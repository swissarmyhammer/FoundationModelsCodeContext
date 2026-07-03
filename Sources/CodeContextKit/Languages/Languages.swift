/// The single place a new language is wired in.
///
/// Adding a language means adding one new `LanguageModule` conformance
/// and one line here — see plan.md "Language modules (strategy pattern)".
/// Every other consumer (chunker, project detection, LSP supervisor,
/// extension→language routing) is generic over `Languages.all`.
///
/// ## Grammar availability (v1 set)
///
/// Every v1 language's tree-sitter grammar ships a working upstream SwiftPM
/// `Package.swift` under the `tree-sitter` GitHub org (or, for Swift itself,
/// `alex-pinkus`), so every module below has a real, non-`nil`
/// `treeSitterLanguage` — none needed a wrapper package to fill a gap:
///
/// | Language   | Upstream repo                    | SwiftPM support |
/// |------------|-----------------------------------|------------------|
/// | Swift      | `alex-pinkus/tree-sitter-swift`   | yes (pinned to a `-with-generated-files` tag; see `Package.swift`) |
/// | Rust       | `tree-sitter/tree-sitter-rust`    | yes |
/// | Python     | `tree-sitter/tree-sitter-python`  | yes (pinned exact; see `Package.swift`) |
/// | TypeScript | `tree-sitter/tree-sitter-typescript` | yes (bundles TSX too, see `TSXLanguage`) |
/// | TSX        | `tree-sitter/tree-sitter-typescript` | yes (same package as TypeScript) |
/// | JavaScript | `tree-sitter/tree-sitter-javascript` | yes (pinned exact; see `Package.swift`) |
/// | Go         | `tree-sitter/tree-sitter-go`      | yes |
/// | C          | `tree-sitter/tree-sitter-c`       | yes |
/// | C++        | `tree-sitter/tree-sitter-cpp`     | yes |
/// | Java       | `tree-sitter/tree-sitter-java`    | yes |
/// | C#         | `tree-sitter/tree-sitter-c-sharp` | yes |
/// | PHP        | `tree-sitter/tree-sitter-php`     | yes |
///
/// A future language whose grammar has no upstream SwiftPM support would
/// leave `treeSitterLanguage: nil` (already optional per the
/// `LanguageModule` protocol) and add a row above noting the gap, rather
/// than standing up a wrapper package as a workaround.
public enum Languages {
    /// Every registered language module, in the order new v1 modules were
    /// ported (swift, rust, python, then the LSP-backed remainder of the v1
    /// set — see plan.md port order step 4).
    public static let all: [any LanguageModule.Type] = [
        SwiftLanguage.self,
        RustLanguage.self,
        PythonLanguage.self,
        TypeScriptLanguage.self,
        TSXLanguage.self,
        JavaScriptLanguage.self,
        GoLanguage.self,
        CLanguage.self,
        CPPLanguage.self,
        JavaLanguage.self,
        CSharpLanguage.self,
        PHPLanguage.self,
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
