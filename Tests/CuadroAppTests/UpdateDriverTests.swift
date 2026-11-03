import AppKit
@testable import Cuadro
import CuadroKit
import Sparkle
import Testing

@MainActor
@Suite(.serialized)
struct UpdateDriverTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func `cancellation is answered once`() {
        let driver = UpdateDriver()
        var calls = 0
        driver.showUserInitiatedUpdateCheck { calls += 1 }
        #expect(driver.phase == .checking)
        driver.cancel()
        driver.cancel()
        #expect(calls == 1)
        #expect(driver.phase == nil)
    }

    @Test func `cancelling download answers its own callback`() {
        let driver = UpdateDriver()
        var checkCalls = 0
        var downloadCalls = 0
        driver.showUserInitiatedUpdateCheck { checkCalls += 1 }
        driver.showDownloadInitiated { downloadCalls += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 30)
        driver.showDownloadDidReceiveData(ofLength: 20)
        #expect(driver.phase == .downloading(nil, received: 50, expected: 100))
        driver.cancel()
        #expect(checkCalls == 0)
        #expect(downloadCalls == 1)
    }

    @Test func `extraction cannot cancel A finished download`() {
        let driver = UpdateDriver()
        var calls = 0
        driver.showDownloadInitiated { calls += 1 }
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(2)
        #expect(driver.phase == .preparing(nil, progress: 1))
        driver.cancel()
        #expect(calls == 0)
    }

    @Test func `ready choice is answered once`() {
        let driver = UpdateDriver()
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady { choices.append($0) }
        #expect(driver.phase == .ready(nil))
        driver.answer(.install)
        driver.answer(.install)
        #expect(choices == [.install])
        #expect(driver.phase == .installing(nil, canRetry: false))
        driver.dismissUpdateInstallation()
    }

    @Test func `later defers ready update`() {
        let driver = UpdateDriver()
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady { choices.append($0) }
        driver.answer(.later)
        #expect(choices == [.dismiss])
        #expect(driver.phase == nil)
    }

    @Test func `retry acknowledges before checking again`() {
        let driver = UpdateDriver()
        var events: [String] = []
        driver.showUpdaterError(NSError(domain: "test", code: 1)) { events.append("acknowledge") }
        driver.checkAgain = { events.append("check") }
        driver.retry()
        driver.acknowledge()
        #expect(events == ["acknowledge", "check"])
        #expect(driver.phase == nil)
    }

    @Test func `unknown no update reason is not reported as up to date`() {
        let driver = UpdateDriver()
        var calls = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "test", code: 1)) { calls += 1 }
        guard case .unavailable = driver.phase else {
            Issue.record("Unknown update failures must not claim that Cuadro is current")
            return
        }
        driver.acknowledge()
        driver.acknowledge()
        #expect(calls == 1)
    }

    @Test func `dismissal clears all pending replies`() {
        let driver = UpdateDriver()
        var calls = 0
        driver.showReady { _ in calls += 1 }
        driver.showInstallingUpdate(withApplicationTerminated: false) { calls += 1 }
        driver.dismissUpdateInstallation()
        driver.answer(.install)
        driver.retryQuit()
        #expect(calls == 0)
        #expect(driver.phase == nil)
    }
}
