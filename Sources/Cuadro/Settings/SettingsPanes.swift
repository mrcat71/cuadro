import AppKit
import CuadroKit
import SwiftUI

private let paneWidth: CGFloat = 540

struct GeneralSettingsPane: View {
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var checksForUpdates = Updater.shared.checksAutomatically

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LoginItem.set(enabled)
                        launchAtLogin = LoginItem.isEnabled
                    }
                Toggle("Show icon in the menu bar", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open Cuadro again from Finder or Spotlight to get back to Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show in the Dock while an editor is open", isOn: $settings.showDockIconWhileEditing)
                    .onChange(of: settings.showDockIconWhileEditing) { _, _ in DockPresence.shared.update() }
            }
            if Updater.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, enabled in
                            Updater.shared.checksAutomatically = enabled
                        }
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                }
            }
            Section("After a capture") {
                Toggle("Copy to the clipboard", isOn: $settings.copyToClipboard)
                Toggle("Save to the screenshots folder", isOn: $settings.autoSave)
                Picker("Then", selection: $settings.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                if settings.afterCapture == .showThumbnail {
                    Picker("Keep the thumbnail for", selection: $settings.thumbnailSeconds) {
                        ForEach([4.0, 6, 10, 30], id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                }
                Toggle("Play the shutter sound", isOn: $settings.playSound)
            }
            Section("History") {
                Toggle("Keep recent captures", isOn: $settings.keepHistory)
                Picker("Number of captures", selection: $settings.historyLimit) {
                    ForEach([10, 30, 50, 100], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .disabled(!settings.keepHistory)
                Button("Clear History") { HistoryStore.shared.clear() }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CaptureSettingsPane: View {
    @Bindable private var settings = AppSettings.shared
    @State private var status = PermissionStatus()

    var body: some View {
        Form {
            Section("Screenshots") {
                Toggle("Include the mouse pointer", isOn: $settings.showCursor)
                Toggle("Include window shadows", isOn: $settings.windowShadow)
                Toggle("Show the magnifier while selecting", isOn: $settings.showMagnifier)
                Picker("Delayed capture", selection: $settings.delaySeconds) {
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                Toggle("Convert colors to sRGB", isOn: $settings.convertToSRGB)
                Text("Keeps hex values consistent across displays. Off keeps the display's own color profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Screen recording") {
                Toggle("Show the pointer", isOn: $settings.recordPointer)
                Toggle("Highlight clicks", isOn: $settings.recordClicks)
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Text("Record Screen with Microphone also records the microphone; the microphone button next to Record switches it for one recording. Recordings are saved as MP4 next to your screenshots, copied to the clipboard and shown in Finder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Color picker") {
                Picker("Copy colors as", selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            }
            Section("Scrolling capture") {
                Picker("Maximum height", selection: $settings.scrollMaxHeight) {
                    ForEach([10_000, 20_000, 50_000, 100_000], id: \.self) { height in
                        Text("\(height.formatted()) px").tag(height)
                    }
                }
                LabeledContent("Auto-scroll speed") {
                    Slider(value: $settings.autoScrollSpeed, in: 0.5...3)
                        .frame(width: 200)
                }
                LabeledContent("Accessibility") {
                    if status.accessibility {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow for Auto-Scroll…") {
                            PermissionCenter.shared.requestAccessibility()
                            PermissionCenter.shared.openAccessibilitySettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
    }
}

struct OutputSettingsPane: View {
    @Bindable private var settings = AppSettings.shared

    private var preview: String {
        let name = FileNameTemplate.render(settings.fileNameTemplate, context: .init(width: 1440, height: 900, appName: "Safari", counter: 1))
        return "\(name).\(settings.imageFormat.fileExtension)"
    }

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text((settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        Button {
                            NSWorkspace.shared.open(settings.saveFolder)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                }
                TextField("File name", text: $settings.fileNameTemplate)
                LabeledContent("Example") {
                    Text(preview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                DisclosureGroup("Tokens") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(FileNameTemplate.tokens, id: \.token) { token in
                            GridRow {
                                Text(token.token).font(.system(.body, design: .monospaced))
                                Text(token.meaning).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                if settings.imageFormat != .png {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $settings.jpegQuality, in: 0.4...1)
                                .frame(width: 180)
                            Text("\(Int(settings.jpegQuality * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Retina") {
                Toggle("Downscale Retina screenshots to 1x", isOn: $settings.downscaleRetina)
                Text("Copies and files get half the pixels, matching what you saw on screen in points.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

struct ShortcutsSettingsPane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(AppAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action, settings: settings)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } footer: {
                Text("Shortcuts work in every app. Add Control to a capture shortcut, or hold Control as you finish a selection, to copy the screenshot without opening anything. macOS keeps ⇧⌘3, ⇧⌘4 and ⇧⌘5 unless you turn them off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { settings.resetShortcuts() }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EditorSettingsPane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Markup") {
                Toggle("Add soft shadows to new markup", isOn: $settings.annotationShadows)
                Button("Reset Tool Colors and Sizes") { settings.resetToolStyles() }
            }
            Section("Tool keys") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: EditorTool.allCases.count, by: 2)), id: \.self) { index in
                        GridRow {
                            toolLabel(EditorTool.allCases[index])
                            if index + 1 < EditorTool.allCases.count {
                                toolLabel(EditorTool.allCases[index + 1])
                            }
                        }
                    }
                }
                Text("Hold Space to pan, ⌘ and scroll or pinch to zoom, Shift to constrain, 1 to 9 for spotlight darkness.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toolLabel(_ tool: EditorTool) -> some View {
        HStack(spacing: 8) {
            Text(String(tool.key).uppercased())
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 22, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Label(tool.title, systemImage: tool.symbol)
        }
    }
}

struct AboutSettingsPane: View {
    @State private var status = PermissionStatus()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Cuadro")
                .font(.system(size: 24, weight: .bold))
            Text(version)
                .foregroundStyle(.secondary)
            Text("A free, native screenshot tool for macOS.")
            PermissionList(status: status)
            Link("github.com/mrcat71/cuadro", destination: URL(string: "https://github.com/mrcat71/cuadro")!)
        }
        .padding(28)
        .frame(width: paneWidth)
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
    }
}
