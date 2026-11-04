import FoundationModels
import FoundationModelsCodeContext
import FoundationModelsRanker

/// The selection model of the example programs that search.
///
/// `searchCode` retrieves candidates, and then a language model picks and orders them. This
/// package ships no model, and `CodeContext` and `CodeContextManager` cannot be made without one:
/// the caller gives a `SelectionFactory`. The package applies it one time for each search, with the
/// ids of the candidates, and it uses the `SelectionConfig` that the factory returns. A manager
/// runs the model one time for each search over the merged candidates of all roots, and not one
/// time for each root. A selection error is the error of `searchCode`: there is no fallback to
/// retrieval alone.
///
/// The examples that search share this one factory, thus they pick the model in one place.
///
/// The example programs are local smoke steps. They are not part of the automated verification of
/// this package (`swift build` and `swift test` are).
public enum ExampleSelection {
    /// A factory that picks among the candidates of each search with the on-device
    /// `SystemLanguageModel`.
    ///
    /// The package applies the factory one time for each search. It gets the ids of the candidates,
    /// and it returns the configuration of the model that picks among them.
    public static let onDeviceModel: SelectionFactory = { _ in
        SelectionConfig(model: SystemLanguageModel.default)
    }
}
