import AppKit
import SwiftUI

@MainActor
final class IPhoneMirrorWindowService: NSObject, NSWindowDelegate {
    private let mirrorService: EmbeddedIPhoneMirrorService
    private var mirrorWindow: NSWindow?

    init(mirrorService: EmbeddedIPhoneMirrorService) {
        self.mirrorService = mirrorService
        super.init()
    }

    func show(receiverName: String) {
        let title = "\(receiverName) · iPhone 投屏"
        if let mirrorWindow {
            mirrorWindow.title = title
            ensureUsefulFrame(for: mirrorWindow)
            if mirrorWindow.isMiniaturized {
                mirrorWindow.deminiaturize(nil)
            }
            mirrorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = EmbeddedIPhoneMirrorView(service: mirrorService)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 320, height: 480)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        let frameName = "PhoneBridge.iPhoneMirrorWindow"
        let restoredFrame = window.setFrameUsingName(frameName)
        if !restoredFrame {
            window.center()
        }
        ensureUsefulFrame(for: window)
        window.setFrameAutosaveName(frameName)
        mirrorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        mirrorWindow?.close()
        mirrorWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === mirrorWindow else { return }
        mirrorWindow = nil
    }

    private func ensureUsefulFrame(for window: NSWindow) {
        guard window.frame.width < 320 || window.frame.height < 480 else { return }
        window.setContentSize(NSSize(width: 430, height: 720))
        window.center()
    }
}
