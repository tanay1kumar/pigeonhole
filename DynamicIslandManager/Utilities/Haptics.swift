import AppKit

// trackpad taps on drop and on a send, only felt on a force touch trackpad
enum Haptics {
    // settings switch, on unless turned off
    static let defaultsKey = "haptics"

    static var isEnabled: Bool {
        #if DEBUG
        if let enabledOverride {
            return enabledOverride
        }
        #endif
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    #if DEBUG
    // tests count taps here, and switch haptics without writing defaults
    static var performed: [NSHapticFeedbackManager.FeedbackPattern] = []
    static var enabledOverride: Bool?
    #endif

    static func dropAccepted() {
        perform(.alignment)
    }

    static func sent() {
        perform(.levelChange)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled else { return }
        #if DEBUG
        performed.append(pattern)
        #endif
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
