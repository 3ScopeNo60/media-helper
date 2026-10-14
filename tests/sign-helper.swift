// Throwaway-key helper for the update tests. Keeps keys in files, never in the Keychain.
//   sign-helper gen <keyfile>             writes a new private key (base64) to <keyfile>, prints the public key
//   sign-helper sign <keyfile> <file>     prints the signature of <file>'s SHA-256, same format as release-tool
import Foundation
import CryptoKit

let a = Array(CommandLine.arguments.dropFirst())
func digest(_ path: String) -> Data {
    let h = FileHandle(forReadingAtPath: path)!; var s = SHA256()
    while let c = try? h.read(upToCount: 1 << 20), !c.isEmpty { s.update(data: c) }
    return Data(s.finalize())
}
switch a.first {
case "gen":
    let k = Curve25519.Signing.PrivateKey()
    try! Data(k.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: a[1]))
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let raw = Data(base64Encoded: try! String(contentsOfFile: a[1], encoding: .utf8))!
    let k = try! Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    print(try! k.signature(for: digest(a[2])).base64EncodedString())
default: print("usage: gen <keyfile> | sign <keyfile> <file>"); exit(1)
}
