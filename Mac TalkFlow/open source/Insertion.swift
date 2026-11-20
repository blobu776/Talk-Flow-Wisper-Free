import AppKit
import CryptoKit

/// Accessibility offsets are UTF-16 offsets, including in fields containing emoji.
struct InsertionPoint {
    let offset: Int
    private let fingerprint: SHA256.Digest

    init?(text: String, selection: CFRange) {
        let units = text.utf16.count
        guard selection.location >= 0, selection.location <= units,
              selection.length >= 0, selection.length <= units - selection.location else { return nil }
        offset = selection.location
        fingerprint = SHA256.hash(data: Data(text.utf8))
    }

    func matches(_ text: String) -> Bool { SHA256.hash(data: Data(text.utf8)) == fingerprint }
}

@MainActor final class DictationTarget {
    let app: NSRunningApplication
    let field: AXUIElement
    let point: InsertionPoint?
    let offset: Int?
    let marker: AXTextMarker?
    private var draft = ""

    private static func attribute(_ field: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field,name as CFString,&result) == .success else { return nil }
        return result
    }

    private static func focus(_ app: NSRunningApplication) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selection(_ field: AXUIElement) -> CFRange? {
        if let ranges = attribute(field,kAXSelectedTextRangesAttribute) as? [Any], ranges.count != 1 { return nil }
        guard let value = attribute(field,kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax,.cfRange,&range) else { return nil }
        return range
    }

    init?(app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if Self.focus(app).flatMap(Self.selection) == nil {
            _ = AXUIElementSetAttributeValue(axApp,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(axApp,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        }
        guard let field = Self.focus(app),
              Self.attribute(field,kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        let role = Self.attribute(field,kAXRoleAttribute) as? String ?? ""
        var writable = DarwinBoolean(false)
        let writableValue = AXUIElementIsAttributeSettable(field,kAXValueAttribute as CFString,&writable) == .success && writable.boolValue
        let editable = Self.attribute(field,"AXEditable") as? Bool == true
        guard ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(role) || editable || writableValue else { return nil }
        if Self.attribute(field,"AXEditable") as? Bool == false { return nil }
        let range = Self.selection(field)
        self.app = app
        self.field = field
        offset = range?.location
        if let range, let value = Self.attribute(field,kAXValueAttribute) as? String {
            point = InsertionPoint(text:value,selection:range)
        } else { point = nil }
        marker = Self.markerRange(field).map { AXTextMarkerRangeCopyStartMarker($0) }
        guard offset != nil || marker != nil else { return nil }
    }

    private static func markerRange(_ field:AXUIElement) -> AXTextMarkerRange? {
        guard let value = attribute(field,"AXSelectedTextMarkerRange"), CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    private func placeCaret() -> Bool {
        if let point {
            guard let current = Self.attribute(field,kAXValueAttribute) as? String, point.matches(current) else { return false }
        }
        if let offset, let original = Self.selection(field) {
            if original.location != offset || original.length != 0 {
                var caret = CFRange(location:offset,length:0)
                guard let value = AXValueCreate(.cfRange,&caret),
                      AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,value) == .success else { return false }
            }
            guard let confirmed = Self.selection(field), confirmed.location == offset, confirmed.length == 0 else { return false }
            return true
        }
        guard let marker, let current = Self.markerRange(field) else { return false }
        func atCaret(_ range:AXTextMarkerRange) -> Bool {
            CFEqual(marker,AXTextMarkerRangeCopyStartMarker(range)) && CFEqual(marker,AXTextMarkerRangeCopyEndMarker(range))
        }
        if atCaret(current) { return true }
        let collapsed = AXTextMarkerRangeCreate(nil,marker,marker)
        guard AXUIElementSetAttributeValue(field,"AXSelectedTextMarkerRange" as CFString,collapsed) == .success,
              let updated = Self.markerRange(field) else { return false }
        return atCaret(updated)
    }

    /// Revise only the draft owned by this recording, after verifying both the draft
    /// and the original document. Editors without writable text ranges use Finish.
    @discardableResult func updateDraft(_ text:String) -> Bool {
        guard app.isActive, let focused = Self.focus(app), CFEqual(focused,field),
              let point, let content = Self.attribute(field,kAXValueAttribute) as? String else { return false }
        let document = content as NSString
        let range = NSRange(location:point.offset,length:draft.utf16.count)
        guard NSMaxRange(range) <= document.length, document.substring(with:range) == draft,
              point.matches(document.replacingCharacters(in:range,with:"")),
              let selection = Self.selection(field) else { return false }
        if draft == text { return true }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field,kAXSelectedTextAttribute as CFString,&writable) == .success, writable.boolValue else { return false }
        var selected = CFRange(location:range.location,length:range.length)
        guard let ax = AXValueCreate(.cfRange,&selected),
              AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,ax) == .success,
              let actual = Self.selection(field), actual.location == selected.location, actual.length == selected.length else { return false }
        guard AXUIElementSetAttributeValue(field,kAXSelectedTextAttribute as CFString,text as CFString) == .success else {
            var previous = selection
            if let restore = AXValueCreate(.cfRange,&previous) {
                _ = AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,restore)
            }
            return false
        }
        draft = text
        var end = CFRange(location:point.offset + text.utf16.count,length:0)
        if let caret = AXValueCreate(.cfRange,&end) {
            _ = AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,caret)
        }
        return true
    }

    func insert(_ text:String) -> Bool {
        if !draft.isEmpty { return updateDraft(text) }
        guard app.isActive, let current = Self.focus(app), CFEqual(current,field), placeCaret() else { return false }
        // Paste follows the editor’s own insertion, undo, and input-event path.
        let board = NSPasteboard.general
        guard let down = CGEvent(keyboardEventSource:nil,virtualKey:9,keyDown:true),
              let up = CGEvent(keyboardEventSource:nil,virtualKey:9,keyDown:false), CGPreflightPostEventAccess() else {
            return AXUIElementSetAttributeValue(field,kAXSelectedTextAttribute as CFString,text as CFString) == .success
        }
        board.clearContents()
        guard board.setString(text,forType:.string), app.isActive, let focused = Self.focus(app), CFEqual(focused,field), placeCaret() else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        return true
    }
}
