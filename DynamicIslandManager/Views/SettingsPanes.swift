import AppKit
import SwiftUI

// launch at login, the convert defaults, haptics, clearing activity, quitting
struct GeneralPane: View {
    @ObservedObject var activity: ActivityStore
    @AppStorage(ConvertDefaults.heicKey, store: AppDefaults.shared) private var heic = "keep"
    @AppStorage(ConvertDefaults.audioKey, store: AppDefaults.shared) private var audio = "keep"
    @AppStorage(ConvertDefaults.movieKey, store: AppDefaults.shared) private var movie = "keep"
    @AppStorage(Haptics.defaultsKey, store: AppDefaults.shared) private var haptics = true
    @State private var loginItem = LaunchAtLogin.isEnabled
    @State private var loginError = LaunchAtLogin.lastError
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if loginError == nil {
                    Toggle("Launch at login", isOn: Binding(get: { loginItem }, set: { on in
                        loginError = LaunchAtLogin.set(on)
                        loginItem = LaunchAtLogin.isEnabled
                    }))
                    .debugFrame("launchAtLogin")
                } else {
                    LabeledContent("Launch at login") {
                        Button("Open Login Items…") {
                            LaunchAtLogin.openSystemSettings()
                        }
                        .debugFrame("openLoginItems")
                    }
                    Text("macOS didn't let the app add itself, add it in Login Items instead.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Convert when dropped") {
                Picker("HEIC photos", selection: $heic) {
                    Text("Keep").tag("keep")
                    Text("JPEG").tag("jpeg")
                }
                .debugFrame("defaultHEIC")
                Picker("WAV and AIFF audio", selection: $audio) {
                    Text("Keep").tag("keep")
                    Text("M4A").tag("m4a")
                }
                Picker("MOV videos", selection: $movie) {
                    Text("Keep").tag("keep")
                    Text("MP4").tag("mp4")
                }
            }
            Section {
                Toggle("Haptics", isOn: $haptics)
                    .debugFrame("haptics")
                Text("A tap on a Force Touch trackpad when a drop lands and when a send goes through.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Activity") {
                    if confirmClear {
                        HStack {
                            Button("Cancel") {
                                confirmClear = false
                            }
                            .debugFrame("clearCancel")
                            Button("Clear \(activity.entries.count)") {
                                activity.clear()
                                confirmClear = false
                            }
                            .foregroundStyle(.red)
                            .debugFrame("clearConfirm")
                        }
                    } else {
                        Button("Clear activity") {
                            confirmClear = true
                        }
                        .disabled(activity.entries.isEmpty)
                        .debugFrame("clearActivity")
                    }
                }
                Text("The list of what was sent stays on this Mac, clearing it forgets the file names.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Quit Pigeonhole") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        // login items can change in system settings while this window lives on
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = LaunchAtLogin.isEnabled
            if loginItem {
                loginError = nil
            }
        }
        // a confirm left armed shouldn't greet the next open
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is SettingsWindow {
                confirmClear = false
            }
        }
    }
}

// who's signed in, the storage, and signing out
struct AccountPane: View {
    @ObservedObject var driveService: GoogleDriveService
    @ObservedObject var storage: StorageStatus
    let onSignOut: () -> Void
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("Google account") {
                LabeledContent("Signed in as", value: driveService.userEmail ?? "–")
                if let name = storage.about?.user?.displayName, !name.isEmpty {
                    LabeledContent("Name", value: name)
                }
            }
            Section("Storage") {
                if let about = storage.about {
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            Text(StorageText.summary(about))
                                .monospacedDigit()
                                .accessibilityValue(storage.isStale ? "not up to date" : "")
                            if about.limit != nil {
                                StorageBar(about: about)
                            }
                        }
                        .opacity(storage.isStale ? 0.55 : 1)
                        StorageLegend(about: about)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(storage.placeholder)
                        .foregroundStyle(.secondary)
                }
                Button("Manage storage…") {
                    LinkActions.openWeb(StorageText.manageURL)
                }
            }
            Section {
                if !driveService.isSignedIn {
                    // the sign-in window can be closed, this is the way back
                    Button("Sign in…") {
                        NotificationCenter.default.post(name: .showSignIn, object: nil)
                    }
                    .debugFrame("signIn")
                } else if confirmSignOut {
                    LabeledContent("Sign out of Google? The island hides until you sign in again.") {
                        HStack {
                            Button("Cancel") {
                                confirmSignOut = false
                            }
                            Button("Sign out") {
                                confirmSignOut = false
                                onSignOut()
                            }
                            .foregroundStyle(.red)
                            .debugFrame("signOutConfirm")
                        }
                    }
                } else {
                    Button("Sign out") {
                        confirmSignOut = true
                    }
                    .debugFrame("signOut")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            storage.refreshIfOld()
        }
        // same as general, a closed window forgets the confirm
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is SettingsWindow {
                confirmSignOut = false
            }
        }
    }
}

// the icon, the version and where the code lives
struct AboutPane: View {
    static let repo = URL(string: "https://github.com/tanay1kumar/Dynamic-Island-for-Mac")!

    // nil when a local Info.plist copied before the version keys has none
    private var version: String? {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Pigeonhole")
                .font(.title2.bold())
            if let version {
                Text(version)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Drop files on the notch and they go to the right Google Drive folder.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Link("github.com/tanay1kumar/Dynamic-Island-for-Mac", destination: Self.repo)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .groupedFormBackground()
    }
}

extension View {
    // a grouped form's background has no system color that matches in light and dark mode, so an empty one paints it
    func groupedFormBackground() -> some View {
        background {
            Form {}
                .formStyle(.grouped)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
