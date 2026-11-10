// Private Metal buffers reject even querying contents. The production logical
// carrier now permits an ordered GPU snapshot without a CPU-access query.
#include "../nvn/nvn_mtl.m"
#include <unistd.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c,label) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s (%d)\n",label,__LINE__); } } while(0)
int main(int argc, char **argv) { @autoreleasepool {
    alarm(30);
    if(argc!=2 || (strcmp(argv[1],"shadow") && strcmp(argv[1],"rows")))return 2;
    setenv("DM_PSO_ARCHIVE","off",1);setenv("DM_PSO_PREBUILD","0",1);setenv("DM_PSO_MANIFEST","off",1);setenv("DM_PSO_USER","/dev/null",1);
    mtl_init();
    id<MTLBuffer> src=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    CHECK(src!=nil,"private source allocation");if(!src)return 2;res_add(src);
    id<MTLTexture> carrier=tbuf_carrier(src,4,16,MTLPixelFormatR32Uint,64,MTLTextureUsageShaderRead);
    CHECK(carrier!=nil,"valid real Metal source carrier");if(!carrier)return 2;
    CHECK(carrier.bufferOffset==0 && tbuf_offset(carrier)==4,"logical source origin preserved without an invalid Metal view");
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();uint64_t rid=0;
    g_tbuf_collecting=1;
    NSUInteger al=[g_dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Uint];
    NSUInteger row=(64+al-1)/al*al;
    id<MTLTexture> result=!strcmp(argv[1],"shadow")?tbuf_shadow(carrier,&rid):tbuf_rows_copy(carrier,MTLPixelFormatR32Uint,16,1,(uint32_t)row,al,&rid);
    g_tbuf_collecting=0;
    CHECK(result && result!=carrier && rid==result.gpuResourceID._impl,"real destination view and resource ID prepared");
    CHECK(g_tbuf_pending.count==1,"copy deferred until outside registration binding");
    tbuf_copies_land();CHECK(g_tbuf_pending==nil,"copy requests transferred to ordered GPU work");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull)&&!mtl_last_commit_error(),"private snapshot completes without querying source contents");
    printf("t_tbuf_access %s: %d checks, %d failed\n",argv[1],checks,failed);return failed!=0;
} }
