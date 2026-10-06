# Cuadro

Free, native screenshot tool for macOS 26 and later, with Shottr's feature set and a Liquid Glass interface. It lives in the menu bar, has no account, no upload and no paywall, and keeps everything on your Mac.

## Features

- **Capture:** area (frozen screen with magnifier and pixel grid), window (with or without shadow, transparent corners), active window, full screen, repeat last area, delayed (3, 5 or 10 s), scrolling capture with live stitching and optional auto-scroll, pin an area directly to the screen.
- **Screen tools:** color picker (HEX, RGB, HSL or OKLCH, plus WCAG contrast against a reference color), screen ruler that snaps to edges, text recognition (OCR) with QR and barcode reading.
- **Editor:** arrow (straight, curved, double), line, rectangle, ellipse, pen, highlighter, text (plain, outlined, label), step counter, pixelate, blur, smart erase, spotlight, magnifier, measurement, crop with aspect presets and auto-trim, pasted image overlays, backdrop (gradient, solid or transparent, padding, corners, shadow, aspect ratio), resize, undo and redo.
- **Output:** clipboard, quick save with file name templates, Save As (PNG, JPEG, HEIC), drag and drop, share sheet, print, open in Preview, pin as a floating window, optional 1x downscale for Retina captures, recent captures history.

## Requirements

