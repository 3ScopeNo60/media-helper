// Prints the CGWindowID of the first on-screen window owned by the named app: window-id "Media Helper"
import Foundation
import CoreGraphics
let name = CommandLine.arguments.dropFirst().first ?? "Media Helper"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
exit(1)
