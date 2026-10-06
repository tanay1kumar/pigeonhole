import Foundation

// the defaults settings reads and writes, the user's own in the real app
// scenario runs get the scratch domain so a check never changes a real setting
enum AppDefaults {
    static let settingsPaneKey = "settingsPane"

    static let shared: UserDefaults = {
        #if DEBUG
        if let scratch = DebugScenarios.scratchDefaults {
            return scratch
        }
        #endif
        return .standard
    }()
}
