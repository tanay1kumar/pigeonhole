import AppKit

// the keys the island answers while it's key, everything else goes on to whoever wants it
enum IslandKey: Equatable {
    case returnKey, escape, undo, copy, settings

    init?(_ event: NSEvent) {
        let modifiers = Self.modifiers(event)
        // with command held russian, greek or hebrew layouts give latin here, like the menus see it
        let characters = event.characters?.lowercased()
        switch (event.keyCode, modifiers) {
        // return and the keypad's enter
        case (36, []), (76, []):
            self = .returnKey
        case (53, []):
            self = .escape
        default:
            guard modifiers == .command else { return nil }
            switch characters {
            case "z": self = .undo
            case "c": self = .copy
            case ",": self = .settings
            default: return nil
            }
        }
    }

    // quit, hide and hide others, this app's own menu would do them to it instead of the app in front
    static func isAppMenuKey(_ event: NSEvent) -> Bool {
        // option changes characters, other layouts change the one ignoring modifiers, either can be the letter
        let letters = Set([event.characters, event.charactersIgnoringModifiers].compactMap { $0?.lowercased() })
        switch modifiers(event) {
        case .command: return letters.contains("q") || letters.contains("h")
        case [.command, .option]: return letters.contains("h")
        default: return false
        }
    }

    // eaten only with another app in front, this app's own quit and hide keep working when it's in front
    static func swallowsAppMenuKey(_ event: NSEvent, thisAppInFront: Bool) -> Bool {
        !thisAppInFront && isAppMenuKey(event)
    }

    private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }
}

enum IslandKeyAction: Equatable {
    case send(UUID), sendAll, retry, dismiss, back, undo, copyLink, settings
}

extension IslandViewModel {
    // what a key does for what's showing, nil leaves the key alone
    func keyAction(for key: IslandKey) -> IslandKeyAction? {
        if key == .settings {
            return .settings
        }
        switch content {
        case .card:
            switch cardState {
            case .suggesting:
                switch key {
                case .returnKey:
                    // return is the send button, only a confident card shows one
                    if suggestions.count == 1, let row = suggestions.first, row.status == .ready, row.level == .confident,
                       row.chosen != nil, hasDestinations {
                        return .send(row.id)
                    }
                    return suggestions.count > 1 && canSendAll ? .sendAll : nil
                case .escape:
                    return .dismiss
                default:
                    return nil
                }
            case .sent:
                switch key {
                case .escape: return .dismiss
                case .undo: return .undo
                case .copy: return suggestions.contains { $0.isSent && $0.driveLink != nil } ? .copyLink : nil
                default: return nil
                }
            case .error(_, let retry):
                switch key {
                case .returnKey: return retry == .none ? nil : .retry
                case .escape: return .dismiss
                default: return nil
                }
            default:
                return nil
            }
        case .activity, .storage:
            return key == .escape ? .back : nil
        default:
            return nil
        }
    }

    func perform(_ action: IslandKeyAction) {
        switch action {
        case .send(let id): send(id)
        case .sendAll: sendAll()
        case .retry: retry()
        case .dismiss: dismissCard()
        case .back: show(.home)
        case .undo: undo()
        case .copyLink: copySentLinks()
        case .settings: openSettings()
        }
    }

    // a card, a result to act on or a panel, worth taking the keyboard for
    var wantsKeys: Bool {
        switch content {
        case .card, .activity, .storage: return true
        default: return false
        }
    }
}
