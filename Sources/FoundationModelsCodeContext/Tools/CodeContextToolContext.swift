import Foundation

/// The shared context of each FoundationModels tool operation of this package.
///
/// Each tool operates on one `CodeContext`. `OperationTool` gives this value
/// to each operation of the tool when the operation executes.
///
/// The type is internal because no public API takes it or returns it: the
/// public tool factory returns `[any Tool]`.
///
/// The tool operations of the later tool tasks make and read this value.
// periphery:ignore
internal struct CodeContextToolContext: Sendable {
    /// The `CodeContext` that the operations call.
    let operating: any CodeContextOperating
}
