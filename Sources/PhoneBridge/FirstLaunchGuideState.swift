import Foundation

enum FirstLaunchGuideState {
    static let shownKey = "PhoneBridge.firstLaunchGuideShown.v1"

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: shownKey)
    }

    static func markPresented(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: shownKey)
    }
}
