#ifndef MINICORE_COMPILETIME_H_
#define MINICORE_COMPILETIME_H_

struct CompileTimes {
    double librarySeconds = 0, pipelineSeconds = 0;
    int libraries = 0, pipelines = 0;
};

// Wraps the Metal device's library and pipeline compile calls with timers. Call before any Context.
void installCompileTimers();

// Totals since installCompileTimers(); callers subtract two readings to time one phase.
CompileTimes compileTimes();

#endif
