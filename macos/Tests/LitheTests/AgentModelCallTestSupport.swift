import Foundation
@testable import LitheAgentConversationModule

extension AgentModelCall {
    /// The Host contribution of one successful streamed conversation step,
    /// described in the raw `modelCall.call` shape for readable view fixtures.
    /// Accounting rules for other calls are covered by the shared fixture.
    static func streamedStep(_ call: [String: Any]) -> Self? {
        guard call["status"] as? Int == 200, call["streaming"] as? Bool == true, call["auxiliary"] == nil,
              let duration = call["durationMs"] as? Int else { return nil }
        let usage = call["usage"] as? [String: Int]
        let firstToken = call["firstTokenMs"] as? Int
        let measured = firstToken.map { usage != nil && duration > $0 } ?? false
        var statistics: [String: Any] = [
            "requests": 1, "steps": 1, "failedSteps": 0, "nonStreamingSteps": 0, "durationMs": duration,
            "inputTokens": usage?["inputTokens"] ?? 0, "cacheReadTokens": usage?["cacheReadTokens"] ?? 0,
            "cacheWriteTokens": usage?["cacheWriteTokens"] ?? 0, "outputTokens": usage?["outputTokens"] ?? 0,
            "callsWithUsage": usage == nil ? 0 : 1,
            "firstTokenMs": firstToken ?? 0, "firstTokenCount": firstToken == nil ? 0 : 1,
            "generationMs": measured ? duration - (firstToken ?? 0) : 0,
            "generatedTokens": measured ? usage?["outputTokens"] ?? 0 : 0]
        if let context = call["context"] { statistics["context"] = context }
        return parse(statistics)
    }
}
