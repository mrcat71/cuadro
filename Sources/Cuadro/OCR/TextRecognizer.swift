import CoreGraphics
import CuadroKit
import Vision

/// On-device text and barcode recognition with Vision.
enum TextRecognizer {
    struct Result: Sendable {
        var text: String
        var barcodes: [String]

        var isEmpty: Bool { text.isEmpty && barcodes.isEmpty }
    }

    nonisolated static func recognize(_ image: CGImage) async throws -> Result {
        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let observations = try await textRequest.perform(on: image)
        let size = CGSize(width: image.width, height: image.height)
        let fragments = observations.compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            return TextFragment(text: candidate.string, box: box)
        }

        var barcodes: [String] = []
        do {
            let barcodeRequest = DetectBarcodesRequest()
            barcodes = try await barcodeRequest.perform(on: image).compactMap(\.payloadString)
        } catch {
            Log.capture.error("Barcode detection failed: \(error.localizedDescription, privacy: .public)")
        }
        return Result(text: TextAssembler.assemble(fragments), barcodes: barcodes)
    }
}
