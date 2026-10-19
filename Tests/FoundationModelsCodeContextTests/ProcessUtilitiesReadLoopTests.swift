import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ProcessUtilities.runReadLoop(name:readEnd:_:)`: the loop is the one owner of the
/// read end of its pipe. The read end stays open while the body of the loop runs, and the loop
/// closes it after the body returns.
///
/// Each test reads the state of the read end through the write end of the same pipe. A write to
/// a pipe whose read end is closed fails with `EPIPE`. The descriptor number of the read end is
/// never read again after the loop, because a parallel test can get that number for a pipe of
/// its own.
struct ProcessUtilitiesReadLoopTests {
    /// The byte that each test writes to the pipe.
    private static let probeByte: UInt8 = 0x2A

    @Test
    func theReadEndStaysOpenWhileTheBodyOfTheLoopRuns() async throws {
        let pipe = Pipe()
        let writeEnd = try Self.writeEndWithNoSignal(of: pipe)
        let gate = ThreadGate()
        let loop = ProcessUtilities.runReadLoop(name: "read-loop-test-open", readEnd: pipe.fileHandleForReading) { _ in
            gate.hold()
        }
        await gate.waitUntilHeld()

        let result = Self.writeProbeByte(to: writeEnd)

        gate.open()
        await loop.value
        #expect(result.bytesWritten == 1, "the read end closed before the body of the loop returned: errno \(result.errorNumber)")
    }

    @Test
    func theLoopClosesTheReadEndAfterTheBodyReturns() async throws {
        let pipe = Pipe()
        let writeEnd = try Self.writeEndWithNoSignal(of: pipe)
        let loop = ProcessUtilities.runReadLoop(name: "read-loop-test-close", readEnd: pipe.fileHandleForReading) { _ in }
        await loop.value

        let result = Self.writeProbeByte(to: writeEnd)

        #expect(result.bytesWritten == -1, "the read end is open after the body of the loop returned")
        #expect(result.errorNumber == EPIPE)
    }

    @Test
    func theBodyGetsTheDescriptorOfTheReadEnd() async throws {
        let pipe = Pipe()
        let writeEnd = try Self.writeEndWithNoSignal(of: pipe)
        #expect(Self.writeProbeByte(to: writeEnd).bytesWritten == 1)
        let loop = ProcessUtilities.runReadLoop(name: "read-loop-test-read", readEnd: pipe.fileHandleForReading) { fileDescriptor in
            ProcessUtilities.readChunk(from: fileDescriptor, bufferSize: ProcessUtilities.defaultChunkSize)
        }

        let chunk = await loop.value

        #expect(chunk == Data([Self.probeByte]))
    }

    /// The result of one `write(2)` of `probeByte`.
    private struct WriteResult {
        /// The return value of `write(2)`: the number of bytes written, or `-1`.
        let bytesWritten: Int

        /// The `errno` after the write.
        let errorNumber: Int32
    }

    /// Gives the descriptor of the write end of `pipe`, after it turns off `SIGPIPE` for it. A
    /// write to a pipe whose read end is closed then fails with `EPIPE` and does not stop the
    /// test process.
    /// - Parameter pipe: The pipe of the test.
    /// - Returns: The descriptor of the write end.
    /// - Throws: A `POSIXError` when `fcntl(2)` fails.
    private static func writeEndWithNoSignal(of pipe: Pipe) throws -> Int32 {
        let writeEnd = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        return writeEnd
    }

    /// Writes `probeByte` to `writeEnd` one time.
    /// - Parameter writeEnd: The descriptor of the write end of a pipe.
    /// - Returns: The return value of `write(2)` and the `errno` after it.
    private static func writeProbeByte(to writeEnd: Int32) -> WriteResult {
        var byte = probeByte
        errno = 0
        let bytesWritten = write(writeEnd, &byte, 1)
        return WriteResult(bytesWritten: bytesWritten, errorNumber: errno)
    }
}
