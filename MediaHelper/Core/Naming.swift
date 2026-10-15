import Foundation

enum Naming {
    /// Turns a video title into something safe to use as a file name.
    /// `/` and `\` become `-`, `:` becomes ` -`, characters macOS and Windows dislike
    /// (`* ? " < > |`) and control characters are dropped, spaces are tidied, leading
    /// dots (which would hide the file) and trailing dots/spaces are removed, and the
    /// result is kept short enough for any file system.
    static func sanitize(_ title: String, fallback: String = "Download", maxCharacters: Int = 120, maxBytes: Int = 180) -> String {
        var out = ""
        for ch in title {
            switch ch {
            case "/", "\\": out.append("-")
            case ":": out.append(" -")
            case "*", "?", "\"", "<", ">", "|": continue
            case "\n", "\r", "\t": out.append(" ")
            default:
                if ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { continue }
                out.append(ch)
            }
        }
        var s = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = trimEnds(s)
        while s.count > maxCharacters || s.utf8.count > maxBytes { s.removeLast() }
        s = trimEnds(s)
        return s.isEmpty ? fallback : s
    }

    private static func trimEnds(_ s: String) -> String {
        var t = Substring(s)
        while t.first == " " { t = t.dropFirst() }
        while let l = t.last, l == " " || l == "." { t = t.dropLast() }
        return String(t)
    }

    /// `folder/name.ext`, or `name 2.ext`, `name 3.ext` … so nothing is ever overwritten.
    static func uniqueURL(in folder: URL, baseName: String, ext: String, fileManager: FileManager = .default) -> URL {
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? baseName : "\(baseName) \(n)"
            return folder.appendingPathComponent(name + "." + ext)
        }
        var n = 1
        while fileManager.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    /// `folder/name`, or `name 2`, `name 3` … for a new folder that must not clash with anything.
    static func uniqueFolderURL(in folder: URL, baseName: String, fileManager: FileManager = .default) -> URL {
        var n = 1
        func candidate(_ n: Int) -> URL { folder.appendingPathComponent(n == 1 ? baseName : "\(baseName) \(n)", isDirectory: true) }
        while fileManager.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }
}
