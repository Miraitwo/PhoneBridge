import SwiftUI

struct AppUpdateView: View {
    let update: AvailableAppUpdate
    let openRelease: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 5) {
                    Text("发现 PhoneBridge 新版本")
                        .font(.title2.bold())
                    Text("当前 \(update.currentVersion)  →  最新 \(update.version)")
                        .foregroundStyle(.secondary)
                    if let publishedAt = update.publishedAt {
                        Text("发布于 \(publishedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            GroupBox("\(update.title) · 更新说明") {
                ScrollView {
                    Text(update.releaseNotes.isEmpty ? "该版本未填写更新说明。" : update.releaseNotes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 180, maxHeight: 320)
            }

            Text("PhoneBridge 只负责检查版本；安装包仍由 GitHub Release 页面下载，不会在后台自动安装。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("稍后") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("打开 GitHub Release") {
                    openRelease()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 380)
    }
}
