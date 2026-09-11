import AppKit
import SwiftUI

final class SettingsController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel

    init(appDelegate: AppDelegate) {
        self.model = SettingsModel(appDelegate: appDelegate)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: window)

        window.title = "Niftty Settings"
        window.minSize = NSSize(width: 800, height: 560)
        window.center()
        window.setFrameAutosaveName("NifttySettings")
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show() {
        model.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Apply settings before closing?"
        alert.informativeText = "Your changes have not been written to the Niftty config file."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Apply")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return !model.hasUnsavedChanges
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }
}
