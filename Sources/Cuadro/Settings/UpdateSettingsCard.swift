import AppKit
import CuadroKit
import SwiftUI

struct UpdateSettingsCard: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        SettingsGroup {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cuadro").font(.system(size: 13, weight: .semibold))
                    Text("Version \(Updater.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            if let phase = updater.driver.phase {
                Divider()
                UpdateStatusView(phase: phase, driver: updater.driver)
            }
            if updater.isAvailable {
                Divider()
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Text("Look for a new version once a day.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Install updates automatically", isOn: $updater.installsAutomatically)
                    .disabled(!updater.checksAutomatically)
                Text("Download new versions in the background and install them when you quit Cuadro.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(updater.unavailableReason)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { updater.driver.receivedAttention() }
    }
}

/// Every Sparkle state has a real action, including cancellation and retry.
struct UpdateStatusView: View {
    let phase: UpdatePhase
    let driver: UpdateDriver
    @State private var showsReleaseNotes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .permission:
                heading("Check for updates automatically?", symbol: "arrow.triangle.2.circlepath")
                detail("Cuadro looks for new versions once a day. You choose whether to install them. No system profile is sent.")
                actions {
                    Button("Not Now") { driver.allowAutomaticChecks(false) }
                    Button("Check Automatically") { driver.allowAutomaticChecks(true) }
                        .buttonStyle(.borderedProminent)
                }
            case .checking:
                heading("Checking for updates…", symbol: "arrow.triangle.2.circlepath")
                ProgressView().progressViewStyle(.linear)
                actions { Button("Cancel") { driver.cancel() } }
            case let .available(offer):
                available(offer)
            case let .downloading(offer, received, expected):
                heading("Downloading \(name(offer))…", symbol: "arrow.down")
                ProgressView(value: UpdateFlow.downloadFraction(received: received, expected: expected))
                detail(expected.flatMap { $0 > 0 ? "\(bytes(received)) of \(bytes($0))" : nil } ?? "\(bytes(received)) downloaded")
                actions { Button("Cancel") { driver.cancel() } }
            case let .preparing(offer, progress):
                heading("Preparing \(name(offer))…", symbol: "shippingbox")
                ProgressView(value: progress)
                detail("Verifying the download and unpacking it.")
            case let .ready(offer):
                heading("\(name(offer)) is ready", symbol: "checkmark.circle", tint: .green)
                detail("Relaunch to finish updating, or install it the next time you quit. Save any open edits before relaunching.")
                actions {
                    Button("Later") { driver.answer(.later) }
                    Button("Relaunch to Update") { driver.answer(.install) }.buttonStyle(.borderedProminent)
                }
            case let .installing(offer, canRetry):
                heading("Installing \(name(offer))…", symbol: "shippingbox")
                ProgressView().progressViewStyle(.linear)
                detail("Cuadro quits, installs the update, and opens again.")
                if canRetry {
                    actions { Button("Quit and Install") { driver.retryQuit() } }
                }
            case let .upToDate(version):
                heading("Cuadro is up to date", symbol: "checkmark.circle", tint: .green)
                detail("\(version) is the newest version.")
                actions { Button("Done") { driver.acknowledge() } }
            case let .unavailable(title, message):
                heading(title, symbol: "info.circle")
                if let message {
                    detail(message)
                }
                actions { Button("Done") { driver.acknowledge() } }
            case let .failed(message):
                heading("The update did not finish", symbol: "exclamationmark.triangle", tint: .red)
                detail(message)
                actions {
                    Button("Dismiss") { driver.acknowledge() }
                    Button("Try Again") { driver.retry() }.buttonStyle(.borderedProminent)
                }
            case .installed:
                heading("Cuadro is updated", symbol: "checkmark.circle", tint: .green)
                actions { Button("Done") { driver.acknowledge() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func available(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Cuadro \(offer.version) is available", symbol: "arrow.down.circle", tint: offer.isCritical ? .orange : .accentColor)
            if offer.isInformationOnly {
                detail("You have \(offer.currentVersion). This version is available from its website.")
            } else if offer.stage == .notDownloaded {
                detail("You have \(offer.currentVersion)." + (offer.size.map { " The download is \(bytes($0))." } ?? ""))
            } else {
                detail("Already downloaded. Save any open edits before relaunching to finish updating.")
            }
            if offer.isCritical {
                detail("This is an important update.")
            }
            if let notes = offer.notes, !notes.isEmpty {
                DisclosureGroup("What's New", isExpanded: $showsReleaseNotes) {
                    ScrollView {
                        UpdateReleaseNotesText(text: notes, format: offer.notesFormat)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 200)
                }
            }
            if let url = offer.fullNotesURL {
                Link("Full Release Notes", destination: url)
            }
            actions {
                if UpdateFlow.canSkip(offer) {
                    Button("Skip This Version") { driver.answer(.skip) }
                }
                Button("Later") { driver.answer(.later) }
                if offer.isInformationOnly {
                    if let url = offer.infoURL {
                        Link("Learn More", destination: url)
                    }
                } else {
                    Button(offer.stage == .notDownloaded ? "Update" : "Relaunch to Update") { driver.answer(.install) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func heading(_ title: String, symbol: String, tint: Color = .accentColor) -> some View {
        Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.system(size: 13, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func actions(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { Spacer(minLength: 0); content() }.controlSize(.small)
    }

    private func name(_ offer: UpdateOffer?) -> String {
        offer.map { "Cuadro \($0.version)" } ?? "the update"
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

private struct UpdateReleaseNotesText: View {
    let text: String
    let format: UpdateOffer.NotesFormat
    @State private var formatted = AttributedString()

    var body: some View {
        Text(formatted)
            // AppKit's HTML importer may run the run loop. Never invoke it during a SwiftUI body evaluation.
            .task(id: text) { formatted = formatNotes() }
    }

    private func formatNotes() -> AttributedString {
        do {
            switch format {
            case .markdown:
                return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            case .plainText:
                return AttributedString(text)
            case .html:
                // Convert to inert text, not a web view that can execute feed content.
                let notes = try NSAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                return AttributedString(notes.string)
            }
        } catch {
            Log.app.error("Could not format release notes: \(error.localizedDescription, privacy: .public)")
            return AttributedString(text)
        }
    }
}
