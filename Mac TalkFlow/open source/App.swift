import AppKit
import SwiftUI
import Carbon

@main enum TalkFlowApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = Delegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let flow = Flow()
    var window: ShortcutWindow!
    var panel: FlowBar!
    var item: NSStatusItem!
    var recordingItem: NSMenuItem!
    var accessItem: NSMenuItem!
    var keys: [ShortcutAction: EventHotKeyRef] = [:]
    var handlerReady = false
    var held = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FlowBar()
        panel.onToggle = { [weak self] in self?.toggle() }
        NotificationCenter.default.addObserver(self,selector:#selector(savePosition),name:NSWindow.didMoveNotification,object:panel)
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName:"waveform",accessibilityDescription:"Talk Flow")
        let menu = NSMenu()
        for (name, action) in [("Open Talk Flow",#selector(show)),("Start dictation",#selector(toggle)),("Quit Talk Flow",#selector(quitApp))] {
            let entry = menu.addItem(withTitle:name,action:action,keyEquivalent:""); entry.target = self
            if action == #selector(toggle) { recordingItem = entry }
        }
        accessItem = NSMenuItem(title:"Enable text insertion…",action:#selector(enableInsertion),keyEquivalent:"")
        accessItem.target = self
        menu.insertItem(accessItem,at:2)
        menu.delegate = self
        item.menu = menu
        flow.onState = { [weak self] in self?.update() }
        flow.recordShortcut = { [weak self] action in self?.beginRecording(action) }
        flow.cancelShortcut = { [weak self] in self?.endRecording() }
        register(); update(); panel.orderFrontRegardless()
    }
    @objc private func enableInsertion() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func createWindow() {
        if NSApp.mainMenu == nil {
            let menu = NSMenu(), appEntry = NSMenuItem(), editEntry = NSMenuItem()
            menu.addItem(appEntry); menu.addItem(editEntry)
            appEntry.submenu = NSMenu(title:"Talk Flow")
            appEntry.submenu?.addItem(withTitle:"Quit Talk Flow",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            let edit = NSMenu(title:"Edit")
            editEntry.submenu = edit
            for (title,action,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a"),("Undo","undo:","z")] {
                edit.addItem(withTitle:title,action:NSSelectorFromString(action),keyEquivalent:key)
            }
            NSApp.mainMenu = menu
        }
        window = ShortcutWindow(contentRect:NSRect(x:0,y:0,width:820,height:570),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Talk Flow"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:Studio(flow:flow)); window.center()
        window.captureKey = { [weak self] event in self?.capture(event) ?? false }
        NotificationCenter.default.addObserver(self,selector:#selector(endRecording),name:NSWindow.didResignKeyNotification,object:window)
        NotificationCenter.default.addObserver(self,selector:#selector(releaseWindow),name:NSWindow.willCloseNotification,object:window)
    }
    @objc private func releaseWindow() { endRecording(); window = nil }
    @objc private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin),forKey:"barOrigin")
    }
    @objc private func screenChanged() { panel.constrainToDisplay() }
    @objc func show() {
        if window == nil { createWindow() }
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil); flow.refresh()
    }
    @objc func toggle() {
        if flow.state == "Listening" { flow.stop(); return }
        guard flow.state == "Ready" else { return }
        let destination = RecordingDestination()
        guard requireTextBox(destination) else { return }
        flow.refresh()
        if flow.mic && flow.speech {
            startHandsFree(at:destination)
            return
        }
        flow.state = "Requesting access"
        update()
        Task {
            await flow.authorize()
            flow.state = "Ready"
            if flow.mic && flow.speech {
                startHandsFree(at:destination)
            } else {
                update()
                panel.showStatus(flow.note)
            }
        }
    }
    private func requireTextBox(_ destination: RecordingDestination) -> Bool {
        flow.missingTextBox = destination.target == nil
        if flow.missingTextBox { update(); show(); return false }
        return true
    }
    private func startHandsFree(at destination:RecordingDestination) {
        flow.start(destination:destination)
        update()
        if flow.state == "Ready" { panel.showStatus(flow.note) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { show(); return true }
    func update() {
        recordingItem.title = flow.state == "Listening" ? "Finish dictation" : "Start dictation"
        item.button?.toolTip = flow.note
        panel.update(flow)
    }
    func register() {
        var events = [EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _,event,context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let code = GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard code == noErr, id.signature == 0x54464c57 else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<Delegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard owner.flow.recordingShortcut == nil else { return }
                if id.id == 1 {
                    if pressed && !owner.held && owner.flow.state == "Ready" { let destination = RecordingDestination(); if owner.requireTextBox(destination) { owner.held = true; owner.flow.start(destination:destination) } }
                    if !pressed && owner.held { owner.held = false; owner.flow.stop() }
                } else if pressed { owner.toggle() }
            }
            return noErr
        },2,&events,Unmanaged.passUnretained(self).toOpaque(),nil)
        handlerReady = status == noErr
        restoreKeys()
    }
    func bind(_ action: ShortcutAction, _ binding: BindingKey) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature:0x54464c57,id:UInt32(action.rawValue))
        guard handlerReady, RegisterEventHotKey(binding.code,binding.flags,id,GetApplicationEventTarget(),0,&ref) == noErr, let ref else { return false }
        keys[action] = ref
        return true
    }
    func restoreKeys() {
        for action in ShortcutAction.allCases where keys[action] == nil { _ = bind(action,flow.binding(action)) }
        flow.shortcutOK = keys.count == ShortcutAction.allCases.count
    }
    func beginRecording(_ action: ShortcutAction) {
        guard flow.state == "Ready" else { return }
        for key in keys.values { UnregisterEventHotKey(key) }
        keys.removeAll()
        held = false
        flow.shortcutMessage = "Press a shortcut, or Escape to cancel."
        flow.recordingShortcut = action
    }
    @objc func endRecording() {
        guard flow.recordingShortcut != nil else { return }
        flow.recordingShortcut = nil
        flow.shortcutMessage = ""
        restoreKeys()
    }
    func capture(_ event: NSEvent) -> Bool {
        guard let action = flow.recordingShortcut else { return false }
        if event.isARepeat { return true }
        if event.keyCode == UInt16(kVK_Escape) { endRecording(); return true }
        guard let candidate = BindingKey.capture(event) else {
            flow.shortcutMessage = "Include Command, Option or Control, or use a function key."
            return true
        }
        let other = flow.binding(action == .hold ? .toggle : .hold)
        guard other.code != candidate.code || other.flags != candidate.flags else {
            flow.shortcutMessage = "Your other dictation shortcut uses that combination."
            return true
        }
        guard bind(action,candidate) else {
            flow.shortcutMessage = "That shortcut is unavailable. Try another combination."
            return true
        }
        flow.bindings[action] = candidate
        UserDefaults.standard.set(try? JSONEncoder().encode(candidate),forKey:action.setting)
        endRecording()
        return true
    }
}

extension Delegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu:NSMenu) { accessItem.isHidden = AXIsProcessTrusted() }
}
