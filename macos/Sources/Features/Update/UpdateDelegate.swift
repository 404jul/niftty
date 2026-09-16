import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // We ship separate arm64 and x86_64 archives from our GitHub
        // Releases to halve the download size, so each architecture
        // follows its own appcast feed. The "latest/download" URL is a
        // stable GitHub redirect to the newest published release.
        //
        // Note: Sparkle has no appcast attribute for selecting an
        // enclosure by CPU architecture, so per-arch feeds selected here
        // is the supported approach (see Sparkle discussions #2283).
        #if arch(arm64)
        return "https://github.com/404jul/niftty/releases/latest/download/appcast-arm64.xml"
        #elseif arch(x86_64)
        return "https://github.com/404jul/niftty/releases/latest/download/appcast-x86_64.xml"
        #else
        return nil
        #endif
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
