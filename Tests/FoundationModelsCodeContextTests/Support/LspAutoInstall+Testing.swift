@testable import FoundationModelsCodeContext

extension LspAutoInstall {
    /// The default auto-install policy with no failure record.
    ///
    /// A test that turns auto-install on gives this policy, or a policy with a temporary
    /// `failureRecordDirectory`. The default record lives in the caches directory of the user:
    /// a test must never write there, and a failure that one test run records there would stop
    /// the installer of the next run.
    static let withoutFailureRecord = LspAutoInstall(failureRecordDirectory: nil)
}
