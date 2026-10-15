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

    /// Teleprompter: scrolls the notes upward at a steady pace.
    func togglePrompter() {
        show()
        Prompter.shared.running.toggle()
        if Prompter.shared.running { Prompter.shared.offset = max(0, Prompter.shared.offset) }
    }
}

@MainActor
@Observable
final class Prompter {
    static let shared = Prompter()
    var running = false
    var offset: Double = 0
    var speed: Double = UserDefaults.standard.object(forKey: "prompterSpeed") as? Double ?? 30 {   // points per second
        didSet { UserDefaults.standard.set(speed, forKey: "prompterSpeed") }
    }
}

private struct NotesEditor: View {
    @State private var text = SpeakerNotes.shared.text
    @AppStorage("speakerNotesSize") private var size = 16.0
    @Bindable private var prompter = Prompter.shared
    private let tick = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if prompter.running {
                GeometryReader { geo in
                    Text(text)
                        .font(.system(size: size * 1.4, weight: .medium))
                        .frame(width: geo.size.width - 24, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, geo.size.height * 0.4)
                        .offset(y: -prompter.offset)
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { prompter.running = false }
            } else {
                TextEditor(text: $text)
                    .font(.system(size: size))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: text) { SpeakerNotes.shared.text = text }
            }
            Divider()
            HStack {
                Button {
                    if !prompter.running && prompter.offset > 0 && prompter.offset > Double(text.count) { prompter.offset = 0 }
                    prompter.running.toggle()
                } label: { Image(systemName: prompter.running ? "pause.fill" : "play.fill") }
                .help("Prompter (\(Hotkeys.shared.label(.prompter)))")
                Button { prompter.offset = 0 } label: { Image(systemName: "backward.end.fill") }
                    .help("Back to the top")
                Slider(value: $prompter.speed, in: 10...120).frame(width: 80).help("Prompter speed")
                Text("Not recorded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { size = max(11, size - 2) } label: { Image(systemName: "textformat.size.smaller") }
                Button { size = min(40, size + 2) } label: { Image(systemName: "textformat.size.larger") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onReceive(tick) { _ in
            if prompter.running { prompter.offset += prompter.speed / 30 }
        }
    }
}
