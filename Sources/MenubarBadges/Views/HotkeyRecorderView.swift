import AppKit
import Carbon.HIToolbox
import MenubarBadgesCore
import SwiftUI

/// Native shortcut recorder button for capturing a global hotkey combination.
struct HotkeyRecorderView: View {
    @Binding var combo: HotkeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(buttonLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if combo != nil && !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var buttonLabel: String {
        if isRecording {
            return "Press shortcut…"
        }
        return combo?.displayString ?? "Record Shortcut"
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            combo = HotkeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
