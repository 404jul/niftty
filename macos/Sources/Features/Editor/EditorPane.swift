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
            .background(Color(nsColor: .controlBackgroundColor).opacity(ghostty.config.backgroundOpacity))

            Divider()

            PlainTextEditor(document: document)
                .clipped()
                .focused($editorFocused)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
                .focusedValue(\.ghosttySurfacePwd, document.url.deletingLastPathComponent().path)
        }
        .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
        .background {
            Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: isSplit)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            Ghostty.SurfaceGrabHandle(surfaceView: surfaceView, dragHandle: ghostty.config.dragHandle)
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

    fileprivate weak var lineNumberView: LineNumberView?

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

private final class LineNumberView: NSView {
    static let width: CGFloat = 40

    private weak var textView: NSTextView?
    private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    init(textView: NSTextView, clipView: NSClipView) {
        self.textView = textView
        super.init(frame: .zero)

        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()


        layoutManager.ensureLayout(for: textContainer)
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY),
            to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)
        )
        let visibleRect = textView.visibleRect
        let containerRect = visibleRect.offsetBy(
            dx: -textView.textContainerInset.width,
            dy: -textView.textContainerInset.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString
        var lineNumber = string.substring(to: min(charRange.location, string.length))
            .filter { $0 == "\n" }.count + 1

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, lineGlyphRange, _ in
            let range = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            let isLogicalLineStart = range.location == 0
                || string.character(at: range.location - 1) == 0x0A

            if isLogicalLineStart {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                let y = lineRect.minY + textView.textContainerInset.height
                    - visibleRect.minY + (lineRect.height - size.height) / 2
                label.draw(
                    at: NSPoint(x: self.bounds.maxX - size.width - 6, y: y),
                    withAttributes: attributes
                )
            }

            if range.length > 0 {
                lineNumber += string.substring(with: range).filter { $0 == "\n" }.count
            }
        }
    }
}

private final class EditorContainerView: NSView {
    let textView: EditorTextView

    private let scrollView: NSScrollView
    private let lineNumberView: LineNumberView

    init(
        scrollView: NSScrollView,
        textView: EditorTextView,
        lineNumberView: LineNumberView
    ) {
        self.scrollView = scrollView
        self.textView = textView
        self.lineNumberView = lineNumberView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(lineNumberView)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    override func layout() {
        super.layout()

        let gutterWidth = min(LineNumberView.width, bounds.width)
        lineNumberView.frame = NSRect(
            x: 0,
            y: 0,
            width: gutterWidth,
            height: bounds.height
        )
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(0, bounds.width - gutterWidth),
            height: bounds.height
        )
        lineNumberView.needsDisplay = true
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The SwiftUI layer behind this view paints the (possibly translucent)
        // theme background; drawing it again here would stack alpha and make
        // the text area more opaque than the rest of the pane.
        scrollView.drawsBackground = false

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
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        scrollView.documentView = textView

        let lineNumberView = LineNumberView(textView: textView, clipView: scrollView.contentView)
        textView.lineNumberView = lineNumberView

        return EditorContainerView(
            scrollView: scrollView,
            textView: textView,
            lineNumberView: lineNumberView
        )
    }

    func updateNSView(_ containerView: EditorContainerView, context: Context) {
        let textView = containerView.textView
        if textView.string != document.text {
            textView.string = document.text
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let document: EditorDocument

        init(document: EditorDocument) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            document.text = textView.string
            textView.lineNumberView?.needsDisplay = true
        }
    }
}

