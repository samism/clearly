import Foundation
import WebKit

public enum LocalImageSupport {
    public static let scheme = "clearly-file"

    public static func fileURLKeyFragment(_ fileURL: URL?) -> String {
        fileURL?.path ?? ""
    }

    private static let imgSrcRegex = try? NSRegularExpression(
        pattern: #"(<img\s[^>]*?src\s*=\s*")([^"]+)("[^>]*?>)"#,
        options: .caseInsensitive
    )

    public static func resolveImageSources(in html: String, relativeTo documentURL: URL?) -> String {
        guard html.range(of: "<img", options: .caseInsensitive) != nil,
              let regex = imgSrcRegex else { return html }

        let ns = html as NSString
        var result = ""
        result.reserveCapacity(html.utf8.count)
        var cursor = 0
        var rewroteAny = false

        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 4 else { return }
            let src = ns.substring(with: match.range(at: 2))
            guard let absolutePath = absolutePath(for: src, relativeTo: documentURL) else { return }

            let encoded = absolutePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? absolutePath
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += ns.substring(with: match.range(at: 1))
            result += "\(scheme)://localhost\(encoded)"
            result += ns.substring(with: match.range(at: 3))
            cursor = match.range.location + match.range.length
            rewroteAny = true
        }

        guard rewroteAny else { return html }
        result += ns.substring(from: cursor)
        return result
    }

    private static func absolutePath(for source: String, relativeTo documentURL: URL?) -> String? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") ||
           source.hasPrefix("data:") || source.hasPrefix("\(scheme)://") {
            return nil
        }

        var filePath = source
        if filePath.hasPrefix("file://") {
            filePath = String(filePath.dropFirst("file://".count))
        }
        filePath = filePath.removingPercentEncoding ?? filePath

        if filePath.hasPrefix("/") {
            return filePath
        }

        guard let documentDirectory = documentURL?.deletingLastPathComponent() else {
            return nil
        }

        return documentDirectory.appendingPathComponent(filePath).path
    }
}

/// Byte cache for local preview images, keyed by path and validated by
/// modification date. Live mode reloads the whole page on every block
/// commit, re-requesting every image — without this, editing an image-heavy
/// note re-reads megabytes from disk per commit. Thread-safe (the scheme
/// handler reads on a concurrent queue).
final class LocalImageCache {
    static let shared = LocalImageCache()

    private struct Entry {
        let data: Data
        let mtime: Date
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var tick: UInt64 = 0
    private let maxBytes: Int
    /// One image never gets to monopolize the cache.
    private var maxEntryBytes: Int { maxBytes / 4 }

    init(maxBytes: Int = 64_000_000) {
        self.maxBytes = maxBytes
    }

    func data(forPath path: String, mtime: Date) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.mtime == mtime else { return nil }
        tick &+= 1
        entries[path]?.lastAccess = tick
        return entry.data
    }

    func store(_ data: Data, forPath path: String, mtime: Date) {
        guard data.count <= maxEntryBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[path] {
            totalBytes -= old.data.count
        }
        tick &+= 1
        entries[path] = Entry(data: data, mtime: mtime, lastAccess: tick)
        totalBytes += data.count
        // LRU eviction; the linear min-scan is fine at tens of entries.
        while totalBytes > maxBytes,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            totalBytes -= oldest.value.data.count
            entries.removeValue(forKey: oldest.key)
        }
    }

    var currentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }
}

public final class LocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "tiff": "image/tiff", "tif": "image/tiff", "bmp": "image/bmp",
        "heic": "image/heic"
    ]

    /// Concurrent I/O queue shared by all handler instances. WebKit invokes
    /// `start` on the main thread; reading multi-MB images there (up to the
    /// 20MB per-image cap) froze the preview while pages loaded.
    private static let ioQueue = DispatchQueue(
        label: "com.sabotage.clearly.local-image-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Tasks WebKit hasn't cancelled. Calling any method on a task after
    /// `stop` raises an Objective-C exception, so every async reply must
    /// re-check membership on the main thread first. Main-thread confined.
    private var liveTasks = Set<ObjectIdentifier>()

    public override init() {
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let path = url.path.removingPercentEncoding ?? url.path
        guard !path.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        liveTasks.insert(taskID)

        let fileURL = URL(fileURLWithPath: path)
        Self.ioQueue.async { [weak self] in
            let withinLimit = Limits.isFileSize(fileURL, atMost: Limits.maxLocalImageSize)
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            var data: Data?
            if withinLimit {
                if let mtime, let cached = LocalImageCache.shared.data(forPath: path, mtime: mtime) {
                    data = cached
                } else {
                    data = try? Data(contentsOf: fileURL)
                    if let data, let mtime {
                        LocalImageCache.shared.store(data, forPath: path, mtime: mtime)
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self, self.liveTasks.remove(taskID) != nil else { return }

                guard withinLimit else {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 413,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/plain"]
                    )!
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didFinish()
                    return
                }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }

                let ext = (path as NSString).pathExtension.lowercased()
                let mime = Self.mimeTypes[ext] ?? "application/octet-stream"
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }
}
