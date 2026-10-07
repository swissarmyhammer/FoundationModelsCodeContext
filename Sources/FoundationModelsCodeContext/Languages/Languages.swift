import Foundation

/// The single place a new language is wired in.
///
/// Adding a language means adding one new `LanguageModule` conformance
/// and one line here — see plan.md "Language modules (strategy pattern)".
/// Every other consumer (chunker, project detection, LSP supervisor,
/// extension→language routing) is generic over `Languages.all`.
///
/// ## Grammar availability
///
/// Every v1 (LSP-backed) language's tree-sitter grammar ships a working
/// upstream SwiftPM `Package.swift` under the `tree-sitter` GitHub org (or,
/// for Swift itself, `alex-pinkus`), so every module below has a real,
/// non-`nil` `treeSitterLanguage` — none needed a wrapper package to fill a
/// gap. The five tree-sitter-only format modules added afterward (sql, json,
/// yaml, markdown, bash) mostly continue that pattern, with one documented
/// exception:
///
/// | Language   | Upstream repo                    | SwiftPM support |
/// |------------|-----------------------------------|------------------|
/// | Swift      | `alex-pinkus/tree-sitter-swift`   | yes (pinned to a `-with-generated-files` tag; see `Package.swift`) |
/// | Rust       | `tree-sitter/tree-sitter-rust`    | yes |
/// | Python     | `tree-sitter/tree-sitter-python`  | local target (v0.25.0; see `Package.swift`) |
/// | TypeScript | `tree-sitter/tree-sitter-typescript` | yes (bundles TSX too, see `TSXLanguage`) |
/// | TSX        | `tree-sitter/tree-sitter-typescript` | yes (same package as TypeScript) |
/// | JavaScript | `tree-sitter/tree-sitter-javascript` | local target (v0.25.0; see `Package.swift`) |
/// | Go         | `tree-sitter/tree-sitter-go`      | yes |
/// | C          | `tree-sitter/tree-sitter-c`       | yes |
/// | C++        | `tree-sitter/tree-sitter-cpp`     | yes |
/// | Java       | `tree-sitter/tree-sitter-java`    | yes |
/// | C#         | `tree-sitter/tree-sitter-c-sharp` | yes |
/// | PHP        | `tree-sitter/tree-sitter-php`     | yes |
/// | JSON       | `tree-sitter/tree-sitter-json`    | yes |
/// | YAML       | `tree-sitter-grammars/tree-sitter-yaml` | yes (pinned exact; see `Package.swift`) |
/// | Markdown   | `tree-sitter-grammars/tree-sitter-markdown` | yes |
/// | Bash       | `tree-sitter/tree-sitter-bash`    | yes |
/// | Ruby       | `tree-sitter/tree-sitter-ruby`    | yes (pinned exact; see `Package.swift`) |
/// | Elixir     | `elixir-lang/tree-sitter-elixir`  | yes (pinned exact; see `Package.swift`) |
/// | SQL        | `DerekStride/tree-sitter-sql`     | **no** — the generated `src/parser.c` isn't committed to git (only `src/scanner.c` is); `SQLLanguage.treeSitterLanguage` is `nil` until a working wrapper exists — see `SQLLanguage`'s doc comment |
///
/// A future language whose grammar has no upstream SwiftPM support follows
/// SQL's precedent: leave `treeSitterLanguage: nil` (already optional per the
/// `LanguageModule` protocol), add a row above noting the gap, and document
/// it on the module itself — rather than standing up a wrapper package as a
/// workaround.
public enum Languages {
    /// Every registered language module, in the order new modules were
    /// ported: swift, rust, python, then the LSP-backed remainder of the v1
    /// set (plan.md port order step 4), then the tree-sitter-only format
    /// modules (sql, json, yaml, markdown, bash), then ruby and elixir.
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
        SQLLanguage.self,
        JSONLanguage.self,
        YAMLLanguage.self,
        MarkdownLanguage.self,
        BashLanguage.self,
        RubyLanguage.self,
        ElixirLanguage.self,
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

    /// Gives the extension of a file path in the form that extension matching uses.
    ///
    /// This is the one place that gets the extension of a file for routing and
    /// filtering. Use it, and do not repeat the `pathExtension.lowercased()` logic.
    ///
    /// - Parameter path: A file path, absolute or relative to a workspace root.
    /// - Returns: The lowercased extension with no leading dot, or an empty string
    ///   when the path has no extension.
    static func normalizedFileExtension(ofPath path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    /// Gives the extension of a file URL in the form that extension matching uses.
    ///
    /// - Parameter url: A file URL.
    /// - Returns: The lowercased extension with no leading dot, or an empty string
    ///   when the URL has no extension.
    static func normalizedFileExtension(of url: URL) -> String {
        normalizedFileExtension(ofPath: url.path)
    }
}
