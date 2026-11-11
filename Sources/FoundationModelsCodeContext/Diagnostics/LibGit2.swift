import Foundation
import libgit2

/// The start call, the error check, and the repository open of the libgit2 C
/// API.
///
/// The package reads git repositories with libgit2 in the process, and never
/// starts the `git` program. A Mac with no developer tools has no `git`, and
/// in the App Sandbox the `/usr/bin/git` shim refuses. `LibGit2Transport` of
/// FoundationModelsExtras and the `LibGit2` layer of FoundationModelsMultitool
/// are the models for this layer. All three packages link the same
/// `swift-libgit2` package, thus one process holds one libgit2.
///
/// A namespace, not a value: libgit2 keeps its own state for the process, and
/// this type only starts it and reads its errors.
enum LibGit2 {
    /// Starts libgit2 one time for the process. The value is the start count,
    /// or a negative libgit2 error code.
    ///
    /// A `static let` is initialized one time, and the runtime makes the
    /// initialization safe across threads. Thus `git_libgit2_init` runs one
    /// time, however many calls reach `start()` first.
    private static let libraryStartCount: Int32 = git_libgit2_init()

    /// The text of a `CodeContextError.git` when libgit2 recorded no error
    /// text.
    private static let missingErrorText = "libgit2 gave no error text"

    /// The `git_repository_open_ext` flags that search from the start folder
    /// up to the root of the file system, as the `git` program does. Zero
    /// sets no flag.
    private static let searchParentFoldersFlags: UInt32 = 0

    /// Starts libgit2, or throws when it cannot start.
    ///
    /// Each entry point of the layer calls this before its first libgit2
    /// call.
    ///
    /// - Throws: `CodeContextError.git` when `git_libgit2_init` failed.
    static func start() throws {
        try check(libraryStartCount)
    }

    /// Throws a `CodeContextError.git` when `status` is a libgit2 error code.
    ///
    /// libgit2 keeps the last error for each thread, thus the check reads the
    /// error text on the same thread, directly after the failed call.
    ///
    /// - Parameter status: The code that the libgit2 call returned. A value
    ///   below `GIT_OK` is an error.
    /// - Throws: `CodeContextError.git` with the text of the last libgit2
    ///   error.
    static func check(_ status: Int32) throws {
        guard status < GIT_OK.rawValue else { return }
        throw CodeContextError.git(lastErrorMessage())
    }

    /// Runs one libgit2 call that makes an object, and gives the object.
    ///
    /// - Parameter call: The libgit2 call. It writes the object into its
    ///   argument, and returns the libgit2 status.
    /// - Returns: The object. The caller owns it and frees it.
    /// - Throws: `CodeContextError.git` when the call fails, or when it gives
    ///   no object.
    static func makeHandle(_ call: (_ handle: inout OpaquePointer?) -> Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        try check(call(&handle))
        guard let handle else {
            throw CodeContextError.git(lastErrorMessage())
        }
        return handle
    }

    /// Opens the repository that holds `directory`, runs `body` with it, and
    /// frees it.
    ///
    /// The search starts at `directory` and goes up through the parent
    /// folders, as the `git` program does in its working folder.
    ///
    /// - Parameters:
    ///   - directory: A folder in the work folder of the repository.
    ///   - body: The work to do with the open repository.
    /// - Returns: The value of `body`.
    /// - Throws: `CodeContextError.git` when no repository holds `directory`,
    ///   or the error of `body`.
    static func withRepository<Value>(at directory: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        try start()
        let repository = try makeHandle { repository in
            git_repository_open_ext(&repository, directory.path, searchParentFoldersFlags, nil)
        }
        defer { git_repository_free(repository) }
        return try body(repository)
    }

    /// The text of the last libgit2 error on this thread.
    private static func lastErrorMessage() -> String {
        guard let error = git_error_last(), let message = error.pointee.message else {
            return missingErrorText
        }
        return String(cString: message)
    }
}
