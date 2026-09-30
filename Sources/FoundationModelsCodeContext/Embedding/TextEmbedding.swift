import FoundationModelsRanker

/// The embedding-model type that converts text into fixed-length vectors — see
/// `FoundationModelsRanker.TextEmbedding`.
///
/// This package and FoundationModelsRanker use one protocol, not two copies. Thus a caller conforms
/// one time, and the same value goes to `CodeContext(rootDirectory:embedder:)`,
/// `CodeContextManager(embedder:)`, and each FoundationModelsRanker API that takes an embedder.
///
/// The contract: `embed(_:)` returns one vector for each input, in input order. All the vectors of
/// one embedder have the same length, and each vector is L2-normalized. The protocol declares no
/// vector length: an embedder that loads its model at the first call cannot know the length before
/// that call. The index gets the length from the first vector that the embedder returns (see
/// `MeasuredEmbedder`). The host supplies the model. This package has no embedding
/// model and no Router of its own. Tests use `FakeEmbedder`, a deterministic double that needs no
/// GPU.
public typealias TextEmbedding = FoundationModelsRanker.TextEmbedding
