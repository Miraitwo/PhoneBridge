import AppKit
import SwiftUI

@main
struct PhoneBridgeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updateChecker = AppUpdateChecker()
    @State private var isFirstLaunchGuidePresented = false
    @State private var didCheckFirstLaunchGuide = false
    @State private var didStartAutomaticUpdateCheck = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear(perform: handleMainWindowAppeared)
                .sheet(isPresented: $isFirstLaunchGuidePresented) {
                    FirstLaunchGuideView {
                        isFirstLaunchGuidePresented = false
                        startAutomaticUpdateCheckIfNeeded()
                    }
                    .interactiveDismissDisabled()
                }
                .sheet(item: $updateChecker.availableUpdate) { update in
                    AppUpdateView(
                        update: update,
                        openRelease: { updateChecker.openRelease(update) },
                        dismiss: { updateChecker.availableUpdate = nil }
                    )
                }
                .alert(item: $updateChecker.notice) { notice in
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        dismissButton: .default(Text("好"))
                    )
                }
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
            CommandGroup(before: .help) {
                Button(updateChecker.isChecking ? "正在检查更新…" : "检查更新…") {
                    Task { await updateChecker.checkNow() }
                }
                .disabled(updateChecker.isChecking)

                Button("PhoneBridge 新手引导") {
                    isFirstLaunchGuidePresented = true
                }
            }
        }
    }

    private func handleMainWindowAppeared() {
        presentFirstLaunchGuideIfNeeded()
        if !isFirstLaunchGuidePresented {
            startAutomaticUpdateCheckIfNeeded()
        }
    }

    private func presentFirstLaunchGuideIfNeeded() {
        guard !didCheckFirstLaunchGuide else { return }
        didCheckFirstLaunchGuide = true
        guard FirstLaunchGuideState.shouldPresent() else { return }
        FirstLaunchGuideState.markPresented()
        isFirstLaunchGuidePresented = true
    }

    private func startAutomaticUpdateCheckIfNeeded() {
        guard !didStartAutomaticUpdateCheck else { return }
        didStartAutomaticUpdateCheck = true
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await updateChecker.checkAutomatically()
        }
    }
}
