/// The single place a new language is wired in.
///
/// Adding a language means adding one new `LanguageModule` conformance
/// and one line here — see plan.md "Language modules (strategy pattern)".
/// Every other consumer (chunker, project detection, LSP supervisor,
/// extension→language routing) is generic over `Languages.all`.
public enum Languages {
    /// Every registered language module, in the order new v1 modules were
    /// ported (swift, rust, python — see plan.md port order step 4).
    public static let all: [any LanguageModule.Type] = [
        SwiftLanguage.self,
        RustLanguage.self,
        PythonLanguage.self,
    ]

    /// Looks up the module registered for a file extension.
    ///
    /// - Parameter fileExtension: The extension without a leading dot, e.g.
    ///   `"swift"`. Matched case-insensitively.
    /// - Returns: The first module whose `fileExtensions` contains a
    ///   case-insensitive match, or `nil` if none does.
    public static func module(forFileExtension fileExtension: String) -> (any LanguageModule.Type)? {
        let normalized = fileExtension.lowercased()
        return all.first { module in
            module.fileExtensions.contains { $0.lowercased() == normalized }
        }
    }
}
