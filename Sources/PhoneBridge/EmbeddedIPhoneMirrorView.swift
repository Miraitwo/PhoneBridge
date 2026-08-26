import SwiftUI

struct EmbeddedIPhoneMirrorView: View {
    @ObservedObject var service: EmbeddedIPhoneMirrorService

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            if let frame = service.latestFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if service.latestFrame == nil {
                VStack(spacing: 12) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: statusSymbol)
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
        .clipShape(RoundedRectangle(cornerRadius: service.state.isRunning ? 4 : 12))
        .overlay {
            RoundedRectangle(cornerRadius: service.state.isRunning ? 4 : 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iPhone 投屏画面")
        .accessibilityValue(service.state.message)
    }

    private var isWorking: Bool {
        switch service.state {
        case .startingAirPlayReceiver, .startingEmbeddedReceiver, .waitingForIPhone:
            return true
        default:
            return false
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "iphone.gen3"
        }
    }
}
