// Actual capture -> GS -> raster replay. Two consecutive geometry jobs change
// only a texture binding; an earlier GPU copy supplies both logical ranges.
// They must not share an immutable snapshot or open a copy inside a local encoder.
#define main geometry_fixture_main
#include "t_geometry.m"
#undef main
#include <unistd.h>
static void sampled_run(int stage) {
    NSString *capture=stage==3?@"b.out[0]=v;c.dst[0]=0;":stage==0?@"c.dst[0]=float(b.t.read(0u).x);":@"c.dst[0]=0;";
    NSString *value=stage>=2?@"float(g.t.read(0u).x)":@"g.in[0]";
    id<MTLLibrary> l=library([NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct B{texture_buffer<uint>t[[id(0)]];device uint*out[[id(1)]];};struct C{device float*dst;uint4 info;};\n"
        "vertex float4 unused(){return float4(0,0,0,1);}\n"
        "vertex void capture(uint v[[vertex_id]],constant B&b[[buffer(0)]],constant C&c[[buffer(13)]]){%@}\n"
        "struct G{device float*in[[id(0)]];device float4*out[[id(1)]];device uint*ix[[id(2)]];constant uint4*info[[id(3)]];device uint*map[[id(4)]];texture_buffer<uint>t[[id(5)]];};\n"
        "kernel void geometry(constant G&g[[buffer(0)]],uint3 t[[thread_position_in_grid]]){if(t.x||t.y||t.z)return;float x=%@*.8-.8;g.out[0]=float4(x,-.5,0,1);g.out[1]=float4(x+.6,-.5,0,1);g.out[2]=float4(x,.5,0,1);g.ix[0]=0;g.ix[1]=1;g.ix[2]=2;g.ix[3]=0xffffffffu;}\n"
        "struct V{device float4*p[[id(0)]];};vertex float4 reader(uint v[[vertex_id]],constant V&a[[buffer(0)]]){return a.p[v];}\nfragment float4 red(){return float4(1,0,0,1);}\n",capture,value]);
    int helpers[]={0,1,2,3,4},rh[]={1};NvProg *pr=[NvProg new];
    pr->sh[0]=shader(l,@"unused",0,NULL,0);NvShader *vs=pr->sh[0];vs->geo_fn=[l newFunctionWithName:@"capture"];
    if(stage==3){vs->rf.nb=1;vs->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=0,.aid=1,.rw=1};vs->ae=[vs->geo_fn newArgumentEncoderWithBufferIndex:0];vs->arg_len=vs->ae.encodedLength;}
    if(stage==0){vs->rf.nb=1;vs->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TBUF,.reg=0,.aid=0,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT};vs->ae=[vs->geo_fn newArgumentEncoderWithBufferIndex:0];vs->arg_len=vs->ae.encodedLength;}
    pr->sh[1]=shader(l,@"red",1,NULL,0);pr->sh[2]=shader(l,@"geometry",2,helpers,5);NvShader *gs=pr->sh[2];
    if(stage>=2){gs->rf.b[gs->rf.nb++]=(nvn_rbind){.kind=NVN_RB_TBUF,.reg=0,.aid=5,.dtt=MTLTextureTypeTextureBuffer,.dpf=NVN_DPF_UINT};gs->ae=[gs->fn newArgumentEncoderWithBufferIndex:0];gs->arg_len=gs->ae.encodedLength;}
    strcpy(gs->key,"fedcba9876543200_b");gs->key[15]=(char)('0'+stage);gs->geo_vertices=3;gs->geo_invocations=1;gs->geo_output=7;gs->geo_stride=4;gs->geo_index_stride=4;
    NSString *base=[[NSString stringWithUTF8String:gs->key] substringToIndex:16];g_shcache=[NSMutableDictionary dictionary];g_shcache[[base stringByAppendingString:@"_bg0"]]=gs;g_shcache[[base stringByAppendingString:@"_bgv"]]=shader(l,@"reader",0,rh,1);
    prog_t cp={.serial=990100+stage};serial_put(cp.serial,pr);
    uint8_t *cmd=NULL;if(posix_memalign((void**)&cmd,getpagesize(),65536))abort();memset(cmd,0,65536);mtl_pool_add(cmd,65536);size_t used=0;
    tex_t source[2]={0};for(int i=0;i<2;i++){source[i]=(tex_t){.magic=MAGIC('T','E','X',0),.serial=990200+stage*2+i,.mem=cmd+32772+i*4096};source[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_BUFFER,.format=NVN_FORMAT_R32UI,.width=4,.height=1,.depth=1,.levels=1,.samples=1};nvn_tex_layout(&source[i].d,&source[i].L);mtl_tex_init(&source[i]);mtl_reg_tex(1+i,&source[i],NULL);}
    // The capture-writer variant starts offscreen: omitting/reordering that
    // actual vertex SSBO write cannot pass from the earlier copy's bytes.
    *(uint32_t *)(cmd+24576)=stage==3?17:0;*(uint32_t *)(cmd+24592)=stage==3?18:1;
    #define EMIT(OP,X) do{size_t z=(8+sizeof(X)+7)&~7ull;op_hdr h={OP,(uint32_t)z};memcpy(cmd+used,&h,8);memcpy(cmd+used+8,&(X),sizeof(X));used+=z;}while(0)
    tex_t target={.magic=MAGIC('T','E','X',0),.serial=990300+stage,.d={.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=32,.height=32,.depth=1,.levels=1,.samples=1}};
    p_set_rt rt={.n=1};rt.color[0]=&target;EMIT(OP_SET_RT,rt);p_viewports vp={.n=1};vp.v[0][2]=vp.v[0][3]=32;EMIT(OP_VIEWPORTS,vp);
    p_clear_color cl={.mask=15,.rgba={0,0,0,1}};EMIT(OP_CLEAR_COLOR,cl);p_bind_program bp={&cp,7};EMIT(OP_BIND_PROGRAM,bp);
    p_draw d={.prim=0,.count=1,.instances=1};for(int i=0;i<2;i++){p_bind_tex1 bind={.stage=stage==3?2:stage,.slot=0,.h=1+i};EMIT(OP_BIND_TEX1,bind);if(stage==3){p_bind_buf dst={.stage=0,.index=0,.addr=(uint64_t)source[i].mem,.size=16};EMIT(OP_BIND_SSBO,dst);d.first=i;}EMIT(OP_DRAW,d);}
    op_hdr end={OP_END,8};memcpy(cmd+used,&end,8);
    #undef EMIT
    state_reset();memset(&R,0,sizeof R);mtl_set_frame(110+stage);mtl_sub_begin();
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];if(!gate)abort();[g_q4 waitForEvent:gate value:1];
    for(int i=0;i<2;i++)mtl_sub_copy((uint64_t)(cmd+24576+i*16),(uint64_t)source[i].mem,16);
    uint64_t h=(uint64_t)cmd;mtl_sub_index(&h,1);mtl_exec(cmd);
    id<MTLBuffer> rb=[g_dev newBufferWithLength:8192 options:MTLResourceStorageModeShared];if(!rb)abort();res_add(rb);
    enc_b_copy_texture_buffer(blit(),tex_mtl(&target),0,0,MTLOriginMake(0,0,0),MTLSizeMake(32,32,1),rb,0,256,8192);
    EXPECT("GPU remains gated until both geometry jobs and readback are encoded",0,gate.signaledValue);gate.signaledValue=1;finish();
    uint8_t *px=rb.contents;EXPECT("first geometry job uses the first logical range",1,px[14*256+5*4]>200);EXPECT("later geometry job uses its rebound logical range",1,px[14*256+18*4]>200);
    EXPECT("only the buffer-consuming jobs split locally",1,g_geo_nrun);
    for(int i=0;i<2;i++)mtl_tex_release(&source[i]);mtl_tex_release(&target);serial_del(cp.serial);defer_obj_release(rb);mtl_pool_del(cmd);mtl_drain();free(cmd);
}
int main(void){@autoreleasepool{alarm(60);setenv("DM_NVN_TBDR","0",1);setenv("DM_NVN_GEOMETRY_CUT","0",1);setenv("DM_PSO_ARCHIVE","off",1);setenv("DM_PSO_PREBUILD","0",1);setenv("DM_PSO_RECORD","/dev/null",1);setenv("DM_PSO_USER","/dev/null",1);mtl_init();sampled_run(0);sampled_run(2);sampled_run(3);printf("t_tbuf_geometry: %d checks, %d failed\n",checks,failed);return failed!=0;}}
