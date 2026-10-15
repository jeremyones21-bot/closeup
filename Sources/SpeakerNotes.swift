import AppKit
import SwiftUI

/// A floating notes card you can read while recording. It belongs to Closeup, and Closeup's
/// own windows are always left out of the capture, so it never shows up in the video.
@MainActor
final class SpeakerNotes {
    static let shared = SpeakerNotes()
    private var panel: NSPanel?

    var text: String {
        get { UserDefaults.standard.string(forKey: "speakerNotes") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "speakerNotes") }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Speaker Notes"
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: NotesEditor())
            p.setFrameAutosaveName("CloseupSpeakerNotes")
            if !p.setFrameUsingName("CloseupSpeakerNotes"), let v = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: v.maxX - 360, y: v.maxY - 290))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct NotesEditor: View {
    @State private var text = SpeakerNotes.shared.text
    @AppStorage("speakerNotesSize") private var size = 16.0

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: size))
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: text) { SpeakerNotes.shared.text = text }
            Divider()
            HStack {
                Text("Not recorded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { size = max(11, size - 2) } label: { Image(systemName: "textformat.size.smaller") }
                Button { size = min(40, size + 2) } label: { Image(systemName: "textformat.size.larger") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
