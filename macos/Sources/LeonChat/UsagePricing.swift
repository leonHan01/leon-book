import Foundation

/// Current public text-token rates, USD per million tokens, checked 2026-11-19.
/// Input cache splits and DeepSeek peak hours are not present in historical totals.
enum UsagePricing {
    struct Rate { let lowInput: Double; let highInput: Double; let lowOutput: Double; let highOutput: Double }
    struct Estimate { let low: Double; let high: Double }
    static let rates: [String: Rate] = [
        "openai:gpt-4o": Rate(lowInput: 1.25, highInput: 2.50, lowOutput: 10, highOutput: 10),
        "openai:gpt-4.1": Rate(lowInput: 0.50, highInput: 2, lowOutput: 8, highOutput: 8),
        "openai:gpt-5.1": Rate(lowInput: 0.125, highInput: 1.25, lowOutput: 10, highOutput: 10),
        "openai:gpt-5.2": Rate(lowInput: 0.175, highInput: 1.75, lowOutput: 14, highOutput: 14),
        "openai:gpt-4o-mini": Rate(lowInput: 0.075, highInput: 0.15, lowOutput: 0.60, highOutput: 0.60),
        "openai:gpt-4.1-mini": Rate(lowInput: 0.10, highInput: 0.40, lowOutput: 1.60, highOutput: 1.60),
        "openai:gpt-5-mini": Rate(lowInput: 0.025, highInput: 0.25, lowOutput: 2, highOutput: 2),
        "openai:gpt-5.4": Rate(lowInput: 0.25, highInput: 2.50, lowOutput: 15, highOutput: 15),
        "openai:gpt-5.4-mini": Rate(lowInput: 0.075, highInput: 0.75, lowOutput: 4.50, highOutput: 4.50),
        "openai:gpt-6-astra": Rate(lowInput: 1, highInput: 10, lowOutput: 50, highOutput: 50),
        "openai:gpt-6.1-sol": Rate(lowInput: 0.10, highInput: 2, lowOutput: 10, highOutput: 10),
        "deepseek:deepseek-flash": Rate(lowInput: 0.003, highInput: 0.30, lowOutput: 0.60, highOutput: 1.20),
        "deepseek:deepseek-v4-pro": Rate(lowInput: 0.022, highInput: 1.32, lowOutput: 1.98, highOutput: 3.96)
    ]
    static func estimate(_ row: ModelUsage) -> Estimate? {
        guard row.inputTokens >= 0, row.outputTokens >= 0, let rate = rates[row.provider.lowercased() + ":" + row.model.lowercased()] else { return nil }
        let input = Double(row.inputTokens) / 1_000_000, output = Double(row.outputTokens) / 1_000_000
        return Estimate(low: input * rate.lowInput + output * rate.lowOutput, high: input * rate.highInput + output * rate.highOutput)
    }
    static func money(_ amount: Double) -> String { amount > 0 && amount < 0.0001 ? "<$0.0001" : String(format: "$%.4f", amount) }
    static func label(_ estimate: Estimate) -> String { "\(money(estimate.low)) – \(money(estimate.high))" }
}
