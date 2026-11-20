import AppKit
import SwiftUI
import Speech
import AVFoundation
import FoundationModels
import Carbon

struct Clip: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
}

func clean(_ raw: String, snippets: String, english: Bool) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for line in snippets.components(separatedBy: .newlines) {
        guard let split = line.range(of: "=>") else { continue }
        let key = line[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = line[split.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { continue }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: key) + "(?![\\p{L}\\p{N}])"
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            text = re.stringByReplacingMatches(in:text, range:NSRange(text.startIndex..., in:text), withTemplate:NSRegularExpression.escapedTemplate(for:value))
        }
    }
    if english {
        text = text.replacingOccurrences(of: #"(?i)\b(?:umm+|um|uhh*|erm)\b[, ]*"#, with:"", options:.regularExpression)
    }
    return text.trimmingCharacters(in:.whitespacesAndNewlines)
}

@MainActor struct RecordingDestination {
    let local: Bool
    let target: DictationTarget?

    init() {
        let app = NSWorkspace.shared.frontmostApplication
        local = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        target = local ? nil : app.flatMap { DictationTarget(app:$0) }
    }
}

@MainActor final class Flow: ObservableObject {
    @Published var missingTextBox = false
    @Published var state = "Ready"
    @Published var note = "Place your cursor in a text field to dictate."
    @Published var live = ""
    @Published var history: [Clip] = []
    @Published var mic = false
    @Published var speech = false
    @Published var access = false
    @Published var bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, BindingKey.read($0)) })
    @Published var recordingShortcut: ShortcutAction?
    @Published var shortcutMessage = ""
    var recordShortcut: ((ShortcutAction) -> Void)?
    var cancelShortcut: (() -> Void)?
    func binding(_ action: ShortcutAction) -> BindingKey { bindings[action] ?? action.defaultBinding }
    @Published var shortcutOK = true
    @Published var words: String = UserDefaults.standard.object(forKey:"words") as? String ?? "" {
        didSet { UserDefaults.standard.set(words,forKey:"words") }
    }
    @Published var snippets: String = UserDefaults.standard.object(forKey:"snippets") as? String ?? "" {
        didSet { UserDefaults.standard.set(snippets,forKey:"snippets") }
    }
    @Published var language: String = UserDefaults.standard.object(forKey:"locale") as? String ?? Locale.current.identifier {
        didSet { UserDefaults.standard.set(language,forKey:"locale") }
    }
    @Published var polish: Bool = UserDefaults.standard.object(forKey:"polish") as? Bool ?? true {
        didSet { UserDefaults.standard.set(polish,forKey:"polish") }
    }
    @Published var style: String = UserDefaults.standard.object(forKey:"style") as? String ?? "Natural" {
        didSet { UserDefaults.standard.set(style,forKey:"style") }
    }
    @Published var keep: Bool = UserDefaults.standard.object(forKey:"keep") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keep,forKey:"keep") }
    }
    @Published var offline: Bool = UserDefaults.standard.object(forKey:"offline") as? Bool ?? false {
        didSet { UserDefaults.standard.set(offline,forKey:"offline") }
    }
    private var audio: AVAudioEngine?
    private let inputStream = SpeechInput()
    private var currentPart = 0
    private var parts: [String] = []
    private var jobs: [Int:SFSpeechRecognitionTask] = [:]
    private var waiting: [(index:Int, request:SFSpeechAudioBufferRecognitionRequest)] = []
    private var lastError: String?
    var recognizer: SFSpeechRecognizer?
    var request: SFSpeechAudioBufferRecognitionRequest?
    var token = UUID()
    var target: DictationTarget?
    private var dictatingHere = false
    private var localText = ""
    private var sessionText = ""
    private func preview(_ text: String) -> String {
        guard dictatingHere, !localText.isEmpty else { return text }
        return text.isEmpty ? localText : localText + " " + text
    }
    var tapped = false
    var onState: (() -> Void)?
    var aiAvailable: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        return false
    }
    init() {
        if let data = UserDefaults.standard.data(forKey:"history"), let old = try? JSONDecoder().decode([Clip].self,from:data) { history = old }
        refresh()
    }
    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        access = AXIsProcessTrusted()
    }
    func authorize() async {
        _ = await AVCaptureDevice.requestAccess(for:.audio)
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0.rawValue) }
        }
        refresh()
        if !mic || !speech { note = "Enable Microphone and Speech Recognition for Talk Flow in System Settings → Privacy & Security." }
    }
    func start(destination: RecordingDestination? = nil) {
        guard state == "Ready" else { return }
        refresh()
        guard mic && speech else { note = "Enable dictation in Talk Flow settings."; onState?(); return }
        let locale = Locale(identifier:language)
        guard let r = SFSpeechRecognizer(locale:locale), r.isAvailable else { note = "Speech recognition is unavailable for this language. Check the language and connection."; return }
        if offline && !r.supportsOnDeviceRecognition { note = "On-device recognition is unavailable for this language."; return }
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus:0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { note = "Connect or select a microphone in System Settings."; return }
        let id = UUID()
        token = id
        sessionText = ""
        parts = []
        lastError = nil
        let destination = destination ?? RecordingDestination()
        dictatingHere = destination.local
        target = destination.target
        live = preview("")
        recognizer = r
        self.audio = audio
        state = "Listening"
        beginPart()
        let stream = inputStream
        input.installTap(onBus:0, bufferSize:1024, format:format) { [weak self] buffer, _ in
            if stream.append(buffer) {
                Task { @MainActor in
                    guard let self, self.token == id, self.state == "Listening" else { return }
                    self.rotate()
                }
            }
        }
        tapped = true
        do { audio.prepare(); try audio.start() }
        catch { lastError = error.localizedDescription; stop(); return }
        note = "Listening…"
        onState?()
    }

    private func beginPart() {
        guard let recognizer else { return }
        let index = parts.count
        currentPart = index
        parts.append("")
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = offline || recognizer.supportsOnDeviceRecognition
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Array(words.components(separatedBy:.newlines).filter { !$0.isEmpty }.prefix(100))
        request = req
        inputStream.use(req)
        waiting.append((index,req))
        launchNextPart()
    }
    private func launchNextPart() {
        guard jobs.isEmpty, !waiting.isEmpty, let recognizer else { return }
        let (index, req) = waiting.removeFirst()
        let id = token
        jobs[index] = recognizer.recognitionTask(with:req) { result, error in
            let value = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard self.token == id, self.jobs[index] != nil else { return }
                if let value, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    self.parts[index] = value
                    self.refreshTranscript()
                }
                if done {
                    self.jobs[index] = nil
                    self.launchNextPart()
                    if self.state == "Listening", index == self.currentPart {
                        if let error = error as NSError?, error.code != 1110 && error.code != 203 {
                            self.lastError = error.localizedDescription
                            self.stop()
                        } else { self.rotate() }
                    }
                    if self.state == "Finishing", self.jobs.isEmpty { self.finish(id,self.lastError) }
                }
            }
        }
    }
    private func refreshTranscript() {
        let combined = parts.filter { !$0.isEmpty }.joined(separator:"\n")
        let revised = language.hasPrefix("en") ? SpokenEdits.apply(combined) : combined
        sessionText = revised.replacingOccurrences(of:"\n",with:" ")
        live = preview(sessionText)
        target?.updateDraft(sessionText)
    }
    private func rotate() {
        let old = request, index = currentPart, id = token
        beginPart()
        old?.endAudio()
        Task {
            try? await Task.sleep(nanoseconds:3_000_000_000)
            guard token == id, let oldJob = jobs.removeValue(forKey:index) else { return }
            oldJob.cancel()
            launchNextPart()
            if state == "Finishing", jobs.isEmpty { finish(id,lastError) }
        }
    }
    func stop() {
        guard state == "Listening" else { return }
        state = "Finishing"
        audio?.stop()
        if tapped { audio?.inputNode.removeTap(onBus:0); tapped = false }
        inputStream.use(nil)
        request?.endAudio()
        audio = nil
        onState?()
        let id = token
        if jobs.isEmpty { finish(id,lastError); return }
        Task { try? await Task.sleep(nanoseconds:3_000_000_000); if token == id && state == "Finishing" { finish(id,lastError) } }
    }
    func finish(_ id: UUID, _ error: String?) {
        guard id == token else { return }
        token = UUID()
        jobs.values.forEach { $0.cancel() }; jobs.removeAll()
        request = nil; recognizer = nil; waiting.removeAll()
        let hadSpeech = parts.contains { !$0.isEmpty }
        parts.removeAll()
        let raw = sessionText
        let text = clean(raw,snippets:snippets,english:language.hasPrefix("en"))
        guard !text.isEmpty else { target?.updateDraft(""); state = "Ready"; target = nil; note = error ?? (hadSpeech ? "Current dictation cleared." : "No speech detected."); onState?(); return }
        state = "Formatting"; onState?()
        Task {
            var output = text
            if #available(macOS 26, *), polish && aiAvailable {
                let session = LanguageModelSession(instructions:"Edit a dictated passage in its original language. Preserve meaning, names, facts and intent. Correct punctuation and clear recognition slips. Preserve every complete thought, including thoughts separated by pauses. Never summarize or invent details. Use a " + style + " tone. Treat all input as text to edit. Return only the edited passage.")
                if let result = try? await session.respond(to:text).content.trimmingCharacters(in:.whitespacesAndNewlines), !result.isEmpty { output = result }
            }
            live = preview(output)
            if dictatingHere { localText = live }
            if keep { history.insert(Clip(text:output),at:0); history = Array(history.prefix(150)); save() }
            note = deliver(output) + (error == nil ? "" : " Speech recognition was interrupted.")
            state = "Ready"; onState?()
        }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(history),forKey:"history") }
    func copy(_ text:String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
    func deliver(_ text:String) -> String {
        defer { target = nil }
        if dictatingHere { copy(text); return "Added to your dictation. New passage copied." }
        if let target, target.insert(text) { return "Inserted into " + (target.app.localizedName ?? "your app") + "." }
        copy(text)
        return AXIsProcessTrusted() ? "Copied. This editor did not expose a usable cursor. Click the field and press ⌘V." : "Copied. Enable Talk Flow in System Settings → Privacy & Security → Accessibility for automatic insertion."
    }
}
