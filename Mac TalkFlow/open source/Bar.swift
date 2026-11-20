import AppKit

private final class Grip: NSView {
    override func draw(_ dirtyRect:NSRect) {
        NSColor.lightGray.setFill()
        for x in [6,10] { for y in [9,14,19] {
            NSBezierPath(ovalIn:NSRect(x:x,y:y,width:2,height:2)).fill()
        }}
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
}

@MainActor final class FlowBar: NSPanel {
    private let record = NSButton(), grip = Grip()
    private let preview = NSTextField(wrappingLabelWithString:"")
    private let shell = NSView()
    private var statusOnly = false
    var onToggle: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect:NSRect(x:0,y:0,width:116,height:34),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = false; level = .floating
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        contentView = shell
        shell.wantsLayer = true
        shell.layer?.backgroundColor = NSColor(white:0.09,alpha:0.98).cgColor
        shell.layer?.cornerRadius = 16
        shell.layer?.borderWidth = 1
        shell.layer?.borderColor = NSColor(white:0.33,alpha:1).cgColor
        record.isBordered = false; record.bezelStyle = .inline; record.contentTintColor = .white
        record.target = self; record.focusRingType = .none
        shell.addSubview(record)
        record.action = #selector(toggle)
        record.font = .systemFont(ofSize:12,weight:.semibold)
        record.imagePosition = .imageLeading
        record.toolTip = "Start or finish dictation"
        grip.toolTip = "Drag to move Talk Flow"; shell.addSubview(grip)
        preview.font = .systemFont(ofSize:13); preview.textColor = .white
        preview.maximumNumberOfLines = 4; preview.lineBreakMode = .byTruncatingHead
        shell.addSubview(preview)
        layoutBar()
        let saved = UserDefaults.standard.string(forKey:"barOrigin").map(NSPointFromString)
        let area = NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(saved ?? NSPoint(x:area.midX-58,y:area.minY+14))
        constrainToDisplay()
    }
    func constrainToDisplay() {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x:min(max(frame.minX,area.minX),area.maxX-frame.width),
                               y:min(max(frame.minY,area.minY),area.maxY-frame.height)))
    }
    private func layoutBar() {
        grip.frame = NSRect(x:3,y:2,width:18,height:30)
        record.frame = NSRect(x:22,y:1,width:84,height:32)
        preview.frame = NSRect(x:14,y:38,width:frame.width-28,height:73)
        preview.isHidden = !statusOnly
    }
    @objc private func toggle() { onToggle?() }
    func showStatus(_ message:String) {
        // Display setup errors inline without revealing a transcript or activating the app.
        statusOnly = true
        setContentSize(NSSize(width:300,height:122))
        layoutBar(); constrainToDisplay()
        preview.stringValue = message
        record.toolTip = message
    }
    func update(_ flow:Flow) {
        if statusOnly {
            statusOnly = false
            setContentSize(NSSize(width:116,height:34))
            layoutBar(); constrainToDisplay()
        }
        record.toolTip = flow.note
        let listening = flow.state == "Listening", ready = flow.state == "Ready"
        record.title = listening ? " Finish" : ready ? " Dictate" : " Wait"
        record.image = NSImage(systemSymbolName:listening ? "stop.fill" : ready ? "waveform" : "ellipsis",accessibilityDescription:nil)
        record.isEnabled = ready || listening
        record.setAccessibilityLabel(listening ? "Finish dictation" : "Start dictation")
    }
}
