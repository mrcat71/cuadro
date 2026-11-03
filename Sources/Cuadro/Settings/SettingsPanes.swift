import AppKit
import CuadroKit
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var updater = Updater.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        ScrollViewReader { scroll in
            SettingsPage {
                UpdateSettingsCard()
                    .id("app-updates")
                SettingsGroup("Startup and appearance") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            LoginItem.set(enabled)
                            launchAtLogin = LoginItem.isEnabled
                        }
                    Toggle("Show icon in the menu bar", isOn: $settings.showMenuBarIcon)
                    if !settings.showMenuBarIcon {
                        Text("To get back to Settings, open Cuadro again from Finder or Spotlight, or choose Settings… in the editor's \(Image(systemName: "ellipsis")) menu. Without the icon, start captures with the shortcuts you set in Shortcuts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show in the Dock while an editor is open", isOn: $settings.showDockIconWhileEditing)
                        .onChange(of: settings.showDockIconWhileEditing) { _, _ in DockPresence.shared.update() }
                }
                SettingsGroup("After a capture") {
                    Toggle("Copy to the clipboard", isOn: $settings.copyToClipboard)
                    Toggle("Save to the screenshots folder", isOn: $settings.autoSave)
                    SettingsPicker("Then", selection: $settings.afterCapture) {
                        ForEach(AfterCaptureAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    if settings.afterCapture == .showThumbnail {
                        SettingsPicker("Keep the thumbnail for", selection: $settings.thumbnailSeconds) {
                            ForEach([4.0, 6, 10, 30], id: \.self) { seconds in
                                Text("\(Int(seconds)) seconds").tag(seconds)
                            }
                        }
                    }
                    Toggle("Play the shutter sound", isOn: $settings.playSound)
                }
                SettingsGroup("History") {
                    Toggle("Keep recent captures", isOn: $settings.keepHistory)
                    SettingsPicker("Number of captures", selection: $settings.historyLimit) {
                        ForEach([10, 30, 50, 100], id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .disabled(!settings.keepHistory)
                    Button("Clear History") { HistoryStore.shared.clear() }
                }
            }
            .onChange(of: updater.driver.attentionRequest) { _, _ in
                scroll.scrollTo("app-updates", anchor: .top)
            }
        }
    }
}

struct CaptureSettingsPane: View {
    @Bindable private var settings = AppSettings.shared
    @State private var status = PermissionStatus()
    @State private var cameras: [(id: String, name: String)] = []

    var body: some View {
        SettingsPage {
            SettingsGroup("Screenshots") {
                Toggle("Include the mouse pointer", isOn: $settings.showCursor)
                Toggle("Include window shadows", isOn: $settings.windowShadow)
                Toggle("Show the magnifier while selecting", isOn: $settings.showMagnifier)
                SettingsPicker("Delayed capture", selection: $settings.delaySeconds) {
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                Toggle("Convert colors to sRGB", isOn: $settings.convertToSRGB)
                Text("Keeps hex values consistent across displays. Off keeps the display's own color profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsGroup("Screen recording") {
                Toggle("Show the pointer", isOn: $settings.recordPointer)
                Toggle("Highlight clicks", isOn: $settings.recordClicks)
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Toggle("Count down 3 seconds before recording", isOn: $settings.recordCountdown)
                Text("Each recording starts with system audio and the camera as set here and the microphone off, or on with Record Screen with Microphone; the buttons next to Record switch them for that recording. The \(Image(systemName: "ellipsis")) menu there changes the other settings here. Recordings are saved as MP4 next to your screenshots, copied to the clipboard and shown in Finder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsGroup("Camera") {
                Toggle("Start recordings with the camera on", isOn: $settings.recordCamera)
                SettingsPicker("Camera", selection: $settings.cameraDeviceID) {
                    Text("Same as macOS").tag(String?.none)
                    ForEach(cameras, id: \.id) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                    // A recording falls back to the camera macOS prefers until it comes back.
                    if let chosen = settings.cameraDeviceID, !cameras.contains(where: { $0.id == chosen }) {
                        Text("Disconnected Camera").tag(Optional(chosen))
                    }
                }
                Toggle("Mirror the camera", isOn: $settings.mirrorCamera)
                Text("The bubble sits in the recording area and the movie shows it. Drag it to move it; it stays in that corner for the next recording.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsGroup("Color picker") {
                SettingsPicker("Copy colors as", selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            }
            SettingsGroup("Scrolling capture") {
                SettingsPicker("Maximum height", selection: $settings.scrollMaxHeight) {
                    ForEach([10000, 20000, 50000, 100_000], id: \.self) { height in
                        Text("\(height.formatted()) px").tag(height)
                    }
                }
                LabeledContent("Auto-scroll speed") {
                    Slider(value: $settings.autoScrollSpeed, in: 0.5 ... 3)
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
        .onAppear {
            status.startPolling()
            cameras = CameraDevices.available().map { (id: $0.uniqueID, name: $0.localizedName) }
        }
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
        SettingsPage {
            SettingsGroup("Saving") {
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
                LabeledContent("File name") {
                    TextField("File name", text: $settings.fileNameTemplate)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }
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
                SettingsPicker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                if settings.imageFormat != .png {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $settings.jpegQuality, in: 0.4 ... 1)
                                .frame(width: 180)
                            Text("\(Int(settings.jpegQuality * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            SettingsGroup("Retina") {
                Toggle("Downscale Retina screenshots to 1x", isOn: $settings.downscaleRetina)
                Text("Copies and files get half the pixels, matching what you saw on screen in points.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
        SettingsPage {
            SettingsGroup("Global shortcuts") {
                ForEach(AppAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action, settings: settings)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
            Text("Shortcuts work in every app. Add Control to a capture shortcut, or hold Control as you finish a selection, to copy the screenshot without opening anything. macOS keeps ⇧⌘3, ⇧⌘4 and ⇧⌘5 unless you turn them off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SettingsGroup {
                Button("Restore Defaults") { settings.resetShortcuts() }
            }
        }
    }
}

struct EditorSettingsPane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        SettingsPage {
            SettingsGroup("Markup") {
                Toggle("Add soft shadows to new markup", isOn: $settings.annotationShadows)
                Button("Reset Tool Colors and Sizes") { settings.resetToolStyles() }
            }
            SettingsGroup("Tool keys") {
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
        SettingsPage {
            SettingsGroup {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cuadro")
                            .font(.system(size: 17, weight: .semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("A free, native screenshot tool for macOS.")
                Link("github.com/mrcat71/cuadro", destination: URL(string: "https://github.com/mrcat71/cuadro")!)
            }
            SettingsGroup("Permissions") {
                PermissionList(status: status, usesGlass: false)
            }
        }
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
    }
}
