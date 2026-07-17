import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ServerSpec.InstallSpec` — the machine-actionable installer
/// alongside each server's human `installHint` — and the per-language
/// modules that populate it. See plan.md "Language modules (strategy
/// pattern)" and the `ServerSpec` doc comment.
struct InstallSpecTests {
    @Test
    func installerDefaultsToNilAndExistingConstructionsCompileUnchanged() {
        let spec = ServerSpec(command: "rust-analyzer", languageIDs: ["rust"], installHint: "install it")
        #expect(spec.installer == nil)
    }

    @Test
    func installSpecDefaultsArgumentsAndExtraSearchDirectoriesToEmpty() {
        let installer = ServerSpec.InstallSpec(tool: "brew")
        #expect(installer.arguments.isEmpty)
        #expect(installer.extraSearchDirectories.isEmpty)
    }

    @Test
    func rustAnalyzerInstallerUsesRustupComponentAdd() {
        let installer = try? #require(RustLanguage.languageServer?.installer)
        #expect(installer?.tool == "rustup")
        #expect(installer?.arguments == ["component", "add", "rust-analyzer"])
        #expect(installer?.extraSearchDirectories == ["~/.cargo/bin"])
    }

    @Test
    func typeScriptFamilyInstallerUsesNpmInstallGlobal() {
        let installer = SharedServerSpecs.typeScriptFamily.installer
        #expect(installer?.tool == "npm")
        #expect(installer?.arguments == ["install", "-g", "typescript-language-server", "typescript"])
        #expect(installer?.extraSearchDirectories.isEmpty == true)
    }

    @Test
    func intelephenseInstallerUsesNpmInstallGlobalLikeTypeScript() {
        let installer = try? #require(PHPLanguage.languageServer?.installer)
        #expect(installer?.tool == "npm")
        #expect(installer?.arguments == ["install", "-g", "intelephense"])
        #expect(installer?.extraSearchDirectories.isEmpty == true)
    }

    @Test
    func goplsInstallerUsesGoInstallWithCorrectModulePath() {
        let installer = try? #require(GoLanguage.languageServer?.installer)
        #expect(installer?.tool == "go")
        #expect(installer?.arguments == ["install", "golang.org/x/tools/gopls@latest"])
        #expect(installer?.extraSearchDirectories == ["~/go/bin"])
    }

    @Test
    func pylspInstallerUsesPipxNotPip() {
        let installer = try? #require(PythonLanguage.languageServer?.installer)
        #expect(installer?.tool == "pipx")
        #expect(installer?.arguments == ["install", "python-lsp-server"])
        #expect(installer?.extraSearchDirectories == ["~/.local/bin"])
    }

    @Test
    func jdtlsInstallerUsesBrew() {
        let installer = try? #require(JavaLanguage.languageServer?.installer)
        #expect(installer?.tool == "brew")
        #expect(installer?.arguments == ["install", "jdtls"])
        #expect(installer?.extraSearchDirectories.isEmpty == true)
    }

    @Test
    func omnisharpHasNoInstallerPendingAReliableHomebrewFormula() {
        // No dependable Homebrew formula exists for omnisharp in Homebrew
        // core; the only tap (OmniSharp/homebrew-omnisharp-roslyn) is
        // third-party and depends on mono, so graceful hint-only
        // degradation is correct here.
        #expect(CSharpLanguage.languageServer?.installer == nil)
    }

    @Test
    func sourceKitLspHasNoInstallerBecauseItIsXcodeBundled() {
        #expect(SwiftLanguage.languageServer?.installer == nil)
    }

    @Test
    func clangdHasNoInstallerBecauseItIsCltBundled() {
        #expect(SharedServerSpecs.clangd.installer == nil)
        #expect(CLanguage.languageServer?.installer == nil)
        #expect(CPPLanguage.languageServer?.installer == nil)
    }

    @Test
    func everyPopulatedInstallerToolIsMentionedInItsModulesInstallHint() {
        // Each module whose `languageServer.installer` is non-nil should
        // have an `installHint` that names the same tool, so the two
        // pieces of guidance (automatic and human-readable) never
        // contradict each other.
        let modulesWithInstallers: [(name: String, spec: ServerSpec?)] = [
            ("rust", RustLanguage.languageServer),
            ("typescript", TypeScriptLanguage.languageServer),
            ("php", PHPLanguage.languageServer),
            ("go", GoLanguage.languageServer),
            ("python", PythonLanguage.languageServer),
            ("java", JavaLanguage.languageServer),
        ]
        for module in modulesWithInstallers {
            guard let spec = module.spec else {
                Issue.record("expected \(module.name) to declare a languageServer")
                continue
            }
            guard let installer = spec.installer else {
                Issue.record("expected \(module.name) to have a populated installer")
                continue
            }
            #expect(
                spec.installHint.contains(installer.tool),
                "\(module.name)'s installHint (\(spec.installHint)) does not mention its installer tool (\(installer.tool))"
            )
        }
    }

    @Test
    func goInstallHintUsesCorrectModulePath() {
        // Known drift fixed: the hint previously referenced the wrong
        // module path (github.com/golang/tools/gopls); gopls's real
        // module is golang.org/x/tools/gopls.
        #expect(GoLanguage.languageServer?.installHint.contains("golang.org/x/tools/gopls") == true)
        #expect(GoLanguage.languageServer?.installHint.contains("github.com/golang/tools/gopls") == false)
    }

    @Test
    func pythonInstallHintUsesPipxNotPip() {
        // Known drift fixed: the hint previously said `pip install
        // python-lsp-server`, which can fail under PEP 668
        // externally-managed-environment restrictions; pipx is correct.
        #expect(PythonLanguage.languageServer?.installHint.contains("pipx") == true)
    }
}
