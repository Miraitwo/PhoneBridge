import AppKit
import SwiftUI

@main
struct PhoneBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("刷新设备") {
                    Task { await model.refreshDevices() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
