/// Language server specs shared by more than one `LanguageModule`.
///
/// `typescript-language-server` speaks TypeScript, TSX, and JavaScript over
/// one daemon; `clangd` speaks C and C++ over one daemon. Each spec is
/// declared exactly once here and referenced by every module it serves, so
/// the `LspSupervisor`'s dedupe-by-command sees the same `ServerSpec` value
/// from every module rather than two or three independently constructed
/// copies that merely happen to compare equal — see plan.md "Multi-language
/// servers compose naturally: the javascript, typescript, and tsx modules
/// all reference the same `typescript-language-server` spec (c/cpp → clangd
/// likewise)".
enum SharedServerSpecs {
    /// The `typescript-language-server` spec shared by the TypeScript, TSX,
    /// and JavaScript modules.
    ///
    /// Ported from `builtin/lsp/typescript-language-server.yaml`. Its
    /// `languageIDs` list matches the yaml's `language_ids` exactly
    /// (`typescript`, `javascript`) — the LSP spec has no distinct `tsx`
    /// language identifier, and TSX documents are submitted as `typescript`.
    static let typeScriptFamily = ServerSpec(
        command: "typescript-language-server",
        args: ["--stdio"],
        languageIDs: ["typescript", "javascript"],
        installHint: "Install typescript-language-server: npm install -g typescript-language-server typescript"
    )

    /// The `clangd` spec shared by the C and C++ modules.
    ///
    /// Ported from `builtin/lsp/clangd.yaml`.
    static let clangd = ServerSpec(
        command: "clangd",
        languageIDs: ["c", "cpp"],
        installHint: "Install clangd via your package manager"
    )
}
