import Foundation
import FoundationModels
import FoundationModelsCodeContext
import FoundationModelsRanker
import os

/// One generation call that a `FakeLanguageModel` answered.
struct FakeModelCall: Sendable, Equatable {
    /// The text of the instructions entry of the transcript of the call, or `nil` when the
    /// session has no instructions. For the selection tier this is the assembled prefix with one
    /// candidate block for each candidate.
    let instructions: String?

    /// The text of the newest prompt entry of the transcript of the call.
    let prompt: String?
}

/// One answer in the script of a `FakeLanguageModel`.
enum FakeModelAnswer: Sendable {
    /// Gives a `Selection` with these ids, in this order.
    case selecting([String])

    /// Gives this text as it is, for a test that needs an answer that does not decode.
    case text(String)

    /// Selects every candidate, in the order of the prompt. It reads the ids from the `id:` lines
    /// of the candidate blocks of the instructions, which is the format of the selection tier of
    /// FoundationModelsRanker. For a test that needs a search to return its retrieval result and
    /// does not test the selection.
    case selectingEveryCandidate

    /// Throws this error.
    case failure(any Error & Sendable)
}

/// The error that a `FakeLanguageModel` throws for itself.
enum FakeLanguageModelError: Error, Equatable {
    /// The model received more calls than its script has answers. This is a test bug: the script is
    /// too short for the code under test.
    case unscripted(answerCount: Int)
}

/// The script that each copy of one `FakeLanguageModel` plays, and the log of the calls that it
/// answered.
///
/// A class, because the identity of the script is the cache key of the executor, and because all
/// copies of one model share one log. The mutable state is under one lock, so the class is
/// `Sendable`.
final class FakeLanguageModelScript: Sendable {
    /// The answers, in call order.
    private let answers: [FakeModelAnswer]

    /// The answer of each call after the last of `answers`, or `nil` when such a call is a test
    /// bug.
    private let repeatedAnswer: FakeModelAnswer?

    /// The calls that the model answered, in order, under one lock.
    private let recordedCalls = OSAllocatedUnfairLock<[FakeModelCall]>(initialState: [])

    /// Makes a script of fixed answers.
    ///
    /// - Parameters:
    ///   - answers: The answers, in call order.
    ///   - repeatedAnswer: The answer of each call after the last of `answers`. When `nil`, such a
    ///     call throws `FakeLanguageModelError.unscripted(answerCount:)`.
    init(answers: [FakeModelAnswer], repeatedAnswer: FakeModelAnswer? = nil) {
        self.answers = answers
        self.repeatedAnswer = repeatedAnswer
    }

    /// The calls that the model answered, in order.
    var calls: [FakeModelCall] { recordedCalls.withLock { $0 } }

    /// Adds `call` to the log and gives the answer for it.
    ///
    /// - Parameter call: The call that the model answers.
    /// - Returns: The text of the answer for this call.
    /// - Throws: The error of a `.failure` answer, or `FakeLanguageModelError.unscripted(answerCount:)`.
    func answer(_ call: FakeModelCall) throws -> String {
        let index = recordedCalls.withLock { calls -> Int in
            calls.append(call)
            return calls.count - 1
        }
        guard let answer = answers.indices.contains(index) ? answers[index] : repeatedAnswer else {
            throw FakeLanguageModelError.unscripted(answerCount: answers.count)
        }
        switch answer {
        case .selecting(let ids):
            return try Self.selectionJSON(ids: ids)
        case .selectingEveryCandidate:
            return try Self.selectionJSON(ids: Self.candidateIDs(in: call.instructions ?? ""))
        case .text(let text):
            return text
        case .failure(let error):
            throw error
        }
    }

    /// The prefix of the line of a candidate block that holds the id of the candidate.
    private static let candidateIDLinePrefix = "id: "

    /// The ids of the candidate blocks of `instructions`, in order.
    private static func candidateIDs(in instructions: String) -> [String] {
        instructions.split(separator: "\n").compactMap { line in
            line.hasPrefix(candidateIDLinePrefix) ? String(line.dropFirst(candidateIDLinePrefix.count)) : nil
        }
    }

