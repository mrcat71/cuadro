@testable import CuadroKit
import Testing

struct UpdateFlowTests {
    @Test(arguments: [UpdateOffer.Stage.notDownloaded, .downloaded, .installing])
    func `install follows the download stage`(_ stage: UpdateOffer.Stage) {
        var offer = UpdateOffer(version: "0.6", currentVersion: "0.5")
        offer.stage = stage
        let next = UpdateFlow.after(.install, in: .available(offer), offer: offer)
        switch stage {
        case .notDownloaded:
            #expect(next.phase == .downloading(offer, received: 0, expected: nil))
            #expect(!next.relaunchWhenReady)
        case .downloaded:
            #expect(next.phase == .preparing(offer, progress: nil))
            #expect(next.relaunchWhenReady)
        case .installing:
            #expect(next.phase == .installing(offer, canRetry: false))
            #expect(!next.relaunchWhenReady)
        }
    }

    @Test(arguments: [UpdateChoice.later, .skip])
    func `deferral never relaunches`(_ choice: UpdateChoice) {
        let offer = UpdateOffer(version: "0.6", currentVersion: "0.5")
        let next = UpdateFlow.after(choice, in: .ready(offer), offer: offer)
        #expect(next.phase == nil)
        #expect(!next.relaunchWhenReady)
    }

    @Test func `ready install does not restart the download`() {
        let offer = UpdateOffer(version: "0.6", currentVersion: "0.5")
        let next = UpdateFlow.after(.install, in: .ready(offer), offer: offer)
        #expect(next.phase == .installing(offer, canRetry: false))
    }

    @Test func `progress handles missing and inaccurate lengths`() {
        #expect(UpdateFlow.downloadFraction(received: 1, expected: nil) == nil)
        #expect(UpdateFlow.downloadFraction(received: 1, expected: 0) == nil)
        #expect(UpdateFlow.downloadFraction(received: 0, expected: 10) == 0)
        #expect(UpdateFlow.downloadFraction(received: 5, expected: 10) == 0.5)
        #expect(UpdateFlow.downloadFraction(received: 20, expected: 10) == 1)
        #expect(UpdateFlow.downloadFraction(received: .max, expected: .max) == 1)
    }

    @Test func `critical and installing updates cannot be skipped`() {
        var offer = UpdateOffer(version: "0.6", currentVersion: "0.5")
        #expect(UpdateFlow.canSkip(offer))
        offer.isCritical = true
        #expect(!UpdateFlow.canSkip(offer))
        offer.isCritical = false
        offer.stage = .downloaded
        #expect(UpdateFlow.canSkip(offer))
        offer.stage = .installing
        #expect(!UpdateFlow.canSkip(offer))
    }
}
