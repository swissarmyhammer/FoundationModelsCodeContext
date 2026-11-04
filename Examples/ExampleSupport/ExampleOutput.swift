/// The output of the example programs.
public enum ExampleOutput {
    /// Writes one line of the result to standard output.
    ///
    /// The example programs are command-line programs, and they have no logging system. The line
    /// is the result that the reader asked for, and not a debug log. This is the one `print` of the
    /// example programs, and it carries the swiftlint directive for `no_direct_standard_out_logs`.
    ///
    /// - Parameter line: The text of the line.
    public static func report(_ line: String) {
        // swiftlint:disable:next no_direct_standard_out_logs
        print(line)
    }
}