    /// The JSON that decodes to a `Selection` with `ids`.
    private static func selectionJSON(ids: [String]) throws -> String {
        let data = try JSONEncoder().encode(["ids": ids])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A FoundationModels `LanguageModel` that loads nothing and answers each generation call from a
/// script, in order. It writes each call to the log of the script first.
///
/// All copies of one model share one script, so a test keeps the model that it gave to the code
/// under test and reads `calls` from it. No test of this package uses a real model.
struct FakeLanguageModel: LanguageModel {
    /// The executor that plays the script.
    typealias Executor = FakeLanguageModelExecutor

    /// The script that the model plays.
    let script: FakeLanguageModelScript

    /// Makes a model that plays `answers`, in call order.
    ///
    /// - Parameters:
    ///   - answers: The answers, in call order.
    ///   - repeatedAnswer: The answer of each call after the last of `answers`. When `nil`, such a
    ///     call throws `FakeLanguageModelError.unscripted(answerCount:)`.
    init(answers: [FakeModelAnswer], repeatedAnswer: FakeModelAnswer? = nil) {
        script = FakeLanguageModelScript(answers: answers, repeatedAnswer: repeatedAnswer)
    }

    /// Makes a model that selects every candidate of each call, in the order of the prompt.
    ///
    /// - Returns: The model.
    static func selectingEveryCandidate() -> FakeLanguageModel {
        FakeLanguageModel(answers: [], repeatedAnswer: .selectingEveryCandidate)
    }

    /// Makes a model that selects `ids` in its first call.
    ///
    /// - Parameter ids: The ids of the answer, in order.
    init(selecting ids: [String]) {
        self.init(answers: [.selecting(ids)])
    }

    /// Makes a model that throws `error` in its first call.
    ///
    /// - Parameter error: The error of the first call.
    init(throwing error: any Error & Sendable) {
        self.init(answers: [.failure(error)])
    }

    /// Guided generation, so a session can ask for a `Generable` type such as `Selection`.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration])
    }

    /// The cache key of the executor: the identity of the script.
    var executorConfiguration: FakeLanguageModelExecutor.Configuration {
        FakeLanguageModelExecutor.Configuration(script: ObjectIdentifier(script))
    }

    /// The calls that the model answered, in order.
    var calls: [FakeModelCall] { script.calls }

    /// Makes a selection factory that gives this model to every search, and counts each use.
    ///
    /// - Parameter factoryCalls: Receives the ids of the candidates of each use of the factory.
    /// - Returns: The factory.
    func factory(recording factoryCalls: FactoryCallLog = FactoryCallLog()) -> SelectionFactory {
        { ids in
            factoryCalls.record(ids)
            return SelectionConfig(model: self)
        }
    }
}

/// The log of the ids that a selection factory received, one entry for each use.
final class FactoryCallLog: Sendable {
    /// The ids of each use, in order, under one lock.
    private let recordedIDs = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    /// Adds the ids of one use.
    ///
    /// - Parameter ids: The ids that the factory received.
    func record(_ ids: [String]) {
        recordedIDs.withLock { $0.append(ids) }
    }

    /// The ids of each use of the factory, in order.
    var uses: [[String]] { recordedIDs.withLock { $0 } }
}

/// The executor of `FakeLanguageModel`.
struct FakeLanguageModelExecutor: LanguageModelExecutor {
    /// The cache key that the SDK makes and reuses the executor by.
    struct Configuration: Sendable, Hashable {
        /// The identity of the script that the model plays.
        let script: ObjectIdentifier
    }

    /// The model that this executor runs for.
    typealias Model = FakeLanguageModel

    /// The token count of the one emitted fragment. The double meters nothing.
    private static let emittedTokenCount = 1

    /// Makes an executor. The configuration holds nothing that the executor reads: the script
    /// arrives with the model on each call.
    ///
    /// - Parameter configuration: The cache key.
    /// - Throws: Never. `throws` comes from the `LanguageModelExecutor` requirement.
    init(configuration: Configuration) throws {}

    /// Writes the call to the log of the script, and emits the answer of the script.
    ///
    /// - Parameters:
    ///   - request: The generation request with the full transcript.
    ///   - model: The model with the script.
    ///   - channel: The channel that the answer goes into.
    /// - Throws: The error of the script for this call.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: FakeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let call = FakeModelCall(
            instructions: Self.instructionsText(in: request.transcript),
            prompt: Self.lastPromptText(in: request.transcript)
        )
        let text = try model.script.answer(call)
        await channel.send(.response(action: .appendText(text, tokenCount: Self.emittedTokenCount)))
    }

    /// The text of the first instructions entry of `transcript`.
    private static func instructionsText(in transcript: Transcript) -> String? {
        transcript.lazy.compactMap { entry -> String? in
            guard case .instructions(let instructions) = entry else { return nil }
            return text(of: instructions.segments)
        }.first
    }

    /// The text of the newest prompt entry of `transcript`.
    private static func lastPromptText(in transcript: Transcript) -> String? {
        transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return text(of: prompt.segments)
        }.last
    }

    /// The text of the text segments of `segments`, joined.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined()
    }
}

/// The error of `unusedSelection`: a test that gives it runs no search that needs a model.
struct SelectionNotExpectedError: Error, Equatable {}

/// The selection factory of a test that makes a `CodeContext` or a `CodeContextManager` and runs no
/// `searchCode`. It throws when something applies it, so a test that starts to search without a
/// scripted model fails at once.
let unusedSelection: SelectionFactory = { _ in throw SelectionNotExpectedError() }

/// Makes the selection factory of a test that runs `searchCode` and needs its retrieval result
/// back: the fake model selects every candidate, in retrieval order.
///
/// - Returns: A factory over a new `FakeLanguageModel` that selects every candidate.
func selectingEveryCandidateFactory() -> SelectionFactory {
    FakeLanguageModel.selectingEveryCandidate().factory()
}
