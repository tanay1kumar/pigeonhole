#if DEBUG
import AppKit

// settings, the menu bar item and the keyboard on the real app
// settings write the scratch domain here, never the user's own
extension ScenarioRunner {
    // no dock icon, the menu bar menu, every pane, and the general settings doing what they say
    func settings() async {
        check(NSApp.activationPolicy() == .accessory && Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
              "no dock icon (activation policy \(NSApp.activationPolicy().rawValue))")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        check(version.map { !$0.isEmpty && !$0.contains("$") } ?? false, "About has a version (\(version ?? "none"))")
        let loginItem = LaunchAtLogin.isEnabled
        guard let menu = app.menuBarItem else {
            check(false, "the app has a menu bar item")
            return
        }
        check(menu.menuTitles == ["Settings…", "Activity", "", "Quit Dynamic Island"], "the menu bar menu (\(menu.menuTitles))")

        // activity from the menu opens the island there and holds it a moment with the pointer away
        pointerOutside()
        menu.debugChoose("Activity")
        let opened = await waitFor(2) { self.model.isExpanded && self.model.content == .activity }
        check(opened != nil, "Activity opens the island on its panel (\(format(opened)))")
        try? await Task.sleep(for: .seconds(1.5))
        check(model.isExpanded, "and it stays open without the pointer")
        let closed = await waitFor(9) { self.model.currentState == .collapsed }
        check(closed != nil, "then lets go (\(format(closed)))")

        // a first open reads the pane used last, before anything can save general over it
        // an earlier scenario's window would be reused, so this one starts from none
        app.settingsWindow?.close()
        app.settingsWindow = nil
        AppDefaults.shared.set(SettingsPane.about.rawValue, forKey: AppDefaults.settingsPaneKey)
        menu.debugChoose("Settings…")
        let shown = await waitFor(3) { self.app.settingsWindow?.isVisible == true }
        check(shown != nil, "Settings… opens the Settings window")
        guard let window = app.settingsWindow else { return }
        check(window.currentPane == .about, "it opens on the pane used last (\(window.currentPane?.title ?? "none"))")
        for pane in SettingsPane.allCases {
            window.show(pane)
            try? await Task.sleep(for: .milliseconds(300))
            check(window.title == pane.title && window.currentPane == pane, "\(pane.title) pane, titled \(window.title)")
            await snapshot("pane-\(pane.rawValue)", of: window)
        }
        check(AppDefaults.shared.string(forKey: AppDefaults.settingsPaneKey) == SettingsPane.about.rawValue,
              "it remembers the last pane (in the scratch domain)")
        // light mode as well, only this window, the backgrounds have to match there too
        window.appearance = NSAppearance(named: .aqua)
        for pane in [SettingsPane.general, .destinations, .about] {
            window.show(pane)
            await snapshot("pane-\(pane.rawValue)-light", of: window)
        }
        window.appearance = nil

        // a convert default changes the pill on the next drop
        window.show(.general)
        check(await pick("JPEG", fromMenu: "defaultHEIC", press: { self.clickInSettings("defaultHEIC", trailing: true) }), "picked JPEG for HEIC photos")
        let saved = await waitFor(2) { AppDefaults.shared.string(forKey: ConvertDefaults.heicKey) == "jpeg" }
        check(saved != nil, "the default is saved")
        window.close()
        pointerInside()
        await dropAndWait([sunflower])
        check(model.suggestions.first?.convertTo == .jpeg, "the next drop's pill starts at JPEG")
        _ = await tap("dismiss")
        _ = await waitFor(2) { self.model.cardState == .idle }

        // haptics off means no tap on a drop
        showSettings(.general)
        check(await tapInSettings("haptics", trailing: true), "clicked Haptics")
        let off = await waitFor(2) { AppDefaults.shared.object(forKey: Haptics.defaultsKey) as? Bool == false }
        check(off != nil, "haptics are off")
        window.close()
        Haptics.performed = []
        await dropAndWait([receiptPNG()])
        check(Haptics.performed.isEmpty, "a drop doesn't tap with haptics off (\(Haptics.performed.count))")
        _ = await tap("dismiss")
        _ = await waitFor(2) { self.model.cardState == .idle }

        // clear activity, with its confirm
        if let store = app.activityStore {
            // two, so Cancel is checked against a list that isn't just this one
            store.record([ActivityEntry(kind: .sent, name: "scenario.pdf", bytes: 1, driveFileId: "scenario", destinationName: "flowers")])
            store.record([ActivityEntry(kind: .sent, name: "scenario-2.pdf", bytes: 1, driveFileId: "scenario-2", destinationName: "flowers")])
            // an all run gets here with the earlier scenarios' sends still listed
            let before = store.entries.count
            showSettings(.general)
            check(await tapInSettings("clearActivity"), "clicked Clear activity")
            // each button sits where the last one was, a quick second click there would be a double click
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            check(await tapInSettings("clearCancel"), "clicked Cancel")
            let kept = await waitFor(2) { DebugFrames.frames["clearConfirm"] == nil }
            check(kept != nil && store.entries.count == before, "Cancel keeps the activity (\(store.entries.count) of \(before))")
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            check(await tapInSettings("clearActivity"), "clicked Clear activity again")
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            check(await tapInSettings("clearConfirm"), "and confirmed")
            let cleared = await waitFor(2) { store.entries.isEmpty }
            check(cleared != nil, "activity is empty")
        }

        // command v pastes into a hint, the menu bar is hidden but its key equivalents still work
        if let folders = folders() {
            showSettings(.destinations)
            let field = "hint-\(folders.flowers.name)"
            let board = NSPasteboard.general
            let savedBoard = savePasteboard(board)
            board.clearContents()
            board.setString("pasted petals", forType: .string)
            let ours = board.changeCount
            if await type("", into: field, in: window, pressReturn: false), let input = textField(at: field, in: window) {
                await press(9, "v", command: true, to: window)
                let pasted = await waitFor(2) { (window.fieldEditor(false, for: input) as? NSTextView)?.string == "pasted petals" }
                // the edit menu sends paste to the key window, a locked screen leaves none
                if screenLocked {
                    print("  skip: the screen is locked, command V needs a key window (main menu \(NSApp.mainMenu?.items.map(\.title) ?? []))")
                } else {
                    check(pasted != nil, "command V pasted into the hint field")
                }
                // the hint goes back to none, a blur would save the pasted words
                _ = await type("", into: field, in: window, pressReturn: true)
                _ = await waitFor(2) { self.app.destinationStore.destinations.first { $0.id == folders.flowers.id }?.hint == nil }
            } else {
                check(false, "focused the hint field")
            }
            if board.changeCount == ours {
                restorePasteboard(board, savedBoard)
            }
        }

        // account shows who and how much
        showSettings(.account)
        let account = await waitFor(10) { self.drive.userEmail != nil && self.app.storageStatus?.about != nil }
        check(account != nil, "Account has the email and the quota")
        await snapshot("account-filled", of: window)
        check(LaunchAtLogin.isEnabled == loginItem, "the real login item is untouched")
        window.close()
    }

