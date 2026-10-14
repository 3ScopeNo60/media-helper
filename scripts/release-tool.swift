// Release signing tool for Media Helper updates.
//
//   release-tool generate        make the signing key pair (private key -> macOS Keychain)
//   release-tool public          print the public key (base64) to build into the app
//   release-tool sign <file>     print the signature (base64) for a release file
//   release-tool verify <file> <sig-file>
//   release-tool export          print the private key (base64), for backing it up. Treat as a password.
//
// Environment: RELEASE_TOOL_SERVICE picks a different Keychain entry (used by tests, so a
// throwaway key can never touch the real one).
import Foundation
import CryptoKit
import Security

let service = ProcessInfo.processInfo.environment["RELEASE_TOOL_SERVICE"] ?? "Media Helper update signing key"
let account = "ed25519-private-key"

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
          let raw = Data(base64Encoded: data) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func saveKey(_ key: Curve25519.Signing.PrivateKey) {
    let value = Data(key.rawRepresentation.base64EncodedString().utf8)
    let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: value,
                                kSecAttrLabel as String: service]
    let status = SecItemAdd(attrs as CFDictionary, nil)
    if status != errSecSuccess { fail("Couldn't save the key to the Keychain (error \(status)).") }
}

func digest(of path: String) -> Data {
    guard let h = FileHandle(forReadingAtPath: path) else { fail("Can't read \(path)") }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    if loadKey() != nil { fail("A signing key already exists. Replacing it would stop every installed copy from accepting updates.") }
    let key = Curve25519.Signing.PrivateKey()
    saveKey(key)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = loadKey() else { fail("No signing key yet. Run: release-tool generate") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: release-tool sign <file>") }
    guard let key = loadKey() else { fail("No signing key yet. Run: release-tool generate") }
    print(try! key.signature(for: digest(of: args[1])).base64EncodedString())
case "verify":
    guard args.count == 3, let key = loadKey(),
          let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("usage: release-tool verify <file> <sig-file>") }
    if key.publicKey.isValidSignature(sig, for: digest(of: args[1])) { print("OK") } else { fail("BAD SIGNATURE") }
case "export":
    guard let key = loadKey() else { fail("No signing key yet.") }
    print(key.rawRepresentation.base64EncodedString())
default:
    fail("usage: release-tool generate | public | sign <file> | verify <file> <sig-file> | export")
}
