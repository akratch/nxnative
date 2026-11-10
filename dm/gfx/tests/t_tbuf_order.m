// Literal GPU oracles for sampled BUFFER alignment. The shared case enters the
// real descriptor and dispatch/draw paths; the private case uses the same valid
// carrier factory, with real Metal buffers/views throughout (no NSObject proxy).
#include "../nvn/nvn_mtl.m"
#include <unistd.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
void crash_install(void);
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c,label) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s (%d)\n",label,__LINE__); } } while(0)
enum { SIZE=0x10000, COUNT=16, SOURCE=0x1004, FIRST=0x2000, SECOND=0x3000, OUTPUT=0x4000, HANDLES=0x6000 };
static uint8_t *mem;
static uint64_t serial=970000;
static uint32_t literal(int version, int element) { return (version ? 0x23456780u : 0x12345670u) ^ (uint32_t)element; }
static void finish(void) {
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"submission and CPU effects complete");
    CHECK(!mtl_last_commit_error(),"no Metal command-buffer error");
}
static id<MTLSharedEvent> gate_begin(void) {
    id<MTLSharedEvent> gate=[g_dev newSharedEvent]; CHECK(gate!=nil,"GPU gate allocated");
    if(!gate) exit(2); [g_q4 waitForEvent:gate value:1]; return gate;
}
static NvShader *shader(id<MTLLibrary> lib, NSString *entry, int stage, nvn_rbind binding) {
    NvShader *s=[NvShader new];s->stage=stage;s->fn=[lib newFunctionWithName:entry];
    s->ae=[s->fn newArgumentEncoderWithBufferIndex:0];s->arg_len=s->ae.encodedLength;
    snprintf(s->key,sizeof s->key,"%016llx",(unsigned long long)++serial);
    s->rf.nb=stage==5?2:1;s->rf.b[0]=binding;s->rf.color_mask=stage==1;
    s->rf.tg[0]=s->rf.tg[1]=s->rf.tg[2]=1;
    if(stage==5)s->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=0,.aid=binding.n?binding.n:1,.rw=1};
    s->rf.pool=binding.kind==NVN_RB_TEXP;s->rf.htab=binding.kind==NVN_RB_TEXH;s->rf.bindless=s->rf.pool||s->rf.htab;
    // Production shader_load retains shaders in this cache. Compute pipelines
    // are keyed by shader identity, so synthetic shaders need that lifetime too.
    if(!g_shcache)g_shcache=[NSMutableDictionary dictionary];g_shcache[@(s->key)]=s;
    CHECK(s->fn&&s->ae,"real function and argument encoder exist");return s;
}
static tex_t buffer_descriptor(unsigned offset) {
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=++serial,.mem=mem+offset};
    t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_BUFFER,.format=NVN_FORMAT_R32UI,.width=COUNT,.height=1,.depth=1,.levels=1,.samples=1};
    nvn_tex_layout(&t.d,&t.L);mtl_tex_init(&t);mtl_reg_tex(1,&t,NULL);return t;
}
static void compute_case(id<MTLLibrary> lib, NSString *entry, nvn_rbind binding, unsigned offset, int writer) {
    fprintf(stderr,"CASE compute %s offset=%u writer=%d\n",entry.UTF8String,offset,writer);
    NvShader *cs=shader(lib,entry,5,binding);NvProg *pr=[NvProg new];pr->sh[5]=cs;
    prog_t pg={.serial=++serial};serial_put(pg.serial,pr);
    NvProg *producer=nil;prog_t producer_pg={.serial=++serial};
    if(writer==3) {
        producer=[NvProg new];producer->sh[5]=shader(lib,@"write_value",5,(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=0,.aid=0,.rw=1});
        producer->sh[5]->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=1,.aid=1};serial_put(producer_pg.serial,producer);
    }
    tex_t t=buffer_descriptor(offset);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();S.cprog=&pg;
    S.tex[5][0]=1;S.ubo[5][1]=(p_bind_buf){.addr=(uint64_t)(mem+HANDLES),.size=16};
    id<MTLSharedEvent> gate=gate_begin();
    for(int version=0;version<2;version++) {
        if(writer==3) {
            S.cprog=&producer_pg;S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(mem+offset),.size=COUNT*4};
            S.ssbo[5][1]=(p_bind_buf){.addr=(uint64_t)(mem+(version?SECOND:FIRST)),.size=COUNT*4};
            p_dispatch write={.x=COUNT,.y=1,.z=1};dispatch(&write);S.cprog=&pg;
        }
        else if(writer==1)mtl_sub_update(mem+(version?SECOND:FIRST),(uint64_t)(mem+offset),COUNT*4);
        else if(writer==2)mtl_sub_fill((uint64_t)(mem+offset),COUNT*4,literal(version,0));
        else mtl_sub_copy((uint64_t)(mem+(version?SECOND:FIRST)),(uint64_t)(mem+offset),COUNT*4);
        S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(mem+OUTPUT+version*COUNT*4),.size=COUNT*4};
        p_dispatch dp={.x=COUNT,.y=1,.z=1};dispatch(&dp);
        if(binding.kind==NVN_RB_TEXP&&!version) {
            pool_snap *table=NULL;for(int k=0;k<POOL_SNAPS;k++)if(g_psnap[k].buf&&!g_psnap[k].samp&&g_psnap[k].dtt==MTLTextureTypeTextureBuffer)table=&g_psnap[k];
            CHECK(table&&table->tbuf&&g_seen_buf,"buffer pool owns an immutable snapshot table");if(!table||!g_seen_buf)exit(2);
            uint64_t prior=((uint64_t *)((uint8_t *)table->buf.contents+DMSH_POOL_HEAD))[1];
            // A read discovered by an ordinary pool lookup can revisit the
            // existing BUFFER table while its first consumer is still queued.
            g_seen_todo[0]|=2;g_seen_done[0]|=2;g_seen_sub=UINT64_MAX;
            os_unfair_lock_lock(&g_rmu);pool_seen_scan();os_unfair_lock_unlock(&g_rmu);
            CHECK(((uint64_t *)((uint8_t *)table->buf.contents+DMSH_POOL_HEAD))[1]==prior,"late seen-ID scan does not patch earlier BUFFER snapshots");
        }
    }
    CHECK(gate.signaledValue==0,"all source snapshots encoded while GPU remains gated");
    gate.signaledValue=1;finish();
    for(int version=0;version<2;version++) {
        int good=1;for(int i=0;i<COUNT;i++) { uint32_t got=((uint32_t *)(mem+OUTPUT))[version*COUNT+i],want=literal(version,writer==2?0:i);
            if(got!=want&&good)fprintf(stderr,"  version%d element%d got=%#x expected=%#x\n",version,i,got,want);good&=got==want; }
        CHECK(good,version?"later dispatch sees every new literal":"earlier dispatch retains every old literal");
    }
    mtl_tex_release(&t);serial_del(pg.serial);
    if(producer)serial_del(producer_pg.serial);
}
static void render_case(id<MTLLibrary> lib) {
    NvProg *pr=[NvProg new];pr->sh[0]=[NvShader new];pr->sh[0]->fn=[lib newFunctionWithName:@"vertex_plain"];
    pr->sh[1]=shader(lib,@"fragment_value",1,(nvn_rbind){.kind=NVN_RB_TBUF,.reg=0,.aid=0,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT});
    prog_t pg={.serial=++serial};serial_put(pg.serial,pr);
    tex_t source=buffer_descriptor(SOURCE),target={.magic=MAGIC('T','E','X',0),.serial=++serial};
    target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_R32UI,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
    nvn_tex_layout(&target.d,&target.L);mtl_tex_init(&target);
    id<MTLBuffer> out=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];CHECK(out!=nil,"render readback allocation");if(!out)exit(2);res_add(out);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();S.prog=&pg;S.bst[0]=S.bst[1]=&pg;S.tex[1][0]=1;
    R.has_rt=1;R.rt.n=1;R.rt.color[0]=&target;R.clear_c[0]=1;R.cc[0]=MTLClearColorMake(0,0,0,0);
    R.has_sc=1;S.has_vp=1;const float viewport[4]={0,0,8,4};memcpy(S.vp[0],viewport,sizeof viewport);
    id<MTLSharedEvent> gate=gate_begin();
    for(int version=0;version<2;version++) {
        mtl_sub_copy((uint64_t)(mem+(version?SECOND:FIRST)),(uint64_t)(mem+SOURCE),COUNT*4);
        R.sc=(p_scissor){version*4,0,4,4};p_draw dw={.prim=4,.count=3,.instances=1};draw(&dw,NULL);
    }
    rp_end();id<MTLTexture> image=tex_mtl(&target);
    CHECK(image!=nil,"real render target exists");if(!image)exit(2);
    enc_b_copy_texture_buffer(blit(),image,0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,4,1),out,0,256,1024);
    gate.signaledValue=1;finish();
    int good=1;for(int y=0;y<4;y++)for(int x=0;x<8;x++)good&=*(uint32_t *)((uint8_t *)out.contents+y*256+x*4)==literal(x>=4,0);
    CHECK(good,"actual draw path preserves earlier and later fragment snapshots");
    mtl_tex_release(&source);mtl_tex_release(&target);serial_del(pg.serial);defer_obj_release(out);
}
static void nonbuffer_and_mixed_case(id<MTLLibrary> lib) {
    tex_t buffer=buffer_descriptor(SOURCE),plain={.magic=MAGIC('T','E','X',0),.serial=++serial};
    plain.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_R32UI,.width=COUNT,.height=1,.depth=1,.levels=1,.samples=1};
    nvn_tex_layout(&plain.d,&plain.L);mtl_tex_init(&plain);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:COUNT height:1 mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> raw=[g_dev newTextureWithDescriptor:d];CHECK(raw!=nil,"ordinary TEXU source allocation");if(!raw)exit(2);res_add(raw);tex_put(plain.serial,raw);
    view_t view={.set_format=1,.format=NVN_FORMAT_R32F};mtl_reg_tex(2,&plain,&view);
    nvn_rbind binding={.kind=NVN_RB_TEXU,.reg=1,.aid=0,.dtt=MTLTextureType2D,.dpf=NVN_DPF_FLOAT};
    NvProg *scalar=[NvProg new];scalar->sh[5]=shader(lib,@"float_rows_value",5,binding);
    binding.n=2;NvProg *mixed=[NvProg new];mixed->sh[5]=shader(lib,@"mixed_rows_value",5,binding);
    prog_t pscalar={.serial=++serial},pmixed={.serial=++serial};serial_put(pscalar.serial,scalar);serial_put(pmixed.serial,mixed);
    tex_t rt={.magic=MAGIC('T','E','X',0),.serial=++serial,.d={.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1}};
    nvn_tex_layout(&rt.d,&rt.L);mtl_tex_init(&rt);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();id<MTLSharedEvent> gate=gate_begin();
    void *mb=NULL;uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+FIRST),256,&mb,&mo),"ordinary texture producer resolves");if(!mb)exit(2);
    enc_b_copy_buffer_texture(blit(),(__bridge id<MTLBuffer>)mb,mo,256,256,MTLSizeMake(COUNT,1,1),raw,0,0,MTLOriginMake(0,0,0));
    ((uint64_t *)(mem+HANDLES))[0]=2;((uint64_t *)(mem+HANDLES))[1]=1;
    S.ubo[5][1]=(p_bind_buf){.addr=(uint64_t)(mem+HANDLES),.size=16};
    R.has_rt=1;R.rt.n=1;R.rt.color[0]=&rt;R.clear_c[0]=1;
    id<MTL4RenderCommandEncoder> open=rp_begin();CHECK(open!=nil,"unrelated render encoder is open before collection");
    uint64_t copies=g_tbuf_copies;tbuf_prepare_stage(scalar->sh[5],5);
    CHECK(g_enc==open&&g_tbuf_copies==copies&&!g_tbuf_pending.count,"ordinary TEXU collection neither closes the encoder nor creates copies");
    CHECK(tex_get(plain.serial)==raw&&!(raw.usage&MTLTextureUsagePixelFormatView),"ordinary TEXU format upgrade was not triggered by collection");
    rp_end();S.cprog=&pscalar;S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(mem+OUTPUT),.size=COUNT*4};p_dispatch dp={.x=COUNT,.y=1,.z=1};dispatch(&dp);
    mtl_sub_copy((uint64_t)(mem+SECOND),(uint64_t)(mem+SOURCE),COUNT*4);
    S.cprog=&pmixed;S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(mem+OUTPUT+COUNT*4),.size=COUNT*4};dispatch(&dp);
    gate.signaledValue=1;finish();int plain_ok=1,mixed_ok=1;
    for(int i=0;i<COUNT;i++){plain_ok&=((uint32_t *)(mem+OUTPUT))[i]==literal(0,i);mixed_ok&=((uint32_t *)(mem+OUTPUT))[COUNT+i]==(literal(0,i)^literal(1,i));}
    CHECK(plain_ok,"ordinary TEXU retains its format-upgrade and pixel behavior");
    CHECK(mixed_ok,"mixed TEXU array preserves ordinary entries and prepared buffer entries");
    mtl_tex_release(&buffer);mtl_tex_release(&plain);mtl_tex_release(&rt);serial_del(pscalar.serial);serial_del(pmixed.serial);
    ((uint64_t *)(mem+HANDLES))[0]=((uint64_t *)(mem+HANDLES))[1]=1;
}
static void feedback_case(id<MTLLibrary> lib) {
    NvShader *vs=shader(lib,@"feedback_value",0,(nvn_rbind){.kind=NVN_RB_TBUF,.reg=0,.aid=0,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT});
    vs->tf_fn=vs->fn;vs->fn=[lib newFunctionWithName:@"vertex_plain"];vs->tf_stride[0]=4;
    NvProg *pr=[NvProg new];pr->sh[0]=vs;tex_t source=buffer_descriptor(SOURCE);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();S.rast_discard=1;S.tex[0][0]=1;
    id<MTLSharedEvent> gate=gate_begin();
    for(int v=0;v<2;v++) {
        // Reset the feedback offset for each independently bound output span.
        p_tf_state begin={.what=0};tf_state_gpu(&begin);
        S.tf[0]=(p_tf_bind){.index=0,.addr=(uint64_t)(mem+OUTPUT+v*COUNT*4),.size=COUNT*4};
        mtl_sub_copy((uint64_t)(mem+(v?SECOND:FIRST)),(uint64_t)(mem+SOURCE),COUNT*4);
        p_draw dw={.prim=0,.count=COUNT,.instances=1};tf_draw(pr,&dw,NULL);
    }
    gate.signaledValue=1;finish();
    for(int v=0;v<2;v++) { int good=1;for(int i=0;i<COUNT;i++)good&=((uint32_t *)(mem+OUTPUT))[v*COUNT+i]==literal(v,i);
        CHECK(good,"feedback's own render encoder samples ordered buffer values"); }
    mtl_tex_release(&source);
}
static void mesh_case(id<MTLLibrary> lib) {
    nvn_rbind b={.kind=NVN_RB_TBUF,.reg=0,.aid=0,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT};
    NvProg *pr=[NvProg new];pr->sh[3]=shader(lib,@"task_value",3,b);pr->sh[4]=shader(lib,@"mesh_value",4,b);
    for(int st=3;st<=4;st++){pr->sh[st]->rf.nb=2;pr->sh[st]->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=0,.aid=1,.rw=1};pr->sh[st]->mesh_threads=32;}
    pr->sh[3]->mesh_kind=1;pr->sh[3]->mesh_payload=4;pr->sh[4]->mesh_kind=2;
    prog_t pg={.serial=++serial};serial_put(pg.serial,pr);
    tex_t source=buffer_descriptor(SOURCE),target={.magic=MAGIC('T','E','X',0),.serial=++serial};
    target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
    nvn_tex_layout(&target.d,&target.L);mtl_tex_init(&target);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();S.prog=&pg;S.tex[3][0]=S.tex[4][0]=1;
    R.has_rt=1;R.rt.n=1;R.rt.color[0]=&target;
    id<MTLSharedEvent> gate=gate_begin();
    for(int v=0;v<2;v++) {
        mtl_sub_copy((uint64_t)(mem+(v?SECOND:FIRST)),(uint64_t)(mem+SOURCE),COUNT*4);
        S.ssbo[3][0]=S.ssbo[4][0]=(p_bind_buf){.addr=(uint64_t)(mem+OUTPUT+v*COUNT*4),.size=COUNT*4};
        p_draw dw={.prim=DM_PRIM_MESH_TASKS,.count=1};draw(&dw,NULL);
    }
    gate.signaledValue=1;finish();
    for(int v=0;v<2;v++){CHECK(((uint32_t *)(mem+OUTPUT))[v*COUNT]==literal(v,0),"actual task stage samples its prepared binding");
        CHECK(((uint32_t *)(mem+OUTPUT))[v*COUNT+1]==literal(v,1),"actual mesh stage samples its prepared binding");}
    mtl_tex_release(&source);mtl_tex_release(&target);serial_del(pg.serial);
}
static void sample_view_count(id<MTLTexture> view, id<MTLComputePipelineState> ps, id<MTLArgumentEncoder> ae, id<MTLBuffer> out, int index, unsigned count) {
    CHECK(view!=nil,"real aligned snapshot view exists");if(!view)exit(2);
    id<MTLBuffer> args=[g_dev newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];CHECK(args!=nil,"private oracle argument allocation");if(!args)exit(2);
    [ae setArgumentBuffer:args offset:0];[ae setTexture:view atIndex:0];[ae setBuffer:out offset:COUNT*4*index atIndex:1];res_add(args);defer_obj_release(args);
    id<MTL4ComputeCommandEncoder> ce=dispatch_enc();enc_c_pso(ce,ps);enc_c_args(ce,args.gpuAddress,0);
    enc_c_dispatch(ce,MTLSizeMake(count,1,1),MTLSizeMake(1,1,1));
}
static void sample_view(id<MTLTexture> view, id<MTLComputePipelineState> ps, id<MTLArgumentEncoder> ae, id<MTLBuffer> out, int index) {
    sample_view_count(view,ps,ae,out,index,COUNT);
}
static void segmented_eviction_case(id<MTLLibrary> lib) {
    id<MTLBuffer> src=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> out=[g_dev newBufferWithLength:COUNT*8 options:MTLResourceStorageModeShared];
    CHECK(src&&out,"segmented lifetime resources allocated");if(!src||!out)exit(2);res_add(src);res_add(out);
    id<MTLTexture> carrier=tbuf_carrier(src,4,COUNT,MTLPixelFormatR32Uint,COUNT*4,MTLTextureUsageShaderRead);
    CHECK(carrier!=nil,"segmented source has a real carrier");if(!carrier)exit(2);
    id<MTLFunction> fn=[lib newFunctionWithName:@"buffer_value"];if(!fn)exit(2);NSError *error=nil;
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:fn error:&error];
    id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];if(!ps||!ae)exit(2);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();uint64_t fence=g_fence,sub=g_sub_serial,rid=0;
    void *mb=NULL;uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+FIRST),COUNT*4,&mb,&mo),"first lifetime producer resolves");if(!mb)exit(2);
    enc_b_copy_buffer(blit_buf(0,0,src.gpuAddress,src.gpuAddress+4096),(__bridge id<MTLBuffer>)mb,mo,src,4,COUNT*4);
    g_tbuf_collecting=1;id<MTLTexture> first=tbuf_shadow(carrier,&rid);g_tbuf_collecting=0;tbuf_copies_land();
    __weak id<MTLTexture> retained=first;first=nil;
    // Complete a prefix before there is any consumer of its snapshot. A later
    // segment must still own the view, its residency, and its arena bytes.
    mdi_wait();CHECK(g_fence==fence&&g_sub_serial==sub,"prefix completion does not seal the logical submission");
    id<MTLSharedEvent> gate=gate_begin();
    CHECK(mtl_addr((uint64_t)(mem+SECOND),COUNT*4,&mb,&mo),"second lifetime producer resolves");if(!mb)exit(2);
    enc_b_copy_buffer(blit_buf(0,0,src.gpuAddress,src.gpuAddress+4096),(__bridge id<MTLBuffer>)mb,mo,src,4,COUNT*4);
    NSUInteger al=[g_dev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatR32Uint];
    id<MTLTexture> last=nil;g_tbuf_collecting=1;
    for(unsigned i=0;i<513;i++) {
        unsigned width=COUNT+i,row=(unsigned)((width*4+al-1)/al*al);
        last=tbuf_snapshot(carrier,MTLPixelFormatR32Uint,MTLTextureTypeTextureBuffer,width,1,row,al,&rid);
        if(!last)exit(2);
    }
    g_tbuf_collecting=0;
    CHECK(g_tbuf_cache.count<=512&&g_tbuf_live.count>=514,"bounded lookup eviction does not discard live submission ownership");
    CHECK(g_tbuf_pending.count==513,"all evicted pending copies still belong to their prefix list");
    tbuf_copies_land();g_tbuf_cache=nil;
    CHECK(retained!=nil,"first view survives prefix completion and complete lookup eviction");
    pthread_mutex_lock(&g_res_mu);int resident=[g_res_objects containsObject:retained];pthread_mutex_unlock(&g_res_mu);
    CHECK(resident,"evicted first view remains resident until its consuming fence");
    sample_view(retained,ps,ae,out,0);sample_view(last,ps,ae,out,1);
    CHECK(!gate.signaledValue,"late consumers remain GPU gated during eviction");gate.signaledValue=1;finish();
    int good=1;for(int v=0;v<2;v++)for(int i=0;i<COUNT;i++)good&=((uint32_t *)out.contents)[v*COUNT+i]==literal(v,i);
    CHECK(good,"late consumers preserve both prefix and post-eviction literal pixels");
    defer_obj_release(src);defer_obj_release(out);defer_obj_release(carrier);
}
static void short_tail_case(id<MTLLibrary> lib, int private_storage) {
    id<MTLFunction> fn=[lib newFunctionWithName:@"buffer_value"];if(!fn)exit(2);NSError *error=nil;
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:fn error:&error];
    id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];if(!ps||!ae)exit(2);
    const unsigned offsets[]={0,4,16};
    for(unsigned k=0;k<sizeof offsets/sizeof *offsets;k++) {
        unsigned offset=offsets[k];
        id<MTLBuffer> src=[g_dev newBufferWithLength:offset+4 options:private_storage?MTLResourceStorageModePrivate:MTLResourceStorageModeShared];
        id<MTLBuffer> out=[g_dev newBufferWithLength:COUNT*4 options:MTLResourceStorageModeShared];
        CHECK(src&&out,"short-tail allocations succeed");if(!src||!out)exit(2);res_add(src);res_add(out);
        id<MTLTexture> carrier=tbuf_carrier(src,offset,1,MTLPixelFormatR32Uint,4,MTLTextureUsageShaderRead);
        CHECK(carrier!=nil,"valid logical element does not require source padding");if(!carrier)exit(2);
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();id<MTLSharedEvent> gate=gate_begin();
        void *mb=NULL;uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+FIRST),4,&mb,&mo),"short-tail producer resolves");if(!mb)exit(2);
        enc_b_copy_buffer(blit_buf(0,0,src.gpuAddress,src.gpuAddress+src.length),(__bridge id<MTLBuffer>)mb,mo,src,offset,4);
        uint64_t rid=0;g_tbuf_collecting=1;id<MTLTexture> view=tbuf_shadow(carrier,&rid);g_tbuf_collecting=0;tbuf_copies_land();
        sample_view_count(view,ps,ae,out,0,1);gate.signaledValue=1;finish();
        CHECK(*(uint32_t *)out.contents==literal(0,0),"short-tail snapshot samples the original logical element");
        defer_obj_release(src);defer_obj_release(out);defer_obj_release(carrier);
    }
}
static void cpu_rewrite_case(id<MTLLibrary> lib, int tracked) {
    void *mb=NULL;uint64_t off=0;
    CHECK(mtl_addr((uint64_t)(mem+SOURCE),COUNT*4,&mb,&off),"shared CPU source resolves before protection");if(!mb)exit(2);
    id<MTLTexture> carrier=tbuf_carrier((__bridge id<MTLBuffer>)mb,off,COUNT,MTLPixelFormatR32Uint,COUNT*4,MTLTextureUsageShaderRead);
    CHECK(carrier!=nil,"shared CPU source carrier exists");if(!carrier)exit(2);
    id<MTLBuffer> out=[g_dev newBufferWithLength:COUNT*8 options:MTLResourceStorageModeShared];if(!out)exit(2);res_add(out);
    id<MTLFunction> fn=[lib newFunctionWithName:@"buffer_value"];if(!fn)exit(2);NSError *error=nil;
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:fn error:&error];id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];if(!ps||!ae)exit(2);
    if(tracked)nvn_dirty_add_range(mem,SIZE);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();uint64_t sub=g_sub_serial,old_rid=0;
    for(int v=0;v<2;v++) {
        // The explicit test-only GPU drain makes this CPU rewrite synchronized;
        // this is not a promise about concurrent unsynchronized CPU/GPU stores.
        for(int i=0;i<COUNT;i++)((uint32_t *)(mem+SOURCE))[i]=literal(v,i);
        uint64_t rid=0;g_tbuf_consumer++;g_tbuf_collecting=1;id<MTLTexture> view=tbuf_shadow(carrier,&rid);g_tbuf_collecting=0;tbuf_copies_land();
        if(v)CHECK(rid!=old_rid,"synchronized CPU rewrite refreshes the sampled snapshot");old_rid=rid;
        sample_view(view,ps,ae,out,v);if(!v)mdi_wait();
    }
    CHECK(sub==g_sub_serial,"CPU rewrite stayed inside the same logical submission");finish();
    int good=1;for(int v=0;v<2;v++)for(int i=0;i<COUNT;i++)good&=((uint32_t *)out.contents)[v*COUNT+i]==literal(v,i);
    CHECK(good,tracked?"protected CPU stores refresh every literal":"untracked shared storage is not reused across consumers");
    if(tracked)nvn_dirty_remove_range(mem);
    defer_obj_release(out);defer_obj_release(carrier);
}
static void private_case(id<MTLLibrary> lib, int rows) {
    id<MTLBuffer> src=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> out=[g_dev newBufferWithLength:COUNT*8 options:MTLResourceStorageModeShared];CHECK(src&&out,"private source and shared oracle allocated");if(!src||!out)exit(2);
    res_add(src);res_add(out);
    id<MTLTexture> carrier=tbuf_carrier(src,4,COUNT,MTLPixelFormatR32Uint,COUNT*4,MTLTextureUsageShaderRead);
    CHECK(carrier&&carrier.bufferOffset==0&&tbuf_offset(carrier)==4,"valid real carrier retains exact logical offset");if(!carrier)exit(2);
    id<MTLFunction> fn=[lib newFunctionWithName:rows?@"rows_value":@"buffer_value"];if(!fn)exit(2);
    NSError *error=nil;id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:fn error:&error];id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];
    CHECK(ps&&ae,"private GPU oracle compiles");if(!ps||!ae)exit(2);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();id<MTLSharedEvent> gate=gate_begin();
    uint64_t first_rid=0;
    for(int version=0;version<2;version++) {
        void *mb=NULL;uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+(version?SECOND:FIRST)),COUNT*4,&mb,&mo),"literal producer mapped");if(!mb)exit(2);
        enc_b_copy_buffer(blit_buf(0,0,src.gpuAddress,src.gpuAddress+4096),(__bridge id<MTLBuffer>)mb,mo,src,4,COUNT*4);
        uint64_t rid=0;g_tbuf_collecting=1;
        NSUInteger al=[g_dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Uint];
        uint32_t row=(uint32_t)((COUNT*4+al-1)/al*al);
        id<MTLTexture> view=rows?tbuf_rows_copy(carrier,MTLPixelFormatR32Uint,COUNT,1,row,al,&rid):tbuf_shadow(carrier,&rid);
        g_tbuf_collecting=0;tbuf_copies_land();
        uint64_t copies=g_tbuf_copies,again=0;
        id<MTLTexture> cached=rows?tbuf_rows_copy(carrier,MTLPixelFormatR32Uint,COUNT,1,row,al,&again):tbuf_shadow(carrier,&again);
        CHECK(cached==view&&again==rid&&copies==g_tbuf_copies,"unchanged private generation reuses the ordered immutable view");
        if(version)CHECK(rid!=first_rid,"second producer receives a distinct immutable view");else first_rid=rid;
        sample_view(view,ps,ae,out,version);
    }
    // Retire the owner's resources and discard lookup caches while the first
    // and second consumers are still queued; neither may borrow their lifetime.
    defer_obj_release(src);defer_obj_release(carrier);src=nil;carrier=nil;g_tbuf_cache=nil;
    gate.signaledValue=1;finish();
    int good=1;for(int v=0;v<2;v++)for(int i=0;i<COUNT;i++)good&=((uint32_t *)out.contents)[v*COUNT+i]==literal(v,i);
    CHECK(good,"private source first/second snapshots preserve every ordered literal");
    defer_obj_release(out);
}
// A retained host view has a stronger lifetime than its guest owner's address.
// This is a backend ownership oracle, not a claim that NVN permits arbitrary
// use of a guest object after Finalize. Public active MapVirtual is tested in
// t_tbuf_nvn; here the old view intentionally retains independent private bytes.
static void retired_owner_case(id<MTLLibrary> lib) {
    id<MTLBuffer> old=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> out=[g_dev newBufferWithLength:COUNT*8 options:MTLResourceStorageModeShared];
    CHECK(old&&out,"retired-owner resources allocated");if(!old||!out)exit(2);res_add(old);res_add(out);
    void *mb=NULL;uint64_t off=0;CHECK(mtl_addr((uint64_t)(mem+SOURCE),COUNT*4,&mb,&off),"replacement owner's logical range resolves");if(!mb)exit(2);
    id<MTLTexture> before=tbuf_carrier(old,4,COUNT,MTLPixelFormatR32Uint,COUNT*4,MTLTextureUsageShaderRead);
    id<MTLTexture> after=tbuf_carrier((__bridge id<MTLBuffer>)mb,off,COUNT,MTLPixelFormatR32Uint,COUNT*4,MTLTextureUsageShaderRead);
    CHECK(before&&after,"old and replacement owners have valid real views");if(!before||!after)exit(2);
    pool_t owner={.magic=MAGIC('P','O','O','L'),.mem=mem,.size=SIZE};
    tex_t guest={.magic=MAGIC('T','E','X',0),.serial=++serial,.pool=&owner,.mem=mem+SOURCE};
    tbuf_track_owner(before,&guest);NvTbufOwner *first_owner=tbuf_source(before)->owner;
    mtl_alias_drop_pool(&owner);guest.serial=++serial;tbuf_track_owner(after,&guest);
    CHECK(first_owner->retired&&first_owner!=tbuf_source(after)->owner,"reused pool object gets a distinct lifetime token");
    CHECK(tbuf_refresh_mapping(&guest,before)==before&&tbuf_buffer(before)==old,"retired view never follows the replacement owner's address");
    CHECK(tbuf_refresh_mapping(&guest,after)==after,"active replacement resolves its own backing");
    id<MTLFunction> fn=[lib newFunctionWithName:@"buffer_value"];if(!fn)exit(2);NSError *error=nil;
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:fn error:&error];id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];if(!ps||!ae)exit(2);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();id<MTLSharedEvent> gate=gate_begin();
    uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+FIRST),COUNT*4,&mb,&mo),"old owner's GPU producer resolves");if(!mb)exit(2);
    enc_b_copy_buffer(blit_buf(0,0,old.gpuAddress,old.gpuAddress+old.length),(__bridge id<MTLBuffer>)mb,mo,old,4,COUNT*4);
    mtl_sub_copy((uint64_t)(mem+SECOND),(uint64_t)(mem+SOURCE),COUNT*4);
    for(int v=0;v<2;v++){uint64_t rid=0;g_tbuf_collecting=1;id<MTLTexture> image=tbuf_shadow(v?after:before,&rid);g_tbuf_collecting=0;tbuf_copies_land();sample_view(image,ps,ae,out,v);}
    gate.signaledValue=1;finish();int good=1;
    for(int v=0;v<2;v++)for(int i=0;i<COUNT;i++)good&=((uint32_t *)out.contents)[v*COUNT+i]==literal(v,i);
    CHECK(good,"retired and replacement views independently sample their own literal GPU bytes");
    mtl_alias_drop_pool(&owner);defer_obj_release(before);defer_obj_release(after);defer_obj_release(old);defer_obj_release(out);
}
static void image_origin_case(id<MTLLibrary> lib, unsigned offset, int aligned, int image2d) {
    tex_t t=buffer_descriptor(offset);t.d.flags|=NVN_TEXTURE_FLAGS_IMAGE;mtl_reg_tex(1,&t,NULL);
    nvn_rbind binding={.kind=NVN_RB_IMG,.reg=0,.aid=0,.dtt=image2d?MTLTextureType2D:MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT,.rw=1};
    NvProg *pr=[NvProg new];pr->sh[5]=shader(lib,image2d?@"image_write_2d":@"image_write",5,binding);pr->sh[5]->rf.nb=1;
    prog_t pg={.serial=++serial};serial_put(pg.serial,pr);
    id<MTLBuffer> out=[g_dev newBufferWithLength:512 options:MTLResourceStorageModeShared];if(!out)exit(2);res_add(out);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();id<MTLSharedEvent> gate=gate_begin();
    mtl_sub_fill((uint64_t)(mem+offset-4),(COUNT+2)*4,0xaabbccddu);
    id<MTLTexture> sink=nil;
    if(image2d){uint64_t rid=0;int real=1;os_unfair_lock_lock(&g_rmu);sink=img_binding(1,&binding,&rid,&real);os_unfair_lock_unlock(&g_rmu);CHECK(sink&&sink.textureType==MTLTextureType2D&&!real,"unsupported BUFFER image uses the shader-declared 2D sink");}
    S.cprog=&pg;S.img[5][0]=1;p_dispatch dp={.x=COUNT,.y=1,.z=1};dispatch(&dp);
    void *mb=NULL;uint64_t mo=0;CHECK(mtl_addr((uint64_t)(mem+offset-4),(COUNT+2)*4,&mb,&mo),"image canary readback resolves");if(!mb)exit(2);
    enc_b_copy_buffer(blit(),(__bridge id<MTLBuffer>)mb,mo,out,0,(COUNT+2)*4);
    if(image2d&&sink.textureType==MTLTextureType2D)enc_b_copy_texture_buffer(blit(),sink,0,0,MTLOriginMake(0,0,0),MTLSizeMake(1,1,1),out,256,256,256);
    gate.signaledValue=1;finish();int good=1;
    for(int i=0;i<COUNT+2;i++){uint32_t want=aligned&&i>0&&i<=COUNT?(0x0badcafeu^(uint32_t)(i-1)):0xaabbccddu;good&=((uint32_t *)out.contents)[i]==want;}
    CHECK(good,aligned?"aligned writable image preserves exact live origin and canaries":"unsupported misaligned image never writes rounded-origin guest bytes");
    if(image2d){int written=sink.textureType==MTLTextureType2D;for(int c=0;c<4;c++)written&=((uint32_t *)out.contents)[64+c]==0x0badcafeu;CHECK(written,"actual 2D image writer reaches only the shape-correct isolated sink");}
    mtl_tex_release(&t);serial_del(pg.serial);defer_obj_release(out);
}
int main(void) { @autoreleasepool {
    crash_install();if(setvbuf(stdout,NULL,_IONBF,0))return 2;
    alarm(60);setenv("DM_NVN_TBDR","0",1);setenv("DM_TBUF_ALIGN","64",1);setenv("DM_PSO_ARCHIVE","off",1);setenv("DM_PSO_PREBUILD","0",1);setenv("DM_PSO_MANIFEST","off",1);setenv("DM_PSO_USER","/dev/null",1);setenv("DM_PSO_RECORD","/dev/null",1);
    mtl_init();mem=mmap(NULL,SIZE,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);if(mem==MAP_FAILED)return 2;mtl_pool_add(mem,SIZE);
    for(int v=0;v<2;v++)for(int i=0;i<COUNT;i++)((uint32_t *)(mem+(v?SECOND:FIRST)))[i]=literal(v,i);
    ((uint64_t *)(mem+HANDLES))[0]=((uint64_t *)(mem+HANDLES))[1]=1;
    NSError *error=nil;id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct B{texture_buffer<uint> t[[id(0)]];device uint*out[[id(1)]];};\n"
        "struct P{device uint*out[[id(0)]];const device uint*in[[id(1)]];};kernel void write_value(constant P&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.in[x];}\n"
        "struct I{texture_buffer<uint,access::write>t[[id(0)]];};kernel void image_write(constant I&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.t.write(uint4(0x0badcafeu^x),x);}\n"
        "struct I2{texture2d<uint,access::write>t[[id(0)]];};kernel void image_write_2d(constant I2&a[[buffer(0)]],uint x[[thread_position_in_grid]]){if(!x)a.t.write(uint4(0x0badcafeu),uint2(0,0));}\n"
        "struct R{texture2d<uint,access::read> t[[id(0)]];device uint*out[[id(1)]];};\n"
        "struct F{texture2d<float,access::read>t[[id(0)]];device uint*out[[id(1)]];};struct M{array<texture2d<float,access::read>,2>t[[id(0)]];device uint*out[[id(2)]];};\n"
        "kernel void float_rows_value(constant F&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=as_type<uint>(a.t.read(uint2(x,0)).x);}\n"
        "kernel void mixed_rows_value(constant M&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=as_type<uint>(a.t[0].read(uint2(x,0)).x)^as_type<uint>(a.t[1].read(uint2(x,0)).x);}\n"
        "struct A{array<texture_buffer<uint>,2> t[[id(0)]];device uint*out[[id(2)]];};\n"
        "struct T{uint n;ulong seen;array<texture_buffer<uint>,2> e;};struct H{constant T*t[[id(0)]];device uint*out[[id(1)]];};\n"
        "kernel void buffer_value(constant B&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.t.read(x).x;}\n"
        "kernel void rows_value(constant R&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.t.read(uint2(x,0)).x;}\n"
        "kernel void array_value(constant A&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.t[1].read(x).x;}\n"
        "kernel void handle_value(constant H&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.t->e[0].read(x).x;}\n"
        "kernel void pool_value(constant H&a[[buffer(0)]],uint x[[thread_position_in_grid]]){a.out[x]=a.t->e[1].read(x).x;}\n"
        "vertex float4 vertex_plain(uint i[[vertex_id]]){return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1);}\n"
        "vertex void feedback_value(uint i[[vertex_id]],constant B&a[[buffer(0)]],device uint*out[[buffer(8)]]){out[i]=a.t.read(i).x;}\n"
        "struct Payload{uint unused;};struct V{float4 p[[position]];};using Mesh=metal::mesh<V,void,3,1,metal::topology::triangle>;\n"
        "[[object]] void task_value(object_data Payload&p[[payload]],mesh_grid_properties grid,uint i[[thread_index_in_threadgroup]],constant B&a[[buffer(0)]]){if(!i){a.out[0]=a.t.read(0u).x;p.unused=0;grid.set_threadgroups_per_grid(uint3(1));}}\n"
        "[[mesh]] void mesh_value(Mesh m,const object_data Payload&p[[payload]],uint i[[thread_index_in_threadgroup]],constant B&a[[buffer(0)]]){if(!i){a.out[1]=a.t.read(1u).x;m.set_primitive_count(0);}}\n"
        "fragment uint fragment_value(constant B&a[[buffer(0)]]){return a.t.read(0u).x;}\n" options:nil error:&error];
    CHECK(lib!=nil,"synthetic shader library compiles");if(!lib){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 2;}
    nvn_rbind b={.kind=NVN_RB_TBUF,.reg=0,.aid=0,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT};
    for(unsigned off=4;off<=12;off+=4)compute_case(lib,@"buffer_value",b,SOURCE-4+off,0);
    compute_case(lib,@"buffer_value",b,0x1800,0); // aligned zero-copy consumer control
    compute_case(lib,@"buffer_value",b,SOURCE,1);compute_case(lib,@"buffer_value",b,SOURCE,2);
    compute_case(lib,@"buffer_value",b,SOURCE,3);
    b.kind=NVN_RB_TEX;b.dtt=MTLTextureType2D;b.f1d=1;compute_case(lib,@"rows_value",b,SOURCE,0);compute_case(lib,@"rows_value",b,0x1010,0);
    b.kind=NVN_RB_TEXU;b.reg=1;b.dtt=MTLTextureTypeTextureBuffer;b.n=2;b.f1d=0;compute_case(lib,@"array_value",b,SOURCE,0);
    b.kind=NVN_RB_TEXH;b.n=0;compute_case(lib,@"handle_value",b,SOURCE,0);
    NvShader *depth_query=[NvShader new];depth_query->rf.nb=1;depth_query->rf.b[0]=b;
    CHECK(!fb_texu_reads(depth_query,1,0)&&!g_tbuf_pending.count,"depth feedback metadata does not materialize buffer-only handle tables");
    b.kind=NVN_RB_TEXP;b.reg=0;compute_case(lib,@"pool_value",b,SOURCE,0);
    render_case(lib);feedback_case(lib);mesh_case(lib);private_case(lib,0);private_case(lib,1);cpu_rewrite_case(lib,0);cpu_rewrite_case(lib,1);
    segmented_eviction_case(lib);short_tail_case(lib,0);short_tail_case(lib,1);
    nonbuffer_and_mixed_case(lib);
    retired_owner_case(lib);
    image_origin_case(lib,SOURCE,0,0);image_origin_case(lib,0x1800,1,0);image_origin_case(lib,SOURCE,0,1);
    printf("t_tbuf_order: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
