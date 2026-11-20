import SwiftUI
import Speech
import ServiceManagement

private let ink = Color(red:0.16,green:0.10,blue:0.15)
private let peach = Color(red:1,green:0.66,blue:0.52)
private let paper = Color(red:0.98,green:0.96,blue:0.93)
private let accent = Color(red:0.61,green:0.21,blue:0.24)

struct Studio: View {
    @ObservedObject var flow: Flow
    @State private var page = "Dictation"
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError = ""
    @State private var reveal = false
    @State private var search = ""
    @State private var confirmClear = false
    private let tabs = [("Dictation","waveform"),("History","clock"),("Dictionary","character.book.closed"),("Snippets","text.quote"),("Settings","slider.horizontal.3")]
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:6) {
                HStack { Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:36,height:36); Text("Talk Flow").font(.system(size:21,weight:.bold,design:.rounded)) }.padding(.bottom,32)
                ForEach(tabs,id:\.0) { name, icon in
                    Button { page = name } label: {
                        HStack(spacing:12) { Image(systemName:icon).frame(width:19); Text(name); Spacer() }.padding(10).background(page == name ? Color.white.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:9))
                    }.buttonStyle(.plain).foregroundStyle(page == name ? peach : .white.opacity(0.85))
                }
                Spacer()
                Label(flow.state,systemImage:flow.state == "Ready" ? "circle.dotted" : "waveform").foregroundStyle(peach).font(.callout)
            }.padding(18).frame(width:174).background(ink).foregroundStyle(.white)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if flow.missingTextBox {
                        VStack(alignment:.leading,spacing:6) {
                            Label("Please select a textbox",systemImage:"exclamationmark.triangle.fill").font(.headline)
                            if !flow.access {
                                Text("Allow Talk Flow in Accessibility so it can see the selected text box.")
                                Button("Open Accessibility settings") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                            }
                        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                         .background(Color.yellow.opacity(0.78),in:RoundedRectangle(cornerRadius:10))
                    }
                    Text(page).font(.system(size:37,weight:.medium,design:.serif))
                    switch page {
                    case "Dictation":
                        VStack(alignment:.leading,spacing:17) {
                            Image(systemName:"waveform").font(.system(size:34)).foregroundStyle(peach)
                            Text(flow.state == "Ready" ? "Hold " + flow.binding(.hold).label + " to talk" : flow.state + "…").font(.system(size:25,weight:.semibold))
                            Text("Release to insert your words at the cursor. For hands-free dictation, press " + flow.binding(.toggle).label + " to start and again to finish.").fixedSize(horizontal:false,vertical:true)
                            Button(flow.state == "Listening" ? "Finish dictation" : "Dictate here") {
                                if flow.state == "Listening" { flow.stop() }
                                else if !flow.mic || !flow.speech { page = "Settings" }
                                else { flow.start() }
                            }.buttonStyle(.borderedProminent).tint(accent).disabled(!["Listening","Ready"].contains(flow.state))
                        }.padding(23).frame(maxWidth:.infinity,alignment:.leading).background(ink,in:RoundedRectangle(cornerRadius:18)).foregroundStyle(.white)
                        Text("Say “scratch that” to remove your last thought or “remove all of that” to clear this recording.").foregroundStyle(.secondary)
                        if !flow.shortcutOK { Text("A global shortcut is unavailable. Choose another combination in Settings.") }
                        if !flow.mic || !flow.speech { Button("Set up microphone and speech recognition") { page = "Settings" } }
                        Text(flow.note).foregroundStyle(.secondary)
                        if !flow.live.isEmpty {
                            DisclosureGroup("Transcript",isExpanded:$reveal) {
                                Text(flow.live).textSelection(.enabled).font(.title3)
                                Button("Copy text") { flow.copy(flow.live) }
                            }
                        }
                    case "History":
                        TextField("Search dictations",text:$search).textFieldStyle(.roundedBorder)
                        if flow.history.isEmpty { Text("Your saved dictations will appear here.").foregroundStyle(.secondary) }
                        ForEach(flow.history.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { clip in
                            VStack(alignment:.leading,spacing:8) {
                                HStack { Text(clip.date.formatted()).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Copy") { flow.copy(clip.text) } }
                                Text(clip.text).textSelection(.enabled)
                            }.padding().background(.white,in:RoundedRectangle(cornerRadius:12))
                        }
                        if !flow.history.isEmpty { Button("Clear history…") { confirmClear = true } }
                    case "Dictionary":
                        Text("Add names and specialized words, one per line. The recognizer uses them as hints while you speak.")
                        editor($flow.words)
                    case "Snippets":
                        Text("Put one shortcut on each line. Separate the spoken phrase from its expansion with =>.")
                        Text("my email => hello@example.com").font(.system(.body,design:.monospaced)).foregroundStyle(accent)
                        editor($flow.snippets)
                    default:
                        Toggle("Start Talk Flow when I log in",isOn:Binding(get:{ loginStatus == .enabled || loginStatus == .requiresApproval },set:{ value in
                            do {
                                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                loginError = ""
                            } catch { loginError = error.localizedDescription }
                            loginStatus = SMAppService.mainApp.status
                        }))
                        if loginStatus == .requiresApproval {
                            Button("Allow Talk Flow in Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        if !loginError.isEmpty { Text(loginError).font(.caption) }
                        GroupBox("Keyboard shortcuts") {
                            VStack(alignment:.leading,spacing:10) {
                                ForEach(ShortcutAction.allCases) { action in
                                    HStack {
                                        Text(action.title)
                                        Spacer()
                                        Button(flow.recordingShortcut == action ? "Listening for keys…" : flow.binding(action).label) { flow.recordShortcut?(action) }
                                            .disabled(flow.state != "Ready")
                                            .accessibilityLabel("Change " + action.title + " shortcut")
                                    }
                                }
                                if flow.recordingShortcut != nil {
                                    HStack { Text(flow.shortcutMessage).font(.caption); Spacer(); Button("Cancel") { flow.cancelShortcut?() } }
                                }
                            }.padding(8)
                        }.onDisappear { flow.cancelShortcut?() }
                        GroupBox("Permissions") {
                            VStack(alignment:.leading,spacing:10) {
                                Text("Microphone " + (flow.mic ? "✓" : "• permission needed") + "     Speech recognition " + (flow.speech ? "✓" : "• permission needed"))
                                if !flow.mic || !flow.speech {
                                    Button("Enable dictation") { Task { await flow.authorize() } }
                                    Button("Open Privacy & Security") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
                                }
                                Text(flow.access ? "Accessibility enabled ✓" : "Enable Accessibility to insert text into other apps. Otherwise, Talk Flow copies it for you.")
                                if !flow.access { Button("Enable text insertion") { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary); NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                            }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        Picker("Recognition language",selection:$flow.language) {
                            ForEach(Array(Set(SFSpeechRecognizer.supportedLocales().map(\.identifier)).union([flow.language])).sorted(),id:\.self) { id in Text(Locale.current.localizedString(forIdentifier:id) ?? id).tag(id) }
                        }
                        Toggle("Require on-device speech recognition",isOn:$flow.offline)
                        Text("Talk Flow prefers on-device recognition. Other languages may use Apple’s speech service.").font(.caption)
                        Toggle("Polish with Apple Intelligence",isOn:$flow.polish).disabled(!flow.aiAvailable)
                        if flow.aiAvailable && flow.polish {
                            Picker("Writing style",selection:$flow.style) { ForEach(["Natural","Professional","Casual"],id:\.self) { Text($0) } }
                        } else if !flow.aiAvailable { Text("AI editing requires an available Apple Intelligence model on this Mac.").font(.caption) }
                        Toggle("Save dictation history on this Mac",isOn:$flow.keep)
                    }
                }.padding(30).frame(maxWidth:.infinity,alignment:.leading)
            }.background(paper)
        }.preferredColorScheme(.light).frame(minWidth:740,minHeight:530)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in flow.refresh() }
        .alert("Clear all saved dictations?",isPresented:$confirmClear) { Button("Cancel",role:.cancel) {}; Button("Clear",role:.destructive) { flow.history = []; flow.save() } }
    }
    private func editor(_ value:Binding<String>) -> some View { TextEditor(text:value).font(.body).padding(8).frame(minHeight:210).background(.white,in:RoundedRectangle(cornerRadius:12)) }
}