    // keys while the island is key, the frontmost app never changes
    func keys() async {
        guard let folders = folders() else { return }
        // settings just put this app in front, the checks need the user's app there
        if NSRunningApplication.current.isActive, let previous = frontAtStart {
            NSApp.yieldActivation(to: previous)
            previous.activate(from: .current, options: [])
            _ = await waitFor(2) { !NSRunningApplication.current.isActive }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // locked nothing can come forward or be key, and with this app in front there's nothing to keep
        let canCheckFront = !screenLocked && front != NSRunningApplication.current.processIdentifier
        pointerInside()
        await dropAndWait([receiptPNG()])
        if let row = model.suggestions.first {
            model.choose(folders.receipts, for: row.id)
            // return is the send button, which only a confident card has
            model.suggestions[0].level = .confident
        }
        pointerInside()
        let key = await waitFor(2) { self.window.isKeyWindow }
        // a locked screen keeps every window from being key, the keys below still reach the island
        if screenLocked {
            print("  skip: the screen is locked, nothing can be key")
        } else {
            check(key != nil, "the island takes the keyboard while the card is under the pointer (\(format(key)))")
        }

        await press(36, "\r")
        let ids = await waitForSent("Return sent it")
        check(!ids.isEmpty, "one upload")
        // the sent card is shorter than the one under the pointer, the pointer didn't move so the keys stay
        if !screenLocked {
            check(window.isKeyWindow, "the island keeps the keyboard when the card shrinks under a still pointer")
        }

        let board = NSPasteboard.general
        let savedBoard = savePasteboard(board)
        let before = board.changeCount
        await press(8, "c", command: true)
        let link = model.suggestions.first(where: \.isSent)?.driveLink?.absoluteString
        let copied = await waitFor(2) { link != nil && board.string(forType: .string) == link }
        check(copied != nil, "command C copied its link")
        let ours = board.changeCount

        await press(6, "z", command: true)
        let undone = await waitFor(10) { self.model.cardState == .suggesting }
        check(undone != nil, "command Z undid it (\(format(undone)))")
        // reset() still deletes it if undo didn't
        if undone != nil {
            pendingDeletes.removeAll { ids.contains($0) }
        }
        pointerInside()

        await press(53, "\u{1b}")
        let dismissed = await waitFor(2) { self.model.cardState == .idle }
        check(dismissed != nil, "Escape put the card away")

        model.show(.activity)
        pointerInside()
        _ = await waitFor(2) { self.window.isKeyWindow }
        // a held key's repeats are eaten, only the first press does something
        await press(53, "\u{1b}", repeating: true)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.content == .activity, "a repeated Escape does nothing")
        await press(53, "\u{1b}")
        let back = await waitFor(2) { self.model.content == .home }
        check(back != nil, "Escape on a panel goes back home")

        // the tiles have nothing to type at, the keyboard goes back
        let released = await waitFor(2) { !self.window.isKeyWindow && NSApp.keyWindow !== self.window }
        if canCheckFront {
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "the frontmost app never changed")
            check(released != nil, "home gives the keyboard back (\(format(released)))")
            // command h while the island borrows the keys is the app in front's, this app must not hide
            model.show(.activity)
            pointerInside()
            if await waitFor(2, { self.window.isKeyWindow }) != nil {
                await press(4, "h", command: true)
                try? await Task.sleep(for: .milliseconds(300))
                check(!NSApp.isHidden, "command H while the island has the keys doesn't hide this app")
                if NSApp.isHidden {
                    NSApp.unhide(nil)
                }
            } else {
                check(false, "the island took the keyboard for the command H check")
            }
            await press(53, "\u{1b}")
            _ = await waitFor(2) { self.model.content == .home }
        } else {
            print("  skip: the frontmost app and the keyboard can't change here (locked \(screenLocked))")
        }

