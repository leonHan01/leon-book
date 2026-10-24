import SwiftUI

struct EditorAttachmentRow: View {
    let media: NativeMedia
    let savedTimestamp: String?
    let onInsertTimestamp: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            NativeIcon.image(media.isVideo ? "video.fill" : media.isImage ? "photo.fill" : media.isAudio ? "waveform" : "doc.fill", size: 12)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Text(media.name)
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let savedTimestamp, media.isVideo {
                Button(action: onInsertTimestamp) {
                    Label(savedTimestamp, nativeIcon: "text.badge.plus")
                }
                .font(.caption.monospacedDigit())
                .buttonStyle(.borderless)
                .help("在正文光标处插入上次播放时间点")
            }

            Button(action: onRemove) {
                NativeIcon.image("xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除附件")
        }
    }
}
