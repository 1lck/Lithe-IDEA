import Foundation

/// Samples CPU and resident memory for the process tree the debug session
/// launched. The counters are native, so the sampler needs no language runtime
/// tool and no helper process.
struct MacDebugPerformanceSampler: DebugPerformanceSampling {
    func samples(for target: DebugPerformanceTarget) -> AsyncThrowingStream<DebugPerformanceSample, Error> {
        MacProcessTreePerformanceSampler.samples(processID: target.processID)
    }
}
