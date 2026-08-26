import SwiftUI

struct EmbeddedAndroidMirrorView: View {
    @ObservedObject var service: EmbeddedAndroidMirrorService

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            if let frame = service.latestFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if service.state.isActive {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "apps.iphone")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    Text(service.state.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
                .padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: service.state.isCapturing ? 4 : 12))
        .overlay {
            RoundedRectangle(cornerRadius: service.state.isCapturing ? 4 : 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Android 内嵌投屏画面")
        .accessibilityValue(service.state.message)
    }
}
