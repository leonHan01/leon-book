import Foundation
@testable import LeonChat

@main struct ContextMemoryChecks {
    static func main() throws {
        let legacy = #"{"conversationId":"room","recentRounds":10,"inputTokenBudget":5500,"topicStartedAfter":0,"agents":[{"agentId":"a","agentName":"助手","summary":"","lastCompressedAt":0,"estimatedInputTokens":0,"retainedRounds":0,"phase":""}]}"#
        let decoder = JSONDecoder()
        let old = try decoder.decode(ConversationContext.self, from: Data(legacy.utf8))
        precondition(old.compressionMode == nil && old.agents[0].facts == nil)
        let current = #"{"conversationId":"room","recentRounds":10,"inputTokenBudget":5500,"topicStartedAfter":0,"compressionMode":"token","agents":[{"agentId":"a","agentName":"助手","summary":"行程规划中","lastCompressedAt":123,"estimatedInputTokens":4600,"retainedRounds":30,"phase":"","facts":[{"agentId":"a","subjectId":"u","speaker":"Leon","kind":"fact","key":"travel_budget","value":"8000元","sourceMessageId":42,"evidence":"预算改成8000元","deleted":false}],"retrievedRounds":2,"compressionFallback":true}]}"#
        let info = try decoder.decode(ConversationContext.self, from: Data(current.utf8))
        precondition(info.compressionMode == "token")
        precondition(info.agents[0].facts?.first?.value == "8000元")
        precondition(info.agents[0].facts?.first?.sourceMessageId == 42)
        precondition(info.agents[0].retrievedRounds == 2 && info.agents[0].compressionFallback == true)
        let roundtrip = try decoder.decode(ConversationContext.self, from: JSONEncoder().encode(info))
        precondition(roundtrip.agents[0].facts?.first?.id == "u:fact:travel_budget")
        print("PASS context memory: legacy response, structured facts, provenance, retrieval and fallback")
    }
}
