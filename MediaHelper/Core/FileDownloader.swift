import Foundation
import CryptoKit

/// Downloads one file with progress. Also used for the app's own updates.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL?, Error>?
    private var destination: URL!
    private var movedError: Error?

    private init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    /// Downloads `url` to `destination` (replacing anything there). Returns the final
    /// address after any redirects.
    @discardableResult
    static func download(_ url: URL, to destination: URL,
                         onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL? {
        let d = FileDownloader(onProgress: onProgress)
        d.destination = destination
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 20 * 60
        let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL?, Error>) in
            d.continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    /// A small text file (a checksum list, say).
    static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HelperError.message("The download site answered with an error (\(http.statusCode)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { onProgress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            movedError = HelperError.message("The download failed (\(http.statusCode)).")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { movedError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation; continuation = nil
        if let error = error ?? movedError { c?.resume(throwing: error) } else { c?.resume(returning: task.response?.url) }
    }
}

enum Checksum {
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Finds `name`'s hash in a `shasum`-style list ("<hash>  <name>"), or the only hash in a one-line file.
    static func expectedHash(in text: String, forFile name: String? = nil) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func hash(_ line: String) -> String? {
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, first.count == 64,
                  first.allSatisfy({ $0.isHexDigit }) else { return nil }
            return first.lowercased()
        }
        if let name {
            for line in lines {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.count >= 2, parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name, let h = hash(line) { return h }
            }
            return nil
        }
        return lines.count == 1 ? hash(lines[0]) : lines.compactMap(hash).first
    }
}
