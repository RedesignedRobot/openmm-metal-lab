// Lab-only GPU timing for experiment 028, not for upstream.
// GPUPROF picks the mode, GPUPROF_OUT the record file, and records are written only while GPUPROF_ON is set.
//   buffers:  normal batching. Every committed buffer writes
//             "b <gpu start> <gpu end> <host commit> <first kernel> <last kernel> <scheduled> <dispatches> <blits>",
//             and host waits write "w <what> <seconds> <start>". All times are seconds on mach_absolute_time.
//   counters: as buffers, and every dispatch gets its own compute encoder with stage-boundary timestamp samples,
//             written as "e <name> <grid> <block> <gpu tick start> <gpu tick end>". Blits are sampled too.
//             "c <cpu tick> <gpu tick>" pairs from sampleTimestamps map GPU ticks onto mach ticks.
//   split:    as buffers, with one encoder per dispatch but no samples, to price the split alone.
//   kernels:  every dispatch is committed and waited on by itself: "k <name> <grid> <block> <seconds>".
#pragma once
#include <Metal/Metal.hpp>
#include <mach/mach_time.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace gpuprof {

enum Mode {Off, Kernels, Buffers, Counters, Split};

// Timestamp samples of one command buffer: two per encoder.
struct Samples {
    MTL::CounterSampleBuffer* buffer = NULL;
    std::vector<std::string> names;
    int dispatches = 0, blits = 0, overflow = 0;
};

static const int SamplesPerBuffer = 2048;

struct State {
    Mode mode = Off;
    FILE* out = NULL;
    std::mutex lock;
    std::map<const void*, std::string> names;
    std::string first, last;
    std::map<MTL::CommandBuffer*, std::shared_ptr<Samples>> open;
    std::vector<MTL::CounterSampleBuffer*> pool;
    MTL::CounterSet* timestamps = NULL;
    long calibrations = 0;
    State() {
        const char* m = getenv("GPUPROF");
        const char* path = getenv("GPUPROF_OUT");
        if (m == NULL || path == NULL)
            return;
        mode = (strcmp(m, "kernels") == 0 ? Kernels : strcmp(m, "counters") == 0 ? Counters : strcmp(m, "split") == 0 ? Split : Buffers);
        out = fopen(path, "w");
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        fprintf(out, "t %u %u\n", timebase.numer, timebase.denom);
    }
    ~State() {
        if (out != NULL)
            fclose(out);
    }
};

inline State& state() {
    static State s;
    return s;
}

inline bool on(Mode mode) {
    return state().mode == mode && getenv("GPUPROF_ON") != NULL;
}

// buffers, counters and split all write buffer records.
inline bool batched() {
    Mode m = state().mode;
    return (m == Buffers || m == Counters || m == Split) && getenv("GPUPROF_ON") != NULL;
}

inline double hostSeconds() {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);
    return mach_absolute_time()*(double) timebase.numer/timebase.denom*1e-9;
}

inline void setName(const void* pipeline, const std::string& name) {
    std::lock_guard<std::mutex> guard(state().lock);
    state().names[pipeline] = name;
}

inline std::string getName(const void* pipeline) {
    std::lock_guard<std::mutex> guard(state().lock);
    auto found = state().names.find(pipeline);
    return found == state().names.end() ? "unknown" : found->second;
}

// Called with the state lock held.
inline Samples& samplesFor(MTL::CommandBuffer* buffer) {
    std::shared_ptr<Samples>& s = state().open[buffer];
    if (s == NULL)
        s = std::make_shared<Samples>();
    return *s;
}

// Returns the next sample index pair's first index for buffer, or -1 if sampling is off or the buffer is full.
inline int nextSample(MTL::CommandBuffer* buffer, Samples& s) {
    if (!on(Counters))
        return -1;
    State& st = state();
    MTL::Device* device = buffer->device();
    if (st.timestamps == NULL) {
        NS::Array* sets = device->counterSets();
        for (int i = 0; sets != NULL && i < sets->count(); i++)
            if (strcmp(sets->object<MTL::CounterSet>(i)->name()->utf8String(), "timestamp") == 0)
                st.timestamps = sets->object<MTL::CounterSet>(i)->retain();
        if (st.timestamps == NULL || !device->supportsCounterSampling(MTL::CounterSamplingPointAtStageBoundary)) {
            fprintf(st.out, "x no stage-boundary timestamp sampling\n");
            st.mode = Split;
            return -1;
        }
    }
    if (st.calibrations++ % 500 == 0) {
        MTL::Timestamp cpu, gpu;
        device->sampleTimestamps(&cpu, &gpu);
        fprintf(st.out, "c %llu %llu\n", (unsigned long long) cpu, (unsigned long long) gpu);
    }
    if (s.buffer == NULL) {
        if (st.pool.empty()) {
            MTL::CounterSampleBufferDescriptor* descriptor = MTL::CounterSampleBufferDescriptor::alloc()->init();
            descriptor->setCounterSet(st.timestamps);
            descriptor->setSampleCount(SamplesPerBuffer);
            descriptor->setStorageMode(MTL::StorageModeShared);
            NS::Error* error = NULL;
            MTL::CounterSampleBuffer* created = device->newCounterSampleBuffer(descriptor, &error);
            descriptor->release();
            if (created == NULL) {
                fprintf(st.out, "x newCounterSampleBuffer failed: %s\n", error == NULL ? "" : error->localizedDescription()->utf8String());
                st.mode = Split;
                return -1;
            }
            st.pool.push_back(created);
        }
        s.buffer = st.pool.back();
        st.pool.pop_back();
    }
    int index = 2*s.names.size();
    if (index+1 >= SamplesPerBuffer) {
        s.overflow++;
        return -1;
    }
    s.names.push_back("unlabeled");
    return index;
}

