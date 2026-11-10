// Real lifecycle deadlines in child processes. Config probes replace only clock
// and dispatch scheduling so large valid budgets need no wall-clock wait.
#include "../hle.h"
#include <dispatch/dispatch.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
static int probe, failed, last_wait=-1;
static unsigned ntimes, nafter;
static int64_t delays[4];
static uint64_t expected;
static const char *mode;
static dispatch_time_t test_time(dispatch_time_t when,int64_t delta) {
    if(!probe)return dispatch_time(when,delta);
    if(ntimes<4)delays[ntimes]=delta;ntimes++;return 0;
}
static void test_after(dispatch_time_t when,dispatch_queue_t queue,dispatch_block_t block) {
    if(probe){nafter++;return;}dispatch_after(when,queue,block);
}
static _Noreturn void test_exit(int status) {
    if(probe){
        int budget=expected+1300>INT_MAX?INT_MAX:(int)(expected+1300);
        if(ntimes!=2||nafter!=2||delays[0]!=1500ll*NSEC_PER_MSEC||delays[1]!=(int64_t)(expected+2000)*NSEC_PER_MSEC||last_wait!=budget)failed++;
        printf("config: cap=%llu timers=%u/%u first=%lld hard=%lld archive=%d failures=%d\n",(unsigned long long)expected,ntimes,nafter,(long long)delays[0],(long long)delays[1],last_wait,failed);fflush(stdout);status=failed!=0;
    }
    _exit(status);
}
#define dispatch_time test_time
#define dispatch_after test_after
#define _exit test_exit
#include "../hle_lifecycle.c"
#undef dispatch_time
#undef dispatch_after
#undef _exit
uint64_t now_ns(void){return probe?1000000000ull:clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
void hlecount_flush(void){}
void dm_rec_finish(void){}
void dm_cheats_exit(void){}
void dm_audio_suspend(int on){(void)on;}
void dm_gfx_quit_begin(void){}
void dm_gfx_suspend(int on){
    (void)on;
    if(!strcmp(mode,"hard-log")){flockfile(stderr);for(;;)pause();}
    if(!strcmp(mode,"hard-first")||!strcmp(mode,"hard-null"))for(;;)pause();
}
void dm_gfx_quit(int ms){last_wait=ms;if(!strcmp(mode,"hard-first")||!strcmp(mode,"hard-null"))for(;;)pause();}
static void callback(void *arg){
    (void)arg;const char message[]="callback\n";(void)write(STDOUT_FILENO,message,sizeof message-1);
    if(strcmp(mode,"normal"))for(;;)pause();
}
int main(int argc,char **argv){
    if(argc<2)return 2;mode=argv[1];
    if(!strcmp(mode,"config")){
        if(argc!=4)return 2;probe=1;expected=strtoull(argv[3],NULL,10);
        if(!strcmp(argv[2],"<unset>"))unsetenv("DM_EXIT_ARCH_MS");else setenv("DM_EXIT_ARCH_MS",argv[2],1);
        int got=exit_arch_ms();if(got<0||(uint64_t)got!=expected){fprintf(stderr,"config: got %d, expected %llu\n",got,(unsigned long long)expected);return 1;}
    }else setenv("DM_EXIT_ARCH_MS","0",1);
    dm_host_shutdown_then("synthetic test",!strcmp(mode,"hard-null")||probe?NULL:callback,NULL);
    return 3;
}
