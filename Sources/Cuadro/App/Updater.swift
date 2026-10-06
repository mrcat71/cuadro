import AppKit
@preconcurrency import Sparkle

/// In-app updates through Sparkle. The feed is the `appcast.xml` asset of the latest GitHub
/// release (`SUFeedURL` in Info.plist), and every archive is checked against `SUPublicEDKey`.
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// Starts scheduled checks. Builds without a feed URL (`swift run`, UI snapshots) skip it.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    /// False while a check or an install is already running.
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: Gentle reminders
    // A menu bar app has no Dock icon to show behind, so Sparkle asks for these: put Cuadro in the
    // Dock while an update is on screen, badge it for updates found in the background.

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        DockPresence.shared.isShowingUpdate = true
        if !state.userInitiated {
            NSApp.dockTile.badgeLabel = "1"
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = ""
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.dockTile.badgeLabel = ""
        DockPresence.shared.isShowingUpdate = false
    }
}
