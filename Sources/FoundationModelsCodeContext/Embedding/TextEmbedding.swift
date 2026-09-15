import FoundationModelsRanker

/// The embedding-model type that converts text into fixed-length vectors — see
/// `FoundationModelsRanker.TextEmbedding`.
///
/// This package and FoundationModelsRanker use one protocol, not two copies. Thus a caller conforms
/// one time, and the same value goes to `CodeContext(rootDirectory:embedder:)`,
/// `CodeContextManager(embedder:)`, and each FoundationModelsRanker API that takes an embedder.
///
/// The contract: `embed(_:)` returns one vector for each input, in input order. Each vector is
/// `dimension` long and L2-normalized. The host supplies the model. This package has no embedding
/// model and no Router of its own. Tests use `FakeEmbedder`, a deterministic double that needs no
/// GPU.
public typealias TextEmbedding = FoundationModelsRanker.TextEmbedding
