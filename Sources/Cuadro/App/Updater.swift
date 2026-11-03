import AppKit
import Observation
@preconcurrency import Sparkle

/// Sparkle owns checking, verification and installation; Cuadro owns its UI.
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var unavailableReason = "Updates are available in the packaged Cuadro.app."
    var checksAutomatically = false {
        didSet {
            if updater?.automaticallyChecksForUpdates != checksAutomatically {
                updater?.automaticallyChecksForUpdates = checksAutomatically
            }
        }
    }

    var installsAutomatically = false {
        didSet {
            if updater?.automaticallyDownloadsUpdates != installsAutomatically {
                updater?.automaticallyDownloadsUpdates = installsAutomatically
            }
        }
    }

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    let driver = UpdateDriver()

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        guard updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            let reason = "Updates could not start: \(error.localizedDescription)"
            unavailableReason = reason
            Log.app.error("\(reason, privacy: .public)")
            return
        }
        self.updater = updater
        isAvailable = true
        driver.checkAgain = { [weak self] in self?.checkForUpdates() }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.installsAutomatically = updater.automaticallyDownloadsUpdates }
            },
        ]
    }

    func checkForUpdates() {
        driver.showUpdateInFocus()
        updater?.checkForUpdates()
    }
}
