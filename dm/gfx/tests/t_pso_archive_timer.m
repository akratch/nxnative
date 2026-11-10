// Execute the production archive timer's queued blocks at virtual deadlines.
// Only the clock and delayed-delivery seams change; captures, handovers, writes
// and their serial dispatch queue are real. No game libraries or long sleeps.
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
static _Atomic uint64_t timer_now;
static dispatch_queue_t timer_queue;
static dispatch_block_t timer_block;
static uint64_t timer_due;
static int timer_duplicates, timer_bad_delay;
static pthread_mutex_t timer_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t timer_clock(clockid_t clock) {
    uint64_t n = atomic_load(&timer_now);
    return n && clock == CLOCK_UPTIME_RAW ? n : clock_gettime_nsec_np(clock);
}
static dispatch_time_t timer_time(dispatch_time_t when, int64_t delta) {
    if (timer_queue && delta == 10 * (int64_t)NSEC_PER_SEC) return UINT64_MAX - 1;
    return dispatch_time(when, delta);
}
static void timer_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (!timer_queue || queue != timer_queue) { dispatch_after(when, queue, block); return; }
    pthread_mutex_lock(&timer_lock);
    if (timer_block) timer_duplicates++;
    if (when != UINT64_MAX - 1) timer_bad_delay++;
    timer_block = [block copy]; timer_due = atomic_load(&timer_now) + 10 * NSEC_PER_SEC;
    pthread_mutex_unlock(&timer_lock);
}
#define clock_gettime_nsec_np timer_clock
#define dispatch_time timer_time
#define dispatch_after timer_after
#define main archive_existing_main
#include "t_pso_archive.m"
#undef main
#undef dispatch_after
#undef dispatch_time
#undef clock_gettime_nsec_np
static int timer_pending(void) {
    pthread_mutex_lock(&timer_lock); int pending = timer_block != nil; pthread_mutex_unlock(&timer_lock); return pending;
}
static int timer_tick(void) {
    pthread_mutex_lock(&timer_lock);
    dispatch_block_t block = timer_block; uint64_t due = timer_due; timer_block = nil;
    pthread_mutex_unlock(&timer_lock);
    if (!block) return 0;
    atomic_store(&timer_now, due);
    dispatch_sync(g_arch_q, block); // Production callback can enqueue its next retry.
    dispatch_group_wait(g_arch_pending, DISPATCH_TIME_FOREVER);
    dispatch_sync(g_arch_q, ^{});
    return 1;
}
static void timer_capture(int serial) {
    MTLRenderPipelineDescriptor *d = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
    d.vertexDescriptor.layouts[16].stride = 16 * (serial + 200);
    NSError *error = nil;
    EXPECT("timer: real synthetic pipeline captured", 1, pso_build(d, &error) != nil);
    EXPECT("timer: one pending delivery", 1, timer_pending());
    arch_note_new(); // A burst must not duplicate the already scheduled callback.
}
int main(void) { @autoreleasepool {
    if (!mkdtemp(archive_cache_root)) return 2;
    atexit(archive_cache_cleanup);
    NSString *cache = [@(archive_cache_root) stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
    if (!cache || ![NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:NO attributes:nil error:nil]) return 2;
    char dir[] = "/tmp/t_archive_timer.XXXXXX"; if (!mkdtemp(dir)) return 2;
    setenv("DM_PSO_ARCHIVE", dir, 1); setenv("DM_PSO_ARCH_WARM_FLUSH_MS", "20000", 1);
    mtl_init(); NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal; struct I{float4 p [[attribute(0)]];}; struct V{float4 p [[position]];}; vertex V vs(I i [[stage_in]]){return {i.p};} struct O{float4 a [[color(0)]];float4 b [[color(1)]];}; fragment O fs(){return {float4(1),float4(0)};}";
    g_lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!g_lib) return 2;
    lib_tag(g_lib, @"timer-synthetic.metallib"); pso4_init();
    if (!g_arch_q || !g_arch_pending || !g_ep || !g_arch_cap) return 2;
    timer_queue = g_arch_q; atomic_store(&timer_now, NSEC_PER_SEC); atomic_store(&g_ep_t0, NSEC_PER_SEC);
    atomic_store(&g_warm_running, 1); g_arch_period_max = 100;
    // Six real periods prove the multiplier saturates at sixteen, not thirty-two.
    const int seconds[] = {20, 40, 80, 160, 320, 320};
    for (int round = 0; round < 6; round++) {
        timer_capture(round);
        uint64_t start = atomic_load(&g_ep_t0), built = g_pb_built;
        int ticks = (int)((start + (uint64_t)seconds[round] * NSEC_PER_SEC - atomic_load(&timer_now)) / (10 * NSEC_PER_SEC));
        for (int tick = 1; tick <= ticks; tick++) {
            EXPECT("timer: retry delivered without another capture", 1, timer_tick());
            EXPECT("timer: no new pipeline compiled during retries", built, g_pb_built);
            EXPECT("timer: exact handover age", round + (tick == ticks), atomic_load(&g_warm_flushes));
            if (tick < ticks) EXPECT("timer: too-young period is retained", start, atomic_load(&g_ep_t0));
        }
        EXPECT("timer: real archive file per due period", round + 1, archive_files(@(dir)).count);
        EXPECT("timer: captures durably handed to the writer", 0, atomic_load(&g_arch_new));
        // A retry scheduled before its asynchronous write finished stops once empty.
        if (timer_pending()) EXPECT("timer: trailing empty retry delivered", 1, timer_tick());
        EXPECT("timer: empty period stops scheduling", 0, timer_pending());
        EXPECT("timer: empty period does not raise multiplier", round + 1, atomic_load(&g_warm_flushes));
    }
    // Off and compaction suppress timer handover, but pending captures keep retries alive.
    for (int compact = 0; compact < 2; compact++) {
        g_warm_flush_ms = compact ? 20000 : 0; g_compact_enabled = compact;
        timer_capture(6 + compact);
        for (int tick = 0; tick < 40; tick++) EXPECT("timer: suppressed retry remains scheduled", 1, timer_tick());
        EXPECT("timer: off or compaction keeps period", 6, atomic_load(&g_warm_flushes));
        EXPECT("timer: suppressed period remains unwritten", 1, atomic_load(&g_arch_new));
        // Finishing prewarm makes the already queued callback flush without another capture.
        g_compact_enabled = 0; atomic_store(&g_warm_running, 0);
        EXPECT("timer: prewarm completion uses outstanding retry", 1, timer_tick());
        EXPECT("timer: prewarm completion persists pending capture", 0, atomic_load(&g_arch_new));
        EXPECT("timer: no retry after completed prewarm", 0, timer_pending());
        atomic_store(&g_warm_running, 1);
    }
    EXPECT("timer: no duplicate delayed callback", 0, timer_duplicates);
    EXPECT("timer: every retry scheduled ten seconds later", 0, timer_bad_delay);
    EXPECT("timer: all eight real periods persisted", 8, archive_files(@(dir)).count);
    atomic_store(&g_warm_running, 0); mtl_arch_save(1000, 1);
    [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
    printf("t_pso_archive_timer: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
