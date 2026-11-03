import AppKit
import CuadroKit
import Observation
@preconcurrency import Sparkle

/// Adapts Sparkle's pending replies to the update card in General settings.
@Observable
final class UpdateDriver: NSObject, SPUUserDriver {
    private(set) var attentionRequest = 0
    private(set) var phase: UpdatePhase? {
        didSet {
            DockPresence.shared.isShowingUpdate = phase != nil
            if phase == nil {
                NSApp.dockTile.badgeLabel = ""
            }
        }
    }

    @ObservationIgnored var checkAgain: () -> Void = {}
    @ObservationIgnored private var offer: UpdateOffer?
    @ObservationIgnored private var expectedLength: UInt64?
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var relaunchWhenReady = false
    @ObservationIgnored private var permissionReply: ((SUUpdatePermissionResponse) -> Void)?
    @ObservationIgnored private var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    @ObservationIgnored private var retryTermination: (() -> Void)?

    func show(_: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        permissionReply = reply
        phase = .permission
        showUpdateInFocus()
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        relaunchWhenReady = false
        var offer = UpdateOffer(version: item.displayVersionString, currentVersion: Updater.version)
        offer.size = item.contentLength > 0 ? item.contentLength : nil
        offer.notes = item.itemDescription
        switch item.itemDescriptionFormat?.lowercased() {
        case "markdown": offer.notesFormat = .markdown
        case "plain-text": offer.notesFormat = .plainText
        default: offer.notesFormat = .html
        }
        offer.fullNotesURL = item.fullReleaseNotesURL
        offer.infoURL = item.infoURL
        offer.isInformationOnly = item.isInformationOnlyUpdate
        offer.isCritical = item.isCriticalUpdate
        switch state.stage {
        case .downloaded: offer.stage = .downloaded
        case .installing: offer.stage = .installing
        default: offer.stage = .notDownloaded
        }
        self.offer = offer
        choiceReply = reply
        phase = .available(offer)
        if state.userInitiated {
            showUpdateInFocus()
        } else {
            // Scheduled checks never take focus away from a capture or editor.
            NSApp.dockTile.badgeLabel = "1"
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard var offer, let text = String(data: downloadData.data, encoding: .utf8) else { return }
        offer.notes = text
        let type = downloadData.mimeType?.lowercased() ?? ""
        offer.notesFormat = type.contains("html") ? .html : (type.contains("markdown") ? .markdown : .plainText)
        self.offer = offer
        if case .available = phase {
            phase = .available(offer)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        Log.app.error("Release notes did not download: \(error.localizedDescription, privacy: .public)")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        let error = error as NSError
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) } ?? .unknown
        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion:
            phase = .upToDate(currentVersion: Updater.version)
        default:
            phase = .unavailable(title: error.localizedDescription, message: error.localizedRecoverySuggestion)
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        choiceReply = nil
        self.acknowledgement = acknowledgement
        let error = error as NSError
        Log.app.error("Update failed: \(error.localizedDescription, privacy: .public)")
        phase = .failed(message: [error.localizedDescription, error.localizedRecoverySuggestion].compactMap(\.self).joined(separator: " "))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        receivedLength = 0
        expectedLength = nil
        phase = .downloading(offer, received: 0, expected: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength > 0 ? expectedContentLength : nil
        phase = .downloading(offer, received: receivedLength, expected: expectedLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        phase = .downloading(offer, received: receivedLength, expected: expectedLength)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .preparing(offer, progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .preparing(offer, progress: min(max(progress, 0), 1))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if relaunchWhenReady {
            relaunchWhenReady = false
            phase = .installing(offer, canRetry: false)
            reply(.install)
        } else {
            choiceReply = reply
            phase = .ready(offer)
        }
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = terminated ? nil : retryTerminatingApplication
        phase = .installing(offer, canRetry: !terminated)
    }

    func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement: @escaping () -> Void) {
        phase = .installed
        acknowledgement()
    }

    func showUpdateInFocus() {
        attentionRequest += 1
        SettingsWindowController.shared.showGeneral()
    }

    func receivedAttention() {
        NSApp.dockTile.badgeLabel = ""
    }

    func dismissUpdateInstallation() {
        permissionReply = nil
        choiceReply = nil
        cancellation = nil
        retryTermination = nil
        relaunchWhenReady = false
        offer = nil
        phase = nil
        acknowledgement = nil
    }

    func answer(_ choice: UpdateChoice) {
        guard let reply = choiceReply else { return }
        choiceReply = nil
        let next = UpdateFlow.after(choice, in: phase, offer: offer)
        relaunchWhenReady = next.relaunchWhenReady
        phase = next.phase
        switch choice {
        case .install: reply(.install)
        case .later: reply(.dismiss)
        case .skip: reply(.skip)
        }
    }

    func cancel() {
        let cancel = cancellation
        cancellation = nil
        phase = nil
        cancel?()
    }

    func acknowledge() {
        let acknowledge = acknowledgement
        acknowledgement = nil
        phase = nil
        acknowledge?()
    }

    func retry() {
        acknowledge()
        checkAgain()
    }

    func retryQuit() {
        retryTermination?()
    }

    func allowAutomaticChecks(_ allow: Bool) {
        guard let reply = permissionReply else { return }
        permissionReply = nil
        phase = nil
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: allow, sendSystemProfile: false))
    }
}
