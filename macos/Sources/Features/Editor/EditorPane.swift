import AppKit
import SwiftUI

final class EditorDocument: NSObject, ObservableObject {
    let url: URL

    @Published var text: String {
        didSet { isDirty = text != savedText }
    }
    @Published private(set) var isDirty = false
    @Published private(set) var saveError: String?

    private var savedText: String

    init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.url = url
        self.text = text
        self.savedText = text
    }

    func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

final class EditorPaneStore {
    static let shared = EditorPaneStore()

    private let documents = NSMapTable<Ghostty.SurfaceView, EditorDocument>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    func document(for surface: Ghostty.SurfaceView) -> EditorDocument? {
        documents.object(forKey: surface)
    }

    func attach(_ document: EditorDocument, to surface: Ghostty.SurfaceView) {
        documents.setObject(document, forKey: surface)
    }
}

extension Ghostty.SurfaceView {
    var editorDocument: EditorDocument? {
        EditorPaneStore.shared.document(for: self)
    }
}

extension Notification.Name {
    static let editorPaneFocusRequested = Notification.Name("com.niftty.editorPaneFocusRequested")
}

struct EditorPane: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var document: EditorDocument

    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.secondary)
                Text(document.url.lastPathComponent)
                    .lineLimit(1)
                    .help(document.url.path)

                if document.isDirty {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let saveError = document.saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(saveError)
                }

                Button("Save", systemImage: "square.and.arrow.down") {
                    document.save()
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!document.isDirty)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            PlainTextEditor(document: document, backgroundColor: NSColor(ghostty.config.backgroundColor))
                .focused($editorFocused)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
                .focusedValue(\.ghosttySurfacePwd, document.url.deletingLastPathComponent().path)
                .background(ghostty.config.backgroundColor)
        }
        .background {
            Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: isSplit)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            if BaseTerminalController.controller(owning: surfaceView)?.focusedSurface === surfaceView {
                editorFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorPaneFocusRequested)) { notification in
            guard notification.object as? Ghostty.SurfaceView === surfaceView else { return }
            editorFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text editor pane")
    }
}

final class EditorTextView: NSTextView {
    private let editorUndoManager = UndoManager()
    var saveDocument: (() -> Void)?

    override var undoManager: UndoManager? {
        editorUndoManager
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] || modifiers == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch (key, modifiers.contains(.shift)) {
        case ("z", false):
            editorUndoManager.undo()
        case ("z", true):
            editorUndoManager.redo()
        case ("a", false):
            selectAll(nil)
        case ("x", false):
            cut(nil)
        case ("c", false):
            copy(nil)
        case ("v", false):
            paste(nil)
        case ("s", false):
            saveDocument?()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let backgroundColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor

        let textView = EditorTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.saveDocument = document.save
        textView.string = document.text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.backgroundColor = backgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        if textView.string != document.text {
            textView.string = document.text
        }
        if textView.backgroundColor != backgroundColor {
            scrollView.backgroundColor = backgroundColor
            textView.backgroundColor = backgroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let document: EditorDocument

        init(document: EditorDocument) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            document.text = textView.string
        }
    }
}
