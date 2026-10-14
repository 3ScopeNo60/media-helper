import Foundation
import CryptoKit

/// A dotted version such as "1.10.2". Compares numerically, so 1.10 > 1.9.
struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let parts: [Int]
    var description: String { parts.map(String.init).joined(separator: ".") }

    /// Accepts "1.2", "v1.2", or a tag that must start with `prefix` (for example "v").
    init?(_ raw: String, prefix: String = "") {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if prefix.isEmpty {
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        } else {
            guard s.hasPrefix(prefix) else { return nil }
            s.removeFirst(prefix.count)
        }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub release the updater needs (GitHub's REST "list releases" shape).
/// The repository is public, so assets are fetched from their plain download address.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let size: Int?
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, body, draft, prerelease, assets }
}

/// An update that can be installed: a newer version with its zip and signature.
struct UpdateOffer: Equatable, Sendable {
    let version: AppVersion
    let tag: String
    let notes: String
    let zip: GitHubRelease.Asset
    let signature: GitHubRelease.Asset
}

enum UpdateFeed {
    static let tagPrefix = "v"
    static let product = "MediaHelper"

    /// File names a release must carry for version `v`: `MediaHelper-1.2.zip` and `MediaHelper-1.2.zip.sig`.
    static func zipName(_ v: AppVersion, product: String = UpdateFeed.product) -> String { "\(product)-\(v).zip" }

    /// The newest release that is newer than `current` and complete (zip + signature).
    /// Drafts, pre-releases, other tags and incomplete releases are ignored.
    static func bestOffer(in releases: [GitHubRelease], current: AppVersion,
                          tagPrefix: String = UpdateFeed.tagPrefix, product: String = UpdateFeed.product) -> UpdateOffer? {
        releases.compactMap { r -> UpdateOffer? in
            guard !r.draft, !r.prerelease, let v = AppVersion(r.tagName, prefix: tagPrefix), v > current else { return nil }
            let name = zipName(v, product: product)
            guard let zip = r.assets.first(where: { $0.name == name }),
                  let sig = r.assets.first(where: { $0.name == name + ".sig" }) else { return nil }
            return UpdateOffer(version: v, tag: r.tagName, notes: r.body ?? "", zip: zip, signature: sig)
        }.max { $0.version < $1.version }
    }
}

/// Integrity and authenticity: a SHA-256 of the downloaded zip, signed with an
/// Ed25519 key whose private half never leaves the release machine. The app
/// carries only the public key, so a tampered or substituted download is refused
/// even if the place it was hosted is compromised.
enum UpdateVerifier {
    static func digest(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    /// `signatureBase64` signs the 32-byte digest; `publicKeyBase64` is the raw 32-byte key.
    static func isValid(signatureBase64: String, digest: Data, publicKeyBase64: String) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: digest)
    }

    /// For tests and the release tooling.
    static func sign(digest: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try privateKey.signature(for: digest).base64EncodedString()
    }
}
