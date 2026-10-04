import AppKit
import Combine
import SwiftUI
import WebKit

/// Normalizes address-bar input into a navigation destination.
///
/// - Explicit http/https/file URLs are kept as-is.
/// - Host-like input (has a dot, is localhost, or is an absolute path) gets an
///   https:// prefix.
/// - Everything else becomes a DuckDuckGo search.
/// - Unknown schemes and empty input are rejected (return nil, no dispatch).
enum BrowserDestination {
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Input with an authority component is an explicit URL. Only allow
        // well-understood, non-executing schemes.
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else { return nil }
            return url
        }

        // Host-like input gets an https:// prefix. This deliberately runs
        // after the "://" check so "localhost:3000" (which URL(string:)
        // would parse as a custom scheme named "localhost") and
        // "192.168.1.4:8080" are treated as hosts.
        let hostLike = trimmed.hasPrefix("localhost")
            || trimmed.hasPrefix("/")
            || (trimmed.contains(".") && !trimmed.contains(" "))
        if hostLike, let url = URL(string: "https://\(trimmed)") {
            return url
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "duckduckgo.com"
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}

/// The state of one browser pane. Owned by `BrowserPaneStore`, keyed weakly
/// by its hosting `Ghostty.SurfaceView` — same lifecycle as `EditorDocument`.
final class BrowserDocument: NSObject, ObservableObject {
    /// The current page URL, or nil when the pane shows the start page.
    @Published var url: URL?
    @Published var addressText: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    init(url: URL? = nil) {
        self.url = url
        self.addressText = url?.absoluteString ?? ""
    }

    /// Navigate from address-bar input. Nil destination (unknown scheme or
    /// empty) is a no-op.
    func navigate(_ input: String) {
        guard let target = BrowserDestination.destination(for: input) else { return }
        addressText = target.absoluteString
        url = target
    }
}

final class BrowserPaneStore {
    static let shared = BrowserPaneStore()

    private let documents = NSMapTable<Ghostty.SurfaceView, BrowserDocument>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    func document(for surface: Ghostty.SurfaceView) -> BrowserDocument? {
        documents.object(forKey: surface)
    }

    func attach(_ document: BrowserDocument, to surface: Ghostty.SurfaceView) {
        documents.setObject(document, forKey: surface)
    }
}

extension Ghostty.SurfaceView {
    var browserDocument: BrowserDocument? {
        BrowserPaneStore.shared.document(for: self)
    }
}

extension Notification.Name {
    static let browserPaneFocusRequested = Notification.Name("com.niftty.browserPaneFocusRequested")
}

/// Holds a weak reference to the live WKWebView so toolbar buttons and the
/// focus notification can drive it imperatively.
final class WebViewBox {
    weak var webView: WKWebView?
}

struct BrowserPane: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var document: BrowserDocument

    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool

    @FocusState private var addressFocused: Bool
    @State private var webViewBox = WebViewBox()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if document.url == nil {
                    startPage
                } else {
                    BrowserWebView(document: document, box: webViewBox)
                }
            }
            .clipped()
        }
        // Same theme treatment as EditorPane: the pane background always
        // respects background + background-opacity, so the empty tab matches
        // the terminal theme and translucency.
        .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
        .background {
            // Keep the real (hidden) surface alive for focus/drag plumbing,
            // exactly like EditorPane does.
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
                addressFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPaneFocusRequested)) { notification in
            guard notification.object as? Ghostty.SurfaceView === surfaceView else { return }
            if let webView = webViewBox.webView {
                webView.window?.makeFirstResponder(webView)
            } else {
                addressFocused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser pane")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                webViewBox.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!document.canGoBack)
            .accessibilityLabel("Back")

            Button {
                webViewBox.webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!document.canGoForward)
            .accessibilityLabel("Forward")

            Button {
                if document.isLoading {
                    webViewBox.webView?.stopLoading()
                } else {
                    webViewBox.webView?.reload()
                }
            } label: {
                Image(systemName: document.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(document.isLoading ? "Stop" : "Reload")

            TextField("Search or enter address", text: $document.addressText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { document.navigate(document.addressText) }
                .focused($addressFocused)
                .focusedValue(\.ghosttySurfaceView, surfaceView)

            if document.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(ghostty.config.backgroundOpacity))
    }

    private var startPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Enter an address above to start browsing")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var document: BrowserDocument
    let box: WebViewBox

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Style the overlay scrollbars: WebKit's default dark thumb is invisible
        // on dark pages and its track paints solid black bars along the bottom
        // and right edges. Inject a transparent track and a thumb that contrasts
        // with the theme background.
        config.userContentController.addUserScript(scrollbarScript())
        let webView = WKWebView(frame: .zero, configuration: config)
        // Pages draw their own background; behind content, use the theme so
        // there is no white flash during loads.
        webView.underPageBackgroundColor = NSColor(ghostty.config.backgroundColor)
        webView.navigationDelegate = context.coordinator
        box.webView = webView
        context.coordinator.observe(webView)
        if let url = document.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Load only when the model points somewhere the webview isn't yet.
        // In-page navigation updates the model from didCommit, so this never
        // double-loads.
        if let url = document.url, webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let document: BrowserDocument
        private var cancellables: Set<AnyCancellable> = []

        init(document: BrowserDocument) {
            self.document = document
        }

        func observe(_ webView: WKWebView) {
            webView.publisher(for: \.canGoBack)
                .assign(to: \.canGoBack, on: document)
                .store(in: &cancellables)
            webView.publisher(for: \.canGoForward)
                .assign(to: \.canGoForward, on: document)
                .store(in: &cancellables)
            webView.publisher(for: \.title)
                .map { $0 ?? "" }
                .assign(to: \.pageTitle, on: document)
                .store(in: &cancellables)
            webView.publisher(for: \.estimatedProgress)
                .map { $0 < 1.0 }
                .removeDuplicates()
                .assign(to: \.isLoading, on: document)
                .store(in: &cancellables)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            document.url = webView.url
            document.addressText = webView.url?.absoluteString ?? ""
        }
    }

    /// Injected CSS: keep the scrollbar track transparent (no dark bars at the
    /// page edges) and give the thumb enough contrast against the theme
    /// background to stay visible.
    private func scrollbarScript() -> WKUserScript {
        let background = NSColor(ghostty.config.backgroundColor)
        // luminance throws on color spaces that don't support it; convert first.
        let isDark = (background.usingColorSpace(.sRGB)?.luminance ?? 0.5) < 0.5
        // Thumb shade opposite to the background: light thumb on dark themes,
        // dark thumb on light themes, always translucent.
        let thumb = isDark ? "rgba(255, 255, 255, 0.40)" : "rgba(0, 0, 0, 0.35)"
        let thumbHover = isDark ? "rgba(255, 255, 255, 0.60)" : "rgba(0, 0, 0, 0.55)"
        let css = """
        ::-webkit-scrollbar { width: 12px; height: 12px; background: transparent; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-corner { background: transparent; }
        ::-webkit-scrollbar-thumb {
            background: \(thumb);
            border-radius: 7px;
            border: 3px solid transparent;
            background-clip: padding-box;
        }
        ::-webkit-scrollbar-thumb:hover { background-color: \(thumbHover); }
        """
        return WKUserScript(
            source: "(function(){ var s = document.createElement('style'); s.textContent = \(json(css)); (document.head || document.documentElement).appendChild(s); })();",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
    }

    private func json(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let encoded = String(data: data, encoding: .utf8) else { return "''" }
        return encoded
    }
}
