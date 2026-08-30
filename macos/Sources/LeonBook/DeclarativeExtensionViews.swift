import LeonBookExtensionKit
import SwiftUI

struct NativeDeclarativeRendererView: View {
    let block: DeclarativeRenderedBlock
    @Environment(\.nativeReadingTypography) private var typography

    var body: some View {
        switch block.style {
        case .card:
            content
                .padding(14)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)) }
        case .callout:
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4)
                content
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "quote.opening")
                    .foregroundStyle(.secondary)
                content
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !block.title.isEmpty {
                Label(block.title, systemImage: block.icon)
                    .font(.callout.weight(.semibold))
            }
            Text(block.body)
                .font(typography.bodyFont.swiftUIFont(size: typography.fontSize))
                .lineSpacing(typography.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text("由 \(block.extensionName) 声明式渲染")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.extensionName) 扩展内容")
    }
}

struct NativeDeclarativeExtensionSettingsPanel: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("扩展目录") {
                Text(model.declarativeExtensionDirectoryURL.path)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            LabeledContent("状态") { Text(model.declarativeExtensionStatus) }

            HStack {
                Button("打开扩展目录") { model.openDeclarativeExtensionDirectory() }
                Button("重新加载") { model.reloadDeclarativeExtensions() }
            }

            if model.declarativeExtensions.packages.isEmpty,
               model.declarativeExtensions.diagnostics.isEmpty {
                Text("把包含 extension.json 的扩展包文件夹放入此目录，然后重新加载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.declarativeExtensions.packages) { package in
                Toggle(isOn: Binding(
                    get: { model.declarativeExtensions.isEnabled(package.id) },
                    set: { model.setDeclarativeExtensionEnabled($0, extensionID: package.id) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(package.manifest.name)
                            Text("v\(package.manifest.version)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !package.manifest.description.isEmpty {
                            Text(package.manifest.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(model.declarativeExtensionCapabilities(package))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !model.declarativeExtensions.diagnostics.isEmpty {
                DisclosureGroup("未加载的扩展包（\(model.declarativeExtensions.diagnostics.count)）") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.declarativeExtensions.diagnostics) { diagnostic in
                            Label {
                                Text("\(diagnostic.packageName)：\(diagnostic.message)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            } icon: {
                                Image(systemName: "exclamationmark.shield")
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Text("扩展只可声明命令、静态模板变量、用户选取文件的导入器、围栏文本渲染器和纯 Base 公式。LeonBook 不加载动态库，不执行 JavaScript、Shell 或扩展提供的原生代码；不安全清单会整包拒绝。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
