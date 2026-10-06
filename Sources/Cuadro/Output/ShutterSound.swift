import AppKit

/// The system screenshot sound.
enum ShutterSound {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    static func play() {
        guard AppSettings.shared.playSound, let sound else { return }
        sound.stop()
        sound.play()
    }
}
