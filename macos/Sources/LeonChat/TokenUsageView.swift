import SwiftUI

struct TokenUsageView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    private func total(_ field: KeyPath<ModelUsage, Int64>) -> Int64 {
        store.modelUsage.reduce(0) { $0 + $1[keyPath: field] }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Token 用量").font(.title2.bold())
            Text("当前服务累计用量，按服务商与模型汇总，包含所有会话、工作流、上下文压缩和归档总结调用。")
                .font(.callout).foregroundStyle(.secondary)
            if store.usageBusy { ProgressView("正在读取用量…").controlSize(.small) }
            if let error = store.usageError { Text(error).foregroundStyle(.red) }
            if let updated = store.usageLoadedAt {
                HStack(spacing: 28) {
                    metric("总 Token", total(\.totalTokens))
                    metric("输入", total(\.inputTokens))
                    metric("输出", total(\.outputTokens))
                }
                Text("已报告用量 \(total(\.reportedCalls).formatted()) 次 · 未报告用量 \(total(\.unreportedCalls).formatted()) 次")
                    .font(.caption).foregroundStyle(.secondary)
                let priced = store.modelUsage.compactMap(UsagePricing.estimate)
                if !priced.isEmpty {
                    Text("已匹配模型估算：" + UsagePricing.label(.init(low: priced.reduce(0) { $0 + $1.low }, high: priced.reduce(0) { $0 + $1.high })) + " USD")
                        .font(.headline)
                    if priced.count != store.modelUsage.count { Text("部分模型暂无可匹配价格，未计入以上金额。您可查看下方明细。") .font(.caption).foregroundStyle(.secondary) }
                }
                if store.modelUsage.isEmpty {
                    Text("暂无用量记录").frame(maxWidth: .infinity, minHeight: 110).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(store.modelUsage) { row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.provider + " · " + row.model).font(.headline).textSelection(.enabled)
                                    Text("总计 \(row.totalTokens.formatted()) · 输入 \(row.inputTokens.formatted()) · 输出 \(row.outputTokens.formatted()) Token")
                                        .font(.callout).textSelection(.enabled)
                                    Text("已报告 \(row.reportedCalls.formatted()) 次 · 未报告 \(row.unreportedCalls.formatted()) 次")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(UsagePricing.estimate(row).map { "估算 " + UsagePricing.label($0) + " USD" } ?? "暂无可匹配价格")
                                        .font(.callout)
                                }
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 280)
                }
                Text("读取于 " + updated.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("按 2026-11-19 官网公开文本价格估算：输入分别按全部缓存命中 / 全部未命中计算；DeepSeek 分别使用非高峰 / 高峰价格。历史缓存命中、计费时段、价格变动和未报告调用无法还原，金额不是账单；可能不含长上下文、工具及其他费用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Link("OpenAI 价格", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!); Link("DeepSeek 价格", destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!) }.font(.caption)
            HStack {
                Button("刷新") { Task { await store.loadUsage() } }.disabled(store.usageBusy)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 560)
        .task { await store.loadUsage() }
    }
    private func metric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}
