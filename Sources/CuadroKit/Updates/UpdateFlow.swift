import Foundation

public struct UpdateOffer: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case notDownloaded, downloaded, installing }
    public enum NotesFormat: Equatable, Sendable { case markdown, html, plainText }

    public var version: String
    public var currentVersion: String
    public var size: UInt64?
    public var notes: String?
    public var notesFormat: NotesFormat = .markdown
    public var fullNotesURL: URL?
    public var infoURL: URL?
    public var isInformationOnly = false
    public var isCritical = false
    public var stage: Stage = .notDownloaded

    public init(version: String, currentVersion: String) {
        self.version = version
        self.currentVersion = currentVersion
    }
}

public enum UpdatePhase: Equatable, Sendable {
    case permission
    case checking
    case available(UpdateOffer)
    case downloading(UpdateOffer?, received: UInt64, expected: UInt64?)
    case preparing(UpdateOffer?, progress: Double?)
    case ready(UpdateOffer?)
    case installing(UpdateOffer?, canRetry: Bool)
    case upToDate(currentVersion: String)
    case unavailable(title: String, message: String?)
    case failed(message: String)
    case installed
}

public enum UpdateChoice: Equatable, Sendable { case install, later, skip }

/// The next visible step after an answer, independent of Sparkle's callbacks.
public enum UpdateFlow {
    public static func after(_ choice: UpdateChoice, in phase: UpdatePhase?, offer: UpdateOffer?) -> (phase: UpdatePhase?, relaunchWhenReady: Bool) {
        guard choice == .install else { return (nil, false) }
        guard case let .available(found)? = phase else {
            return (.installing(offer, canRetry: false), false)
        }
        switch found.stage {
        case .notDownloaded: return (.downloading(found, received: 0, expected: nil), false)
        case .downloaded: return (.preparing(found, progress: nil), true)
        case .installing: return (.installing(found, canRetry: false), false)
        }
    }

    public static func downloadFraction(received: UInt64, expected: UInt64?) -> Double? {
        guard let expected, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }

    public static func canSkip(_ offer: UpdateOffer) -> Bool {
        !offer.isCritical && offer.stage != .installing
    }
}
