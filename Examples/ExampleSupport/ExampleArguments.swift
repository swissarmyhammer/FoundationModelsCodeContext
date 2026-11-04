import Foundation

/// The command-line arguments that the example programs read.
///
/// Each example program takes its arguments by position, and each one has a default. This type is
/// the one place that reads them, thus the three programs do not repeat the position rules.
public enum ExampleArguments {
    /// The position of the first argument. Position 0 is the name of the program.
    private static let firstPosition = 1

    /// The position of the second argument.
    private static let secondPosition = 2

    /// The query of the programs that search, when the caller gives none.
    private static let defaultQuery = "TODO"

    /// Gives the first argument of the program.
    ///
    /// - Parameter defaultValue: The text to give when the caller gives no first argument.
    /// - Returns: The first argument, or `defaultValue`.
    public static func firstArgument(default defaultValue: String) -> String {
        argument(at: firstPosition, default: defaultValue)
    }

    /// Gives the second argument of the program.
    ///
    /// - Parameter defaultValue: The text to give when the caller gives no second argument.
    /// - Returns: The second argument, or `defaultValue`.
    public static func secondArgument(default defaultValue: String) -> String {
        argument(at: secondPosition, default: defaultValue)
    }

    /// Gives the directory that the program works on: the first argument, or the current directory.
    ///
    /// - Returns: The standardized URL of the directory.
    public static func directoryURL() -> URL {
        URL(fileURLWithPath: firstArgument(default: FileManager.default.currentDirectoryPath), isDirectory: true)
            .standardizedFileURL
    }

    /// Gives the query of a program that searches: the second argument, or `TODO`.
    ///
    /// - Returns: The query.
    public static func query() -> String {
        secondArgument(default: defaultQuery)
    }

    /// Gives the argument at `position`, or `defaultValue` when the caller gave fewer arguments.
    ///
    /// - Parameters:
    ///   - position: The position in `CommandLine.arguments`.
    ///   - defaultValue: The text to give when there is no argument at `position`.
    /// - Returns: The argument, or `defaultValue`.
    private static func argument(at position: Int, default defaultValue: String) -> String {
        let arguments = CommandLine.arguments
        return arguments.indices.contains(position) ? arguments[position] : defaultValue
    }
}
