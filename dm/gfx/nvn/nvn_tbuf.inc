// Included after texture registration and the submission arena. No game data or
// shader ABI changes: sampled views are immutable, ordered GPU buffer copies.
// Same-operation writable aliases, GPU-written handles and CPU-post reports are
// separate contracts; a snapshot must not be advertised as implementing them.
typedef struct {
    uint64_t sub, writes, shader_writes, pending, storage_writes, dirty, pools, sparse;
} tbuf_epoch;
static tbuf_epoch tbuf_epoch_now(void) {
    return (tbuf_epoch){g_sub_serial, g_wr_epoch, g_vbuf_write_epoch, (uint64_t)g_npend,
                       g_sbw_gen, nvn_dirty_now(), atomic_load(&g_pool_gen), nvn_sparse_gen()};
}
@interface NvTbufCopy : NSObject {
@public id<MTLBuffer> source, destination; id<MTLTexture> view;
    uint64_t source_offset, destination_offset, bytes, consumer; int ready;
}
@end
@implementation NvTbufCopy
@end
static NSMutableDictionary<NSData *, NvTbufCopy *> *g_tbuf_cache;
static NSMutableArray<NvTbufCopy *> *g_tbuf_pending;
// Live until the final logical submission commit, independently of bounded
// lookup-cache eviction and prefix command-buffer completion.
static NSMutableArray<NvTbufCopy *> *g_tbuf_live;
static uint64_t g_tbuf_cache_sub, g_tbuf_copies, g_tbuf_bytes;
static int g_tbuf_collecting, g_tbuf_binding_hit, g_tbuf_untracked_hit;
static uint64_t g_tbuf_view_version, g_tbuf_consumer;
// No padding is hashed: every key is a sequence of uint64_t words.
static id<MTLTexture> tbuf_snapshot(id<MTLTexture> t, MTLPixelFormat pf, MTLTextureType type,
                                   uint32_t w, uint32_t h, uint32_t row, NSUInteger alignment, uint64_t *rid) {
    *rid = 0; // Never leave the carrier RID behind on an allocation/range failure.
    if (!t || !w || !h || !row || !alignment) return nil;
    NvTbufSource *logical = tbuf_source(t);
    id<MTLTexture> root = t; while (root.parentTexture) root = root.parentTexture;
    id<MTLBuffer> source = logical ? logical->buffer : root.buffer;
    uint64_t offset = logical ? logical->offset : root.bufferOffset;
    if (!source || offset >= source.length) return nil;
    uint64_t length = (uint64_t)row * h;
    uint64_t bytes = MIN(length, source.length - offset);
    if (logical) bytes = MIN(bytes, logical->bytes);
    if (!length || length > SIZE_MAX - alignment || !bytes) return nil;
    tbuf_epoch epoch = tbuf_epoch_now();
    // Private storage has only GPU producers. Shared sources can be reused only
    // if CPU stores are tracked, with protection rearmed before the GPU read.
    // Obtaining a shared pointer is not a read of its contents. Untracked shared
    // storage stays legal but gets a fresh snapshot for each consumer.
    int untracked = 0;
    if (source.storageMode != MTLStorageModePrivate) {
        const uint8_t *cpu = source.contents;
        untracked = !cpu || !nvn_dirty_tracked(cpu + offset, (size_t)bytes);
        if (!untracked) nvn_dirty_protect(cpu + offset, (size_t)bytes);
    }
    MTLTextureSwizzleChannels sw = t.swizzle;
    uint64_t key[] = {(uintptr_t)(__bridge void *)source, offset, bytes, length, pf, type, w, h, row, alignment,
                      sw.red, sw.green, sw.blue, sw.alpha,
                      epoch.sub, epoch.writes, epoch.shader_writes, epoch.pending, epoch.storage_writes,
                      epoch.dirty, epoch.pools, epoch.sparse, untracked ? g_tbuf_consumer : 0};
    if (!g_tbuf_cache || g_tbuf_cache_sub != g_sub_serial || g_tbuf_cache.count >= 512) {
        g_tbuf_cache = [NSMutableDictionary dictionary]; g_tbuf_cache_sub = g_sub_serial;
    }
    NSData *k = [NSData dataWithBytes:key length:sizeof key];
    NvTbufCopy *copy = g_tbuf_cache[k];
    g_tbuf_binding_hit = 1;
    g_tbuf_untracked_hit |= untracked;
    if (!g_pend_over && !g_sbw_over && copy && (copy->ready || (g_tbuf_collecting && copy->consumer == g_tbuf_consumer))) {
        *rid = copy->view.gpuResourceID._impl; return copy->view;
    }
    // Binding cannot end its caller's encoder, or start a second encoder while
    // g_rmu is held. All shipping callers prepare before opening that encoder.
    if (!g_tbuf_collecting) MDIE("buffer texture snapshot was not prepared before binding");
    id<MTLBuffer> arena = nil; size_t off = arena_alloc((size_t)length + alignment - 1, &arena);
    if (!arena) return nil;
    off += (alignment - off % alignment) % alignment;
    // Padding is not guest memory. Initialize it before any GPU use; source bytes
    // are copied on the GPU, including for private storage (never query contents).
    if (bytes < length) memset((uint8_t *)arena.contents + off + bytes, 0, (size_t)(length - bytes));
    MTLTextureDescriptor *d = type == MTLTextureTypeTextureBuffer
        ? [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:pf width:w resourceOptions:arena.resourceOptions usage:MTLTextureUsageShaderRead]
        : [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.resourceOptions = arena.resourceOptions; d.usage = MTLTextureUsageShaderRead; d.swizzle = sw;
    id<MTLTexture> view = [arena newTextureWithDescriptor:d offset:off bytesPerRow:row];
    if (!view) { RED_ONCE(138, "cannot allocate an aligned buffer-texture snapshot (%ux%u, row %u)", w, h, row); return nil; }
    res_add(view);
    copy = [NvTbufCopy new]; copy->source = source; copy->destination = arena; copy->view = view;
    copy->source_offset = offset; copy->destination_offset = off; copy->bytes = bytes;
    copy->consumer = g_tbuf_consumer;
    // tbuf_commit retires the view at the consumer's final fence. This owner
    // keeps the source and arena alive without retiring their residency.
    if (!g_tbuf_live) g_tbuf_live = [NSMutableArray array];
    [g_tbuf_live addObject:copy];
    if (!g_tbuf_pending) g_tbuf_pending = [NSMutableArray array];
    [g_tbuf_pending addObject:copy]; g_tbuf_cache[k] = copy; g_tbuf_view_version++;
    *rid = view.gpuResourceID._impl;
    return view;
}
static void tbuf_copies_land(void) {
    // A boundary can replay deferred work recursively. Each invocation owns its
    // request list; cache entries are reusable only after their copy is encoded.
    NSArray<NvTbufCopy *> *pending = g_tbuf_pending; g_tbuf_pending = nil;
    for (NvTbufCopy *copy in pending) {
        g_blit_alias = 1;
        id<MTL4ComputeCommandEncoder> e = blit();
        g_blit_alias = 1;
        enc_b_copy_buffer(e, copy->source, copy->source_offset, copy->destination, copy->destination_offset, copy->bytes);
        copy->ready = 1; g_tbuf_copies++; g_tbuf_bytes += copy->bytes;
    }
}