inline MTL::ComputeCommandEncoder* newEncoder(MTL::CommandBuffer* buffer) {
    if (!batched())
        return buffer->computeCommandEncoder();
    std::lock_guard<std::mutex> guard(state().lock);
    Samples& s = samplesFor(buffer);
    int index = nextSample(buffer, s);
    if (index < 0)
        return buffer->computeCommandEncoder();
    MTL::ComputePassDescriptor* descriptor = MTL::ComputePassDescriptor::computePassDescriptor();
    MTL::ComputePassSampleBufferAttachmentDescriptor* attachment = descriptor->sampleBufferAttachments()->object(0);
    attachment->setSampleBuffer(s.buffer);
    attachment->setStartOfEncoderSampleIndex(index);
    attachment->setEndOfEncoderSampleIndex(index+1);
    return buffer->computeCommandEncoder(descriptor);
}

inline MTL::BlitCommandEncoder* newBlit(MTL::CommandBuffer* buffer) {
    if (!batched())
        return buffer->blitCommandEncoder();
    std::lock_guard<std::mutex> guard(state().lock);
    Samples& s = samplesFor(buffer);
    s.blits++;
    int index = nextSample(buffer, s);
    if (index < 0)
        return buffer->blitCommandEncoder();
    s.names.back() = "blit 1 1";
    MTL::BlitPassDescriptor* descriptor = MTL::BlitPassDescriptor::blitPassDescriptor();
    MTL::BlitPassSampleBufferAttachmentDescriptor* attachment = descriptor->sampleBufferAttachments()->object(0);
    attachment->setSampleBuffer(s.buffer);
    attachment->setStartOfEncoderSampleIndex(index);
    attachment->setEndOfEncoderSampleIndex(index+1);
    return buffer->blitCommandEncoder(descriptor);
}

// Call right after a dispatch (or a group of dispatches such as an FFT) was encoded into the queue's open encoder.
template <class Queue>
inline void timeDispatch(Queue& queue, const std::string& name, int grid, int block) {
    if (batched()) {
        MTL::CommandBuffer* buffer = queue.getOpenBuffer();
        {
            std::lock_guard<std::mutex> guard(state().lock);
            if (state().first.empty())
                state().first = name;
            state().last = name;
            Samples& s = samplesFor(buffer);
            s.dispatches++;
            if (state().mode == Counters && !s.names.empty() && s.names.back() == "unlabeled")
                s.names.back() = name+" "+std::to_string(grid)+" "+std::to_string(block);
        }
        if (state().mode != Buffers)
            queue.endEncoding();
        return;
    }
    if (!on(Kernels))
        return;
    MTL::CommandBuffer* buffer = queue.getCommandBuffer()->retain();
    queue.commit();
    buffer->waitUntilCompleted();
    std::lock_guard<std::mutex> guard(state().lock);
    fprintf(state().out, "k %s %d %d %.9f\n", name.c_str(), grid, block, buffer->GPUEndTime()-buffer->GPUStartTime());
    buffer->release();
}

// Call right before a buffer is committed.
inline void watch(MTL::CommandBuffer* buffer) {
    std::shared_ptr<Samples> samples;
    {
        std::lock_guard<std::mutex> guard(state().lock);
        auto found = state().open.find(buffer);
        if (found != state().open.end()) {
            samples = found->second;
            state().open.erase(found);
        }
    }
    if (!batched())
        return;
    if (samples == NULL)
        samples = std::make_shared<Samples>();
    double committed = hostSeconds();
    std::string names;
    {
        std::lock_guard<std::mutex> guard(state().lock);
        names = (state().first.empty() ? "none" : state().first)+" "+(state().last.empty() ? "none" : state().last);
        state().first.clear();
        state().last.clear();
    }
    std::shared_ptr<double> scheduled = std::make_shared<double>(0.0);
    buffer->addScheduledHandler([scheduled](MTL::CommandBuffer*) { *scheduled = hostSeconds(); });
    buffer->addCompletedHandler([committed, names, scheduled, samples](MTL::CommandBuffer* done) {
        NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
        std::lock_guard<std::mutex> guard(state().lock);
        FILE* out = state().out;
        fprintf(out, "b %.9f %.9f %.9f %s %.9f %d %d %d\n", done->GPUStartTime(), done->GPUEndTime(), committed, names.c_str(),
                *scheduled, samples->dispatches, samples->blits, samples->overflow);
        if (samples->buffer != NULL) {
            NS::Data* data = samples->buffer->resolveCounterRange(NS::Range(0, 2*samples->names.size()));
            const MTL::CounterResultTimestamp* t = (data == NULL ? NULL : (const MTL::CounterResultTimestamp*) data->bytes());
            for (int i = 0; t != NULL && i < samples->names.size(); i++)
                fprintf(out, "e %s %llu %llu\n", samples->names[i].c_str(), (unsigned long long) t[2*i].timestamp, (unsigned long long) t[2*i+1].timestamp);
            state().pool.push_back(samples->buffer);
        }
        pool->release();
    });
}

struct Wait {
    const char* what;
    double start;
    bool active;
    Wait(const char* what) : what(what), start(hostSeconds()), active(batched()) {}
    ~Wait() {
        if (!active)
            return;
        double end = hostSeconds();
        std::lock_guard<std::mutex> guard(state().lock);
        fprintf(state().out, "w %s %.9f %.9f\n", what, end-start, start);
    }
};

} // namespace gpuprof
