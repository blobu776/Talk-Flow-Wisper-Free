# Talk Flow for macOS

Talk Flow is a native Mac dictation app with a movable floating button. Click a text box in another app, click **Dictate**, speak, then click **Finish**. Compatible editors show the live draft at the original insertion point. Editors that support insertion but cannot update a draft receive the passage on Finish. If no editable target is detected, Talk Flow opens its window with a yellow warning.

## Build

1. Open `Talk Flow.xcodeproj` in Xcode 26 or later with the macOS 26 SDK or later.
2. Select the **Talk Flow** scheme and **My Mac**, then choose **Product → Run**.
3. Allow Microphone, Speech Recognition, and Accessibility when requested. If necessary, enable the same copy of Talk Flow you intend to run in **System Settings → Privacy & Security → Accessibility**.

The deployment target is macOS 14. Apple Intelligence editing requires macOS 26 or later and an available system model. The project uses system frameworks and has no third-party packages. Local signing is configured for development. Public distribution requires your own signing and notarization setup.

## Use

- Drag the dotted grip to move the floating button. Open the waveform menu-bar icon for the main window.
- Hold Option–Space for push-to-talk, or press Control–Option–Space to toggle hands-free dictation. Change either shortcut in Settings.
- In English, say “scratch that” to undo the last thought in the current recording or “remove all of that” to clear it. Pausing preserves the recording.
- History, custom vocabulary, and snippets are stored in your macOS account. Settings include local history, on-device recognition, and optional Apple Intelligence editing. Depending on language and settings, Apple Speech may use Apple’s speech service.
- If a field loses focus or its contents change independently, Talk Flow can leave the final passage on the clipboard for manual insertion.

## Source

`App.swift` manages windows, shortcuts, and the background lifecycle. `Engine.swift` handles recognition and delivery. `Insertion.swift` implements anchored edits. `Corrections.swift` handles spoken corrections and quiet audio. `Bar.swift` and `Views.swift` contain the interface.

The original icon artwork is in `Icon.svg`, with the bundled Mac icon in `Icon.icns`. Released under the MIT License.
