// Footprint timeline, injected with DYLD_INSERT_LIBRARIES when TIMELINE_OUT is set. A thread polls phys_footprint every
// millisecond and logs each new maximum (1 MiB steps) with malloc bytes in use. Metal buffer, library and pipeline
// creation are logged with their times, so the peak can be placed against Context creation. Written at exit.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <cxxabi.h>
#include <libproc.h>
#include <malloc/malloc.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <cstdio>
#include <cstring>

static std::mutex mu;
static std::vector<std::string> events;
static uint64_t t0;
static mach_timebase_info_data_t tb;

static double nowMs() {
    return (double) (mach_absolute_time()-t0)*tb.numer/tb.denom/1e6;
}
static uint64_t footprint() {
    rusage_info_v4 ru;
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t*) &ru);
    return ru.ri_phys_footprint;
}
static void log(const char* kind, const std::string& detail) {
    char buf[160];
    snprintf(buf, sizeof(buf), "%10.1f %-5s fp=%7.1f ", nowMs(), kind, footprint()/1048576.0);
    std::lock_guard<std::mutex> lock(mu);
    events.push_back(buf+detail);
}
static std::string site() {
    void* frames[24];
    int n = backtrace(frames, 24);
    for (int i = 2; i < n; i++) {
        Dl_info info;
        if (!dladdr(frames[i], &info) || !info.dli_fname || !strstr(info.dli_fname, "OpenMM") || !info.dli_sname)
            continue;
        int status = 0;
        char* d = abi::__cxa_demangle(info.dli_sname, NULL, NULL, &status);
        std::string s = (status == 0 && d) ? d : info.dli_sname;
        free(d);
        if (s.find("MetalArray::") != std::string::npos || s.find("MTL::") != std::string::npos)
            continue;
        return s.substr(0, s.find('('));
    }
    return "?";
}

static IMP origLen, origLib, origPso;
static id hookLen(id self, SEL sel, NSUInteger length, MTLResourceOptions options) {
    id b = ((id (*)(id, SEL, NSUInteger, MTLResourceOptions)) origLen)(self, sel, length, options);
    if (length >= 1<<20)
        log("buf", std::to_string(length>>10)+" KiB "+site());
    return b;
}
static id hookLib(id self, SEL sel, id source, id options, id* error) {
    log("lib+", std::to_string([(NSString*) source length]/1024)+" KiB source "+site());
    id l = ((id (*)(id, SEL, id, id, id*)) origLib)(self, sel, source, options, error);
    log("lib-", "");
    return l;
}
static id hookPso(id self, SEL sel, id function, id* error) {
    id p = ((id (*)(id, SEL, id, id*)) origPso)(self, sel, function, error);
    log("pso", [[(id<MTLFunction>) function name] UTF8String]);
    return p;
}
static IMP swap(Class cls, const char* name, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel_registerName(name));
    return m ? method_setImplementation(m, imp) : NULL;
}

static void poll() {
    uint64_t best = 0;
    while (true) {
        uint64_t fp = footprint();
        if (fp > best+(1<<20)) {
            best = fp;
            malloc_statistics_t st;
            malloc_zone_statistics(NULL, &st);
            char buf[96];
            snprintf(buf, sizeof(buf), "malloc_in_use=%.1f", st.size_in_use/1048576.0);
            log("max", buf);
        }
        usleep(1000);
    }
}

__attribute__((constructor)) static void timelineInit() {
    if (!getenv("TIMELINE_OUT"))
        return;
    mach_timebase_info(&tb);
    t0 = mach_absolute_time();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Class cls = object_getClass(device);
    origLen = swap(cls, "newBufferWithLength:options:", (IMP) hookLen);
    origLib = swap(cls, "newLibraryWithSource:options:error:", (IMP) hookLib);
    origPso = swap(cls, "newComputePipelineStateWithFunction:error:", (IMP) hookPso);
    std::thread(poll).detach();
}

__attribute__((destructor)) static void timelineDump() {
    const char* path = getenv("TIMELINE_OUT");
    if (!path)
        return;
    log("exit", "");
    FILE* f = fopen(path, "w");
    if (!f)
        return;
    rusage_info_v4 ru;
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t*) &ru);
    fprintf(f, "lifetime_max_phys_footprint %.1f MiB\n", ru.ri_lifetime_max_phys_footprint/1048576.0);
    std::lock_guard<std::mutex> lock(mu);
    for (auto& e : events)
        fprintf(f, "%s\n", e.c_str());
    fclose(f);
}
