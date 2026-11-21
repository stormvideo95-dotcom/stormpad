import AppKit
import CoreGraphics

struct Mapping: Codable, Identifiable, Equatable {
    var id = UUID()
    var input: String
    var keyCode: UInt16
    var flags: UInt64
    var label: String
}

enum Keys {
    static let names: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Fwd Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 76: "Enter",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        55: "Left ⌘", 54: "Right ⌘", 56: "Left ⇧ Shift", 60: "Right ⇧ Shift",
        58: "Left ⌥ Option", 61: "Right ⌥ Option", 59: "Left ⌃ Control", 62: "Right ⌃ Control", 63: "fn"
    ]

    static func name(_ code: UInt16, _ chars: String?) -> String {
        if let n = names[code] { return n }
        if let c = chars, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return c.uppercased()
        }
        return "Key \(code)"
    }

    static func prefix(_ flags: UInt64) -> String {
        let f = CGEventFlags(rawValue: flags)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }

    static func modifierFlag(_ code: UInt16) -> CGEventFlags? {
        switch code {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func nsFlag(_ code: UInt16) -> NSEvent.ModifierFlags {
        switch code {
        case 55, 54: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return []
        }
    }

    // modifier keys to physically press for a combo like ⌘C
    static let comboCodes: [(CGEventFlags, UInt16)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)
    ]

    static func pretty(_ input: String) -> String {
        if let i = input.firstIndex(of: ":"), input.distance(from: input.startIndex, to: i) <= 4 {
            return String(input.drop(while: { $0 != ":" }).dropFirst())
        }
        return input
    }
}

enum KeyOut {
    static let src = CGEventSource(stateID: .hidSystemState)

    static func key(_ code: UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.flags = flags
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    static func modifier(_ code: UInt16, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
