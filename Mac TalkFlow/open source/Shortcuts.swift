import AppKit
import Carbon

enum ShortcutAction: Int, CaseIterable, Identifiable {
    case hold = 1, toggle
    var id: Int { rawValue }
    var title: String { self == .hold ? "Hold to talk" : "Hands-free dictation" }
    var setting: String { "shortcut." + String(rawValue) }
    var defaultBinding: BindingKey {
        BindingKey(code:UInt32(kVK_Space), flags:UInt32(self == .hold ? optionKey : controlKey | optionKey), keyName:"Space")
    }
}

struct BindingKey: Codable {
    var code: UInt32
    var flags: UInt32
    var keyName: String
    var label: String {
        [(controlKey,"⌃"),(optionKey,"⌥"),(shiftKey,"⇧"),(cmdKey,"⌘")]
            .filter { flags & UInt32($0.0) != 0 }.map { $0.1 }.joined() + " " + keyName
    }
    static func read(_ action: ShortcutAction) -> Self {
        if let data = UserDefaults.standard.data(forKey:action.setting),
           let key = try? JSONDecoder().decode(Self.self,from:data) { return key }
        return action.defaultBinding
    }
    static func capture(_ event: NSEvent) -> Self? {
        let modifiers: [(NSEvent.ModifierFlags,Int)] = [(.control,controlKey),(.option,optionKey),(.shift,shiftKey),(.command,cmdKey)]
        let flags = modifiers.reduce(0) { $0 | (event.modifierFlags.contains($1.0) ? $1.1 : 0) }
        let fnKeys = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let function = fnKeys.firstIndex(of:Int(event.keyCode))
        guard flags & (controlKey | optionKey | cmdKey) != 0 || function != nil else { return nil }
        let named = [49:"Space",36:"Return",76:"Keypad Enter",48:"Tab",51:"Delete",117:"Forward Delete",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down"]
        let name = function.map { "F" + String($0 + 1) } ?? named[Int(event.keyCode)] ?? event.characters(byApplyingModifiers:[])?.uppercased() ?? ""
        guard !name.isEmpty else { return nil }
        return Self(code:UInt32(event.keyCode),flags:UInt32(flags),keyName:name)
    }
}

@MainActor final class ShortcutWindow: NSWindow {
    var captureKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if captureKey?(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown, captureKey?(event) == true { return }
        super.sendEvent(event)
    }
}
