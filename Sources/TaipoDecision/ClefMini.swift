import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import TaipoCore
import TaipoIME
import Tokenizers

/// Clef-style decision model, small enough for the IME (Spec 004 Behavior 2): a Qwen3-0.6B
/// backbone scores how natural "context + candidate" reads (prefill only, no generation);
/// that language score replaces the engine's coarse frequencies, while the engine keeps the
/// keyboard-typo cost. total = −edit penalty + λ · log P(candidate | context).
public actor ClefMini: CandidateDecider {
    public static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Taipo/models/Qwen3-0.6B-MLX-4bit")

    public enum LoadError: Error, CustomStringConvertible {
        case missingModel(URL)
        public var description: String {
            switch self { case let .missingModel(url): "model not found at \(url.path)" }
        }
    }

    /// Best of 0.25–4 on the Spec 004 eval corpus (zh-typo 66.8% → 87.5%, 2026-10-19).
    public static let defaultLambda = 2.0

    private let container: ModelContainer
    public let lambda: Double

    private init(container: ModelContainer, lambda: Double) {
        self.container = container
        self.lambda = lambda
    }

    /// Spec 004 D8: a missing directory is reported, never a crash.
    public static func load(directory: URL = defaultDirectory, lambda: Double = defaultLambda) async throws -> ClefMini {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw LoadError.missingModel(directory)
        }
        let container = try await loadModelContainer(from: directory, using: TransformersTokenizerLoader())
        return ClefMini(container: container, lambda: lambda)
    }

    public func choose(context: String, keys: String, candidates: [Candidate]) async throws -> Int? {
        try await decide(context: context, keys: keys, candidates: candidates).index
    }

    /// The choice plus each candidate's language score (Spec 007 inspector shows them).
    public func decide(context: String, keys: String, candidates: [Candidate]) async throws -> Decision {
        let considered = Array(candidates.prefix(DecisionPolicy.maxCandidates))
        guard considered.count > 1 else { return Decision(index: nil, scores: nil) }
        let lm = try await languageScores(context: context, texts: considered.map(\.text))
        let totals = zip(considered, lm).map { candidate, score in -Decoder.penalty(candidate.edits) + lambda * score }
        let best = totals.indices.max(by: { totals[$0] < totals[$1] || (totals[$0] == totals[$1] && $0 > $1) })
        return Decision(index: best, scores: lm)
    }

    /// Sum of token log-probabilities of each text after the context.
    public func languageScores(context: String, texts: [String]) async throws -> [Double] {
        let prefix = "以下是使用者正在輸入的一段文字：\n" + context
        return await container.perform { (model: ModelContext) -> [Double] in
            let prefixIds = model.tokenizer.encode(text: prefix, addSpecialTokens: false)
            return texts.map { text in
                let textIds = model.tokenizer.encode(text: text, addSpecialTokens: false)
                guard !textIds.isEmpty else { return -.infinity }
                let ids = prefixIds + textIds
                let logits = model.model(MLXArray(ids.map(Int32.init)).reshaped(1, ids.count), cache: nil)
                // Position i predicts token i+1; score the text tokens only.
                let predicted = logits[0, (prefixIds.count - 1)..<(ids.count - 1)]
                let logp = predicted - logSumExp(predicted, axis: -1, keepDims: true)
                let picked = takeAlong(logp, MLXArray(textIds.map(Int32.init)).reshaped(textIds.count, 1), axis: -1)
                return Double(picked.sum().item(Float.self))
            }
        }
    }
}

/// Bridges swift-transformers' tokenizer to MLXLMCommon (same mapping as mlx-swift-lm's macro).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
