#if DEBUG
import AppKit

// the keyboard table and the menu bar's hold on the island
enum SettingsTests: TestSuite {
    static let name = "Settings"

    static func event(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode)!
    }

    static var tests: [TestCase] {
        [
            TestCase("return, escape and the command keys are read, nothing else") { t in
                t.expectEqual(IslandKey(event(36, "\r")), .returnKey)
                t.expectEqual(IslandKey(event(76, "\u{3}")), .returnKey, "the keypad's enter")
                t.expectEqual(IslandKey(event(53, "\u{1b}")), .escape)
                t.expectEqual(IslandKey(event(6, "z", .command)), .undo)
                t.expectEqual(IslandKey(event(8, "c", .command)), .copy)
                t.expectEqual(IslandKey(event(43, ",", .command)), .settings)
                t.expect(IslandKey(event(6, "z", [.command, .shift])) == nil, "redo isn't the island's")
                t.expect(IslandKey(event(6, "z")) == nil, "a plain letter isn't")
                t.expect(IslandKey(event(36, "\r", .option)) == nil, "option return isn't")
                t.expect(IslandKey(event(9, "v", .command)) == nil, "paste isn't")
                // with command held a russian layout types latin, the letter ignoring modifiers is cyrillic
                t.expectEqual(IslandKey(event(6, "z", .command, ignoring: "\u{44f}")), .undo, "command z on a russian layout")
            },
            TestCase("quit and hide are caught for the app in front, lock screen and log out aren't") { t in
                t.expect(IslandKey.isAppMenuKey(event(12, "q", .command)), "command q")
                t.expect(IslandKey.isAppMenuKey(event(4, "h", .command)), "command h")
                t.expect(IslandKey.isAppMenuKey(event(4, "\u{2d9}", [.command, .option], ignoring: "h")), "option command h")
                t.expect(IslandKey.isAppMenuKey(event(12, "q", .command, ignoring: "\u{439}")), "command q on a russian layout")
                t.expect(!IslandKey.isAppMenuKey(event(12, "q", [.command, .control])), "lock screen isn't")
                t.expect(!IslandKey.isAppMenuKey(event(12, "q", [.command, .shift])), "log out isn't")
                t.expect(!IslandKey.isAppMenuKey(event(12, "q")), "a plain q isn't")
                t.expect(IslandKey.swallowsAppMenuKey(event(12, "q", .command), thisAppInFront: false), "eaten with another app in front")
                t.expect(!IslandKey.swallowsAppMenuKey(event(12, "q", .command), thisAppInFront: true), "this app's own quit works when it's in front")
            },
            TestCase("each key does what the table says for what's showing") { t in
                let s = try CardTests.setup(t)
                t.expect(!s.model.wantsKeys, "home takes no keys")
                t.expect(s.model.keyAction(for: .escape) == nil)
                t.expectEqual(s.model.keyAction(for: .settings), .settings)
                await CardTests.dropAndWait(t, s, [try CardTests.receiptFile(s.dir)])
                let id = s.model.suggestions[0].id
                s.model.choose(CardTests.receipts, for: id)
                t.expect(s.model.wantsKeys)
                // an unsure card shows chips and no send button, return has nothing to press
                s.model.suggestions[0].level = .unsure
                t.expect(s.model.keyAction(for: .returnKey) == nil, "an unsure card has no send button")
                s.model.suggestions[0].level = .confident
                t.expectEqual(s.model.keyAction(for: .returnKey), .send(id))
                t.expectEqual(s.model.keyAction(for: .escape), .dismiss)
                t.expect(s.model.keyAction(for: .undo) == nil && s.model.keyAction(for: .copy) == nil)
                s.model.perform(.send(id))
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expect(s.model.keyAction(for: .returnKey) == nil, "nothing to send once sent")
                t.expectEqual(s.model.keyAction(for: .undo), .undo)
                t.expectEqual(s.model.keyAction(for: .copy), .copyLink)
                t.expectEqual(s.model.keyAction(for: .escape), .dismiss)
                s.model.perform(.undo)
                await t.eventually { s.model.cardState == .suggesting }
                s.drive.failNames = ["receipt.txt"]
                s.model.send(id, to: CardTests.receipts)
                await t.eventually { if case .error = s.model.cardState { return true }; return false }
                t.expectEqual(s.model.keyAction(for: .returnKey), .retry)
                t.expectEqual(s.model.keyAction(for: .escape), .dismiss)
                s.model.perform(.dismiss)
                await t.eventually { s.model.cardState == .idle }
                s.model.show(.activity)
                t.expectEqual(s.model.keyAction(for: .escape), .back)
                s.model.perform(.back)
                t.expectEqual(s.model.content, .home)
            },
            TestCase("several files, return sends them all once every row has a folder") { t in
                let s = try CardTests.setup(t)
                await CardTests.dropAndWait(t, s, [try CardTests.receiptFile(s.dir), try CardTests.resumeFile(s.dir)])
                for row in s.model.suggestions {
                    s.model.choose(CardTests.receipts, for: row.id)
                }
                t.expectEqual(s.model.keyAction(for: .returnKey), .sendAll)
            },
            TestCase("the menu bar's activity holds the island open until the pointer has been there") { t in
                let model = IslandShellTests.model()
                model.pointerIsOverIsland = { false }
                model.showFromMenu(.activity)
                t.expect(model.isExpanded && model.content == .activity)
                t.expect(model.holdsExpanded, "held with the pointer away")
                model.collapse()
                t.expect(model.isExpanded, "a collapse while held doesn't close it")
                model.pointerArrived()
                t.expect(!model.holdsExpanded, "hover decides from here")
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
            },
        ]
    }
}
#endif