        model.show(.activity)
        pointerInside()
        _ = await waitFor(2) { self.window.isKeyWindow }
        await press(43, ",", command: true)
        let settings = await waitFor(3) { self.app.settingsWindow?.isVisible == true }
        check(settings != nil, "command comma opens Settings")
        // with settings in front the island hands the keyboard back to it, not to nobody
        // command comma closed the island, a panel opens it again
        if screenLocked {
            print("  skip: the screen is locked, Settings can't be key to get the keyboard back")
        } else if let settingsWindow = app.settingsWindow {
            _ = await waitFor(2) { settingsWindow.isKeyWindow }
            model.show(.activity)
            pointerInside()
            let took = await waitFor(2) { self.window.isKeyWindow }
            pointerOutside()
            let returned = await waitFor(2) { settingsWindow.isKeyWindow }
            check(took != nil && returned != nil, "Settings gets the keyboard back from the island (took \(format(took)), back \(format(returned)))")
        }
        app.settingsWindow?.close()

        // an unmoved count means command c wrote nothing, the pasteboard is still the user's
        if ours != before && board.changeCount == ours {
            restorePasteboard(board, savedBoard)
        }
    }

    var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // a key down and up, as the keyboard would send them, to the island unless told
    // posted keys wait in the queue until the main actor yields, so this waits for them before the next step changes what's showing
    private func press(_ keyCode: UInt16, _ characters: String, command: Bool = false, repeating: Bool = false, to target: NSWindow? = nil) async {
        let number = (target ?? window).windowNumber
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: command ? .command : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: repeating && type == .keyDown, keyCode: keyCode) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func showSettings(_ pane: SettingsPane) {
        app.showSettings(pane)
    }

    // a click on a pane's control once it's laid out
    private func tapInSettings(_ control: String, trailing: Bool = false) async -> Bool {
        guard await waitFor(2, { DebugFrames.frames[control] != nil }) != nil else {
            print("  no frame for \(control)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(400))
        return clickInSettings(control, trailing: trailing)
    }

    // a form row's switch or menu sits at its trailing end
    func clickInSettings(_ control: String, trailing: Bool = false) -> Bool {
        guard let window = app.settingsWindow else { return false }
        return click(control, in: window, trailing: trailing)
    }
}
#endif