- macOS 26 or later.
- Xcode with Swift 6.2 or later (developed with Xcode 27 and Swift 6.4).
- An "Apple Development" signing identity is recommended (see [Signing](#signing)).

## Build and run

```sh
make app        # release build, assembles and signs build/Cuadro.app
make run        # make app, quit a running copy, open the new one
make install    # copy to ~/Applications/Cuadro.app
make test       # unit tests (Swift Testing)
make dist       # zip, dmg and SHA256SUMS of build/Cuadro.app in build/dist
make clean      # remove .build and build
```

Install to `~/Applications` before turning on **Launch at login**: the login item points at the app's current location.

### Signing

`make app` signs with the first "Apple Development" identity in your keychain, so the code signature stays stable across rebuilds and the Screen Recording permission survives them. Without one it falls back to ad-hoc signing, and macOS asks for the permission again after every rebuild. Override with `make app SIGN_IDENTITY=-` (ad-hoc) or any identity hash from `security find-identity -v -p codesigning`.

## Permissions

| Permission | Needed for | Where |
| --- | --- | --- |
| Screen Recording | Every capture | System Settings > Privacy & Security > Screen & System Audio Recording |
| Accessibility | Auto-scroll in scrolling capture only | System Settings > Privacy & Security > Accessibility |

On first launch Cuadro opens a welcome window with buttons for both. After switching Screen Recording on, click **Relaunch Cuadro**: macOS applies the grant only to a new process.

## Shortcuts

Global shortcuts work in every app and are set in **Settings > Shortcuts**. Defaults match Shottr: ⇧⌘1 full screen, ⇧⌘2 area. Every other action starts unassigned and is available from the menu bar icon. macOS keeps ⇧⌘3, ⇧⌘4 and ⇧⌘5 unless you turn them off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.

**While selecting an area:** drag to select; hold Space to move the selection; Shift for a square; Option to draw from the center; click without dragging to take the window under the pointer; Space (not dragging) switches to window mode; Return takes the whole display; Tab copies the color under the pointer; arrows nudge the pointer by 1 pt (Shift: 10 pt); Esc or right-click cancels.

**Color picker:** click copies the color in the format chosen in Settings; Shift-click sets a reference color and the loupe then shows the contrast ratio.

**Screen ruler:** hover to see the distances between edges; drag to measure a box; click or ⌘C copies the measurement; scroll changes edge sensitivity; ↑ or ↓ locks to vertical, ← or → to horizontal; Esc closes.

**Editor tools:** V select, A arrow, L line, R rectangle, O ellipse, P pen, H highlighter, T text, N step counter, B pixelate/blur, E smart erase, S spotlight, M magnifier, U ruler, I color picker, C crop.

| Editor action | Keys |
| --- | --- |
| Copy image, save, Save As, print | ⌘C, ⌘S, ⇧⌘S, ⌘P |
| Undo, redo | ⌘Z, ⇧⌘Z |
| Recognize text, pin, backdrop, resize | ⇧⌘T, ⇧⌘P, ⇧⌘B, ⌥⌘R |
| Zoom in, out, actual size, fit | ⌘=, ⌘-, ⌘0, ⌘9, or ⌘-scroll and pinch |
| Pan | Hold Space and drag |
| Paste an image as an overlay | ⌘V |
| Open a file, open the clipboard image | ⇧⌘O, ⇧⌘V |
| Delete, duplicate, nudge selected markup | Delete, ⌘D, arrows (Shift: 10 pt) |
| Edit text, finish editing | Double-click or Return, then Esc or ⌘Return |
| Spotlight darkness | 1 to 9 with the spotlight tool or a spotlight selected |
| Apply or cancel crop | Return, Esc |
| Stamp the ruler's hover measurement | Option-click with the ruler tool |

## Settings and files

- Screenshots folder: `~/Pictures/Screenshots` by default; file names come from a template such as `Screenshot {date} at {time}` (tokens are listed in Settings > Output).
- Recent captures: `~/Library/Application Support/Cuadro/History` (30 by default, configurable or off in Settings > General).
- Preferences: the `io.github.mrcat71.cuadro` defaults domain.

## Architecture

| Target | Path | Role |
| --- | --- | --- |
| `CuadroKit` | `Sources/CuadroKit` | Pure logic with no AppKit: geometry, annotation model and hit testing, `DocumentRenderer` (CoreGraphics, CoreText, CoreImage), `ScrollStitcher`, edge finder, color formats, file name templates, key combos, OCR text assembly. Fully unit-tested. |
| `Cuadro` | `Sources/Cuadro` | The app: AppKit lifecycle with SwiftUI views and `defaultIsolation(MainActor)`. |
| `cuadro-icon` | `Sources/cuadro-icon` | Draws the app icon PNG set; `make` turns it into `AppIcon.icns`. |
| `CuadroKitTests` | `Tests/CuadroKitTests` | Table-driven Swift Testing suites. |

Inside the app:

- `Capture/`: `ScreenCaptureService` (ScreenCaptureKit display and window screenshots), `CaptureCoordinator` (every mode and the post-capture pipeline), `Overlay/` (frozen-screen selection, picker and ruler), `Scrolling/` (SCStream plus stitching off the main actor).
- `Editor/`: `EditorModel` (document state as a value, undo snapshots), `Canvas/` (NSScrollView canvas drawing through `DocumentRenderer`, so the canvas and the export match), `Chrome/` (floating Liquid Glass palettes).
- `Hotkeys/` (Carbon `RegisterEventHotKey`, no Accessibility needed), `Permissions/`, `Output/`, `Pin/`, `QuickAccess/`, `OCR/` (Vision), `Settings/`, `HUD/`.

## Releases

Pushing a version tag runs [`release.yml`](.github/workflows/release.yml): tests, release build, smoke test, then a GitHub Release with `cuadro-<version>-macos-arm64.zip`, a `.dmg` and `SHA256SUMS`, with notes generated from the commits.

```sh
git tag -a v0.1.0 -m "Cuadro 0.1.0"
git push origin v0.1.0
```

Tags must look like `v1.2.3`, or `v1.2.3-beta.1` for a pre-release. Running the workflow by hand (Actions > release > Run workflow) builds the same files without publishing and attaches them to the run. `make app dist VERSION=1.2.3` produces them locally in `build/dist`.

The job runs on GitHub's hosted `xcode-27` macOS image because the self-hosted runners are Linux only. While the repository is private, those macOS minutes count against the account's Actions quota.

Signing depends on which repository secrets exist:

| Secrets | Result |
| --- | --- |
| None | Ad-hoc signed. macOS blocks the first launch of a downloaded copy; allow it in System Settings > Privacy & Security > Open Anyway. Screen Recording must be granted again after every update. |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` with your Apple Development certificate | Stable signature, so the Screen Recording grant survives updates on your Macs. Other Macs still need Open Anyway. |
| The two above with a Developer ID Application certificate, plus `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific password) | Notarized and stapled; opens normally on any Mac. Needs a paid Apple Developer Program membership. |

To add a certificate, export it from Keychain Access (My Certificates, right-click the certificate, Export, `.p12` with a password), then:

```sh
base64 -i Cuadro.p12 | gh secret set MACOS_CERTIFICATE_P12 --repo mrcat71/cuadro
gh secret set MACOS_CERTIFICATE_PASSWORD --repo mrcat71/cuadro
```

Renovate keeps the pinned action SHAs current (`.github/renovate.json`); it runs from the self-hosted Renovate CE in `okira-infra`, whose repository allowlist must include `mrcat71/cuadro`.

## Development checks

```sh
swift build                 # debug build, should report no warnings
swift test                  # CuadroKit unit tests
make app && codesign --verify --deep --strict build/Cuadro.app
```

Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "io.github.mrcat71.cuadro"'`. Use the full path in zsh, where `log` is a shell builtin.

UI self-check: `build/Cuadro.app/Contents/MacOS/Cuadro --ui-snapshot /tmp/cuadro-ui` opens the editor, settings, onboarding, a pin, a toast, a thumbnail and the selection overlay with a synthetic screenshot, writes a PNG per window and quits. With Screen Recording allowed it captures the real windows; without it, it renders the layer trees in-process, where Liquid Glass surfaces appear flat.

## Manual test checklist

Run these after changes to capture or the editor; they need a real screen and input.

- [ ] ⇧⌘2: drag an area, the editor opens and the image is on the clipboard; Esc cancels and focus returns to the previous app.
- [ ] Area mode: Space toggles window mode; clicking a window captures it with a shadow and transparent corners.
- [ ] ⇧⌘1 captures the display under the pointer; Repeat Last Area reproduces the previous rectangle.
- [ ] Multiple displays (and a non-Retina display if available): overlay on every screen, correct crop and scale.
- [ ] Delayed capture of an open menu.
- [ ] Scrolling capture on a long web page, with manual scrolling and with Auto-Scroll; sticky headers appear once.
- [ ] Recognize Text on a paragraph and on a QR code; Pick Color with a contrast reference; Measure Screen.
- [ ] Every editor tool: draw, select, move, resize, change style, undo and redo; text editing; crop with auto-trim; backdrop.
- [ ] Copy, save, Save As in each format, drag out to Finder, share, pin, print.
- [ ] Settings: record and clear a shortcut, hide the menu bar icon and reopen the app, Launch at login from `~/Applications`.

## Not included

Cloud or S3 upload, before and after GIFs, hand-drawn style, APCA contrast, text-only blur, and horizontal scrolling capture. Scrolling capture follows downward scrolling only, and an area selection stays on one display.

## License

Apache License 2.0, see [LICENSE](LICENSE).
