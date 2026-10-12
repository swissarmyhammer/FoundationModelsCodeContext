import Testing

/// The parent suite of the scale benchmarks (`GrepCodeScaleTests`,
/// `DetectProjectsScaleTests`). It runs its child suites one at a time. A
/// benchmark measures the CPU time of the whole test process, or the wall time
/// of a call, and a benchmark that runs at the same time adds its own load to
/// that measurement.
@Suite(.serialized)
enum ScaleBenchmarks {}
