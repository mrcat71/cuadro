// Checks a Sparkle feed before it is published. Its newest item must offer exactly this archive,
// carry the app's version, and be signed by the key that matches the app's SUPublicEDKey;
// otherwise every installed copy rejects the update. `make appcast` runs it.
//
// Usage: swift Scripts/check-appcast.swift <appcast.xml> <archive.zip> <Info.plist>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-appcast: \(message)\n".utf8))
    exit(1)
}

func read(_ url: URL) -> Data {
    do {
        return try Data(contentsOf: url)
    } catch {
        fail("cannot read \(url.path): \(error.localizedDescription)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { fail("usage: check-appcast <appcast.xml> <archive> <Info.plist>") }
let feedURL = URL(fileURLWithPath: arguments[0])
let archiveURL = URL(fileURLWithPath: arguments[1])
let plistURL = URL(fileURLWithPath: arguments[2])

let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let feed: XMLDocument
do {
    feed = try XMLDocument(data: read(feedURL))
} catch {
    fail("\(feedURL.path) is not XML: \(error.localizedDescription)")
}
guard let item = (try? feed.nodes(forXPath: "/rss/channel/item"))?.first as? XMLElement,
      let enclosure = item.elements(forName: "enclosure").first
else { fail("\(feedURL.path) has no item with an enclosure") }

guard let plist = (try? PropertyListSerialization.propertyList(from: read(plistURL), format: nil)) as? [String: Any],
      let publicKeyText = plist["SUPublicEDKey"] as? String,
      let build = plist["CFBundleVersion"] as? String,
      let version = plist["CFBundleShortVersionString"] as? String
else { fail("\(plistURL.path) lacks SUPublicEDKey, CFBundleVersion or CFBundleShortVersionString") }

let archive = read(archiveURL)
let url = enclosure.attribute(forName: "url")?.stringValue ?? ""
guard URL(string: url)?.lastPathComponent == archiveURL.lastPathComponent else {
    fail("enclosure url \(url) does not point at \(archiveURL.lastPathComponent)")
}
guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count) else {
    fail("enclosure length does not match the archive's \(archive.count) bytes")
}
let feedBuild = item.elements(forLocalName: "version", uri: sparkle).first?.stringValue
guard feedBuild == build else { fail("sparkle:version \(feedBuild ?? "missing") is not the app's CFBundleVersion \(build)") }
let feedVersion = item.elements(forLocalName: "shortVersionString", uri: sparkle).first?.stringValue
guard feedVersion == version else {
    fail("sparkle:shortVersionString \(feedVersion ?? "missing") is not the app's \(version)")
}

guard let signatureText = enclosure.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue,
      let signature = Data(base64Encoded: signatureText)
else { fail("enclosure has no sparkle:edSignature") }
guard let keyData = Data(base64Encoded: publicKeyText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("SUPublicEDKey is not a base64 Ed25519 public key") }
guard publicKey.isValidSignature(signature, for: archive) else {
    fail("the signature does not match SUPublicEDKey: the signing key (SPARKLE_PRIVATE_KEY) is not the app's key")
}
print("check-appcast: \(archiveURL.lastPathComponent) is \(version) (\(build)), signed for the app's key")
