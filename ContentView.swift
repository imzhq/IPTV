import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

// MARK: - Models

enum ContentKind: String, CaseIterable, Identifiable {
    case live = "Live TV"
    case movies = "Movies"
    case series = "Series"
    var id: String { rawValue }
}

enum HomeTab: String, CaseIterable, Identifiable {
    case live = "Live TV"
    case movies = "Movies"
    case series = "Series"
    case downloads = "Downloads"
    var id: String { rawValue }

    var kind: ContentKind? {
        switch self {
        case .live: return .live
        case .movies: return .movies
        case .series: return .series
        case .downloads: return nil
        }
    }
}

func symbolName(for kind: ContentKind) -> String {
    switch kind {
    case .live: return "play.fill"
    case .movies: return "film"
    case .series: return "tv"
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

struct IPTVCategory: Decodable, Identifiable {
    var id: String { categoryId }
    let categoryId: String
    let categoryName: String

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .categoryId) {
            categoryId = s
        } else {
            categoryId = String(try c.decode(Int.self, forKey: .categoryId))
        }
        categoryName = (try? c.decode(String.self, forKey: .categoryName)) ?? "Unnamed"
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// One item type for live channels, movies and series (they use slightly different field names)
struct MediaItem: Decodable, Identifiable {
    let id: Int
    let name: String
    let searchKey: String
    let icon: String?
    let ext: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            return nil
        }
        id = Int(str("stream_id") ?? str("series_id") ?? "") ?? 0
        let n = str("name") ?? "Unknown"
        name = n
        searchKey = n.lowercased()
        let ic = str("stream_icon") ?? str("cover")
        icon = (ic?.isEmpty ?? true) ? nil : ic
        ext = str("container_extension") ?? "mp4"
    }
}

struct Episode: Identifiable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let ext: String
}

private func intFrom(_ any: Any?, default def: Int) -> Int {
    if let i = any as? Int { return i }
    if let s = any as? String, let i = Int(s) { return i }
    if let d = any as? Double { return Int(d) }
    return def
}

// MARK: - ViewModel

@MainActor
class IPTVViewModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "iptv_host") ?? ""
    @Published var username: String = UserDefaults.standard.string(forKey: "iptv_user") ?? ""
    @Published var password: String = UserDefaults.standard.string(forKey: "iptv_pass") ?? ""

    @Published var categories: [ContentKind: [IPTVCategory]] = [:]
    @Published var items: [MediaItem] = []
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    // Whole-catalog cache used by the search box
    @Published var library: [ContentKind: [MediaItem]] = [:]
    @Published var libraryLoading: Set<ContentKind> = []
    @Published var libraryError: String? = nil

    private var baseURL: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    private var u: String { username.trimmingCharacters(in: .whitespaces) }
    private var p: String { password.trimmingCharacters(in: .whitespaces) }

    private func makeURL(action: String? = nil, extra: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: baseURL + "/player_api.php") else { return nil }
        var q = [
            URLQueryItem(name: "username", value: u),
            URLQueryItem(name: "password", value: p)
        ]
        if let action = action { q.append(URLQueryItem(name: "action", value: action)) }
        comps.queryItems = q + extra
        return comps.url
    }

    private func fetch(_ url: URL, timeout: TimeInterval = 25) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("❌ HTTP status: \(http.statusCode)")
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func actions(for kind: ContentKind) -> (cats: String, items: String) {
        switch kind {
        case .live:   return ("get_live_categories", "get_live_streams")
        case .movies: return ("get_vod_categories", "get_vod_streams")
        case .series: return ("get_series_categories", "get_series")
        }
    }

    func login() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = makeURL() else {
            errorMessage = "Invalid server URL"
            return
        }
        do {
            let data = try await fetch(url)
            print("LOGIN RESPONSE: \(String(data: data, encoding: .utf8) ?? "")")

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let info = json?["user_info"] as? [String: Any]
            let auth = "\(info?["auth"] ?? 0)"

            if auth == "1" {
                UserDefaults.standard.set(host, forKey: "iptv_host")
                UserDefaults.standard.set(username, forKey: "iptv_user")
                UserDefaults.standard.set(password, forKey: "iptv_pass")
                await loadCategories(.live)
                if errorMessage == nil { isLoggedIn = true }
            } else {
                errorMessage = "Login failed. Check the URL, username and password."
            }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
            print("❌ Login error: \(error)")
        }
    }

    func loadCategories(_ kind: ContentKind) async {
        guard let url = makeURL(action: actions(for: kind).cats) else { return }
        errorMessage = nil
        do {
            let data = try await fetch(url)
            categories[kind] = try JSONDecoder().decode([IPTVCategory].self, from: data)
        } catch {
            errorMessage = "Categories failed: \(error.localizedDescription)"
            print("❌ Categories error: \(error)")
        }
    }

    func loadItems(_ kind: ContentKind, category: IPTVCategory) async {
        isLoading = true
        errorMessage = nil
        items = []
        defer { isLoading = false }

        let extra = [URLQueryItem(name: "category_id", value: category.categoryId)]
        guard let url = makeURL(action: actions(for: kind).items, extra: extra) else { return }
        do {
            let data = try await fetch(url)
            items = try JSONDecoder().decode([MediaItem].self, from: data)
        } catch {
            errorMessage = "Loading failed: \(error.localizedDescription)"
            print("❌ Items error: \(error)")
        }
    }

    // Downloads the full list for a section once (no category filter) so it can be searched instantly
    func loadLibrary(_ kind: ContentKind) async {
        guard library[kind] == nil, !libraryLoading.contains(kind),
              let url = makeURL(action: actions(for: kind).items) else { return }
        libraryLoading.insert(kind)
        libraryError = nil
        defer { libraryLoading.remove(kind) }
        do {
            let data = try await fetch(url, timeout: 90)
            // Decode off the main thread so the app doesn't freeze on big catalogs
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode([MediaItem].self, from: data)
            }.value
            library[kind] = decoded
            print("✅ Search catalog for \(kind.rawValue): \(decoded.count) items")
        } catch {
            libraryError = "Could not load the search list: \(error.localizedDescription)"
            print("❌ Library error: \(error)")
        }
    }

    func loadEpisodes(for series: MediaItem) async -> [Episode] {
        let extra = [URLQueryItem(name: "series_id", value: String(series.id))]
        guard let url = makeURL(action: "get_series_info", extra: extra) else { return [] }
        do {
            let data = try await fetch(url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            var result: [Episode] = []

            func add(_ raw: Any, seasonHint: Int) {
                guard let d = raw as? [String: Any] else { return }
                let id: String
                if let s = d["id"] as? String { id = s }
                else if let i = d["id"] as? Int { id = String(i) }
                else { return }
                let number = intFrom(d["episode_num"], default: 0)
                let season = intFrom(d["season"], default: seasonHint)
                let title = (d["title"] as? String) ?? "Episode \(number)"
                let ext = (d["container_extension"] as? String) ?? "mp4"
                result.append(Episode(id: id, season: season, number: number, title: title, ext: ext))
            }

            if let dict = root["episodes"] as? [String: Any] {
                for (seasonKey, value) in dict {
                    for e in (value as? [Any]) ?? [] { add(e, seasonHint: Int(seasonKey) ?? 0) }
                }
            } else if let arr = root["episodes"] as? [Any] {
                for (i, value) in arr.enumerated() {
                    if let inner = value as? [Any] {
                        for e in inner { add(e, seasonHint: i + 1) }
                    } else {
                        add(value, seasonHint: 0)
                    }
                }
            }
            return result.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        } catch {
            errorMessage = "Episodes failed: \(error.localizedDescription)"
            return []
        }
    }

    // Raw .ts feed for live (lowest delay). If a channel is black, try ".m3u8" instead of ".ts".
    func liveURL(_ item: MediaItem) -> URL? {
        URL(string: "\(baseURL)/live/\(u)/\(p)/\(item.id).ts")
    }

    func movieURL(_ item: MediaItem) -> URL? {
        URL(string: "\(baseURL)/movie/\(u)/\(p)/\(item.id).\(item.ext)")
    }

    func episodeURL(_ ep: Episode) -> URL? {
        URL(string: "\(baseURL)/series/\(u)/\(p)/\(ep.id).\(ep.ext)")
    }

    func logout() {
        isLoggedIn = false
        categories = [:]
        items = []
        library = [:]
    }
}

// MARK: - Download engine

enum DLError: LocalizedError {
    case http(Int)
    case noRange
    case incomplete
    case noSpace
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "The server refused the download (HTTP \(code)). Try fewer connections."
        case .noRange:
            return "The server doesn't allow split downloads. Set connections to 1."
        case .incomplete:
            return "The file came out incomplete. Tap retry."
        case .noSpace:
            return "Not enough free storage on this phone."
        case .cannotWrite:
            return "Could not write the file."
        }
    }
}

// Asks the server for 1 byte to learn the file size and whether it supports split (range) downloads
private func probeDownload(_ url: URL) async throws -> (total: Int64, rangeOK: Bool) {
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    bytes.task.cancel()   // we only wanted the headers
    guard let http = response as? HTTPURLResponse else { throw DLError.http(0) }

    switch http.statusCode {
    case 206:
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/") {
            let tail = String(cr[cr.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
            if let total = Int64(tail) { return (total, true) }
        }
        return (0, false)
    case 200...299:
        return (max(http.expectedContentLength, 0), false)
    default:
        throw DLError.http(http.statusCode)
    }
}

enum DLState: String, Codable {
    case queued, downloading, finishing, completed, failed
}

struct DownloadPart: Codable {
    var index: Int
    var start: Int64     // -1 means the whole file is fetched in one request
    var end: Int64
    var done: Bool
}

struct DownloadItem: Identifiable, Codable {
    var id: String
    var title: String
    var remote: String
    var fileName: String
    var total: Int64
    var done: Int64
    var state: DLState
    var error: String?
    var added: Date
    var parts: [DownloadPart]
}

// Uses a background URLSession, so transfers continue while the phone is locked or the app is in the background.
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var speeds: [String: Double] = [:]

    private let dir: URL
    private let partsDir: URL
    private var session: URLSession!

    private var received: [String: [Int: Int64]] = [:]      // item id -> part index -> bytes so far
    private var attempts: [String: Int] = [:]               // "id|part" -> number of tries
    private var lastSample: [String: (time: Date, bytes: Int64)] = [:]
    private var starting: Set<String> = []
    private var lastPublish = Date.distantPast

    private var indexFile: URL { dir.appendingPathComponent("index.json") }

    private override init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        dir = d
        partsDir = d.appendingPathComponent("parts", isDirectory: true)
        try? fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
        super.init()

        if let data = try? Data(contentsOf: indexFile),
           let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = decoded
        }

        let cfg = URLSessionConfiguration.background(withIdentifier: "com.lean.iptv.downloads")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue.main)

        reconcile()
    }

    // MARK: Lookups

    func item(_ id: String) -> DownloadItem? {
        items.first { $0.id == id }
    }

    func item(forRemote remote: String) -> DownloadItem? {
        items.first { $0.remote == remote }
    }

    func localURL(for item: DownloadItem) -> URL? {
        guard item.state == .completed else { return nil }
        let u = dir.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var usedBytes: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + $1.total }
    }

    // MARK: Actions

    func add(title: String, remote: URL, ext: String) {
        if let existing = item(forRemote: remote.absoluteString) {
            if existing.state == .failed { retry(existing.id) }
            return
        }
        let id = UUID().uuidString
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let fileExt = cleaned.isEmpty ? "mp4" : String(cleaned.prefix(5))
        items.append(DownloadItem(id: id,
                                  title: title,
                                  remote: remote.absoluteString,
                                  fileName: "\(id).\(fileExt)",
                                  total: 0,
                                  done: 0,
                                  state: .queued,
                                  error: nil,
                                  added: Date(),
                                  parts: []))
        save()
        startNext()
    }

    func retry(_ id: String) {
        mutate(id) {
            $0.state = .queued
            $0.error = nil
            $0.done = 0
            $0.parts = []
        }
        save()
        startNext()
    }

    func remove(_ id: String) {
        cancelTasks(id)
        removeParts(id)
        starting.remove(id)
        if let it = item(id) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(it.fileName))
        }
        items.removeAll { $0.id == id }
        received[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        save()
        startNext()
    }

    // MARK: Engine

    private func mutate(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func partURL(_ id: String, _ index: Int) -> URL {
        partsDir.appendingPathComponent("\(id)-\(index).part")
    }

    private func parse(_ description: String?) -> (String, Int)? {
        guard let description = description else { return nil }
        let bits = description.split(separator: "|")
        guard bits.count == 2, let idx = Int(bits[1]) else { return nil }
        return (String(bits[0]), idx)
    }

    private func removeParts(_ id: String) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: partsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(id + "-") {
            try? fm.removeItem(at: f)
        }
    }

    private func cancelTasks(_ id: String) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription?.hasPrefix(id + "|") == true {
                t.cancel()
            }
        }
    }

    // After the app starts again, pick up anything that was in progress
    private func reconcile() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let known = Set(tasks.compactMap { $0.taskDescription })

                // These were being assembled when the app closed, so start them again
                for i in self.items.indices where self.items[i].state == .finishing {
                    let id = self.items[i].id
                    try? FileManager.default.removeItem(at: self.dir.appendingPathComponent(self.items[i].fileName))
                    self.removeParts(id)
                    self.items[i].state = .failed
                    self.items[i].error = "Interrupted while finishing. Tap retry."
                    self.items[i].parts = []
                }

                let snapshot = self.items
                for it in snapshot where it.state == .downloading {
                    if it.parts.isEmpty {
                        self.mutate(it.id) { $0.state = .queued }
                        continue
                    }
                    if it.parts.allSatisfy({ $0.done }) {
                        self.merge(it.id)
                        continue
                    }
                    for part in it.parts where !part.done {
                        if !known.contains("\(it.id)|\(part.index)") {
                            self.startPart(it.id, part.index, resumeData: nil)
                        }
                    }
                }
                self.save()
                self.startNext()
            }
        }
    }

    private func startNext() {
        guard starting.isEmpty,
              !items.contains(where: { $0.state == .downloading || $0.state == .finishing }) else { return }
        guard let next = items.first(where: { $0.state == .queued }) else { return }
        begin(next.id)
    }

    private func begin(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              let url = URL(string: items[i].remote) else {
            fail(id, "Bad download link")
            return
        }
        items[i].state = .downloading
        items[i].error = nil
        items[i].done = 0
        items[i].parts = []
        starting.insert(id)
        received[id] = [:]
        lastSample[id] = nil
        save()

        let stored = UserDefaults.standard.integer(forKey: "dl_connections")
        let connections = max(1, min(8, stored == 0 ? 4 : stored))

        Task {
            do {
                let info = try await probeDownload(url)
                await MainActor.run {
                    self.starting.remove(id)
                    guard let it = self.item(id), it.state == .downloading else {
                        self.startNext()
                        return
                    }
                    if info.total > 0 {
                        do { try self.checkSpace(needed: info.total) }
                        catch {
                            self.fail(id, error.localizedDescription)
                            return
                        }
                    }

                    // Split into parts of at least 4 MB, up to the chosen number of connections
                    var count = 1
                    if info.rangeOK && info.total > 0 {
                        count = max(1, min(connections, Int(info.total / (4 * 1024 * 1024))))
                    }
                    var parts: [DownloadPart] = []
                    if count == 1 {
                        parts = [DownloadPart(index: 0, start: -1, end: -1, done: false)]
                    } else {
                        let chunk = info.total / Int64(count)
                        for n in 0..<count {
                            let start = Int64(n) * chunk
                            let end = (n == count - 1) ? info.total - 1 : start + chunk - 1
                            parts.append(DownloadPart(index: n, start: start, end: end, done: false))
                        }
                    }
                    self.mutate(id) {
                        $0.total = info.total
                        $0.parts = parts
                    }
                    self.save()
                    for p in parts { self.startPart(id, p.index, resumeData: nil) }
                }
            } catch {
                await MainActor.run {
                    self.starting.remove(id)
                    self.fail(id, error.localizedDescription)
                }
            }
        }
    }

    private func checkSpace(needed: Int64) throws {
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage,
           free < needed + needed / 10 + 300_000_000 {
            throw DLError.noSpace
        }
    }

    private func startPart(_ id: String, _ index: Int, resumeData: Data?) {
        guard let it = item(id),
              let url = URL(string: it.remote),
              let part = it.parts.first(where: { $0.index == index }),
              !part.done else { return }

        let task: URLSessionDownloadTask
        if let data = resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            received[id, default: [:]][index] = 0
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            req.allowsCellularAccess = !UserDefaults.standard.bool(forKey: "dl_wifi_only")
            if part.start >= 0 {
                req.setValue("bytes=\(part.start)-\(part.end)", forHTTPHeaderField: "Range")
            }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = "\(id)|\(index)"
        task.resume()
    }

    private func retryPart(_ id: String, _ index: Int, resume: Data?, reason: String) {
        let key = "\(id)|\(index)"
        let n = (attempts[key] ?? 0) + 1
        attempts[key] = n
        if n > 4 {
            fail(id, reason)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self,
                  let it = self.item(id), it.state == .downloading,
                  let part = it.parts.first(where: { $0.index == index }), !part.done else { return }
            self.startPart(id, index, resumeData: resume)
        }
    }

    private func refreshProgress(_ id: String) {
        guard let it = item(id), it.state == .downloading else { return }
        var sum: Int64 = 0
        for p in it.parts {
            if p.done {
                if p.start >= 0 { sum += p.end - p.start + 1 }
                else { sum += max(it.total, received[id]?[p.index] ?? 0) }
            } else {
                sum += received[id]?[p.index] ?? 0
            }
        }
        mutate(id) { $0.done = sum }

        let now = Date()
        if let last = lastSample[id] {
            let dt = now.timeIntervalSince(last.time)
            if dt >= 1 {
                speeds[id] = max(0, Double(sum - last.bytes) / dt)
                lastSample[id] = (now, sum)
            }
        } else {
            lastSample[id] = (now, sum)
        }
    }

    // Joins the parts into the final file, one part at a time so the extra storage stays small
    private func merge(_ id: String) {
        guard let it = item(id) else { return }
        mutate(id) { $0.state = .finishing }
        save()

        let dest = dir.appendingPathComponent(it.fileName)
        let partFiles = it.parts.sorted { $0.index < $1.index }.map { partURL(id, $0.index) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var failure: Error?

            _ = try? fm.removeItem(at: dest)
            if partFiles.count == 1 {
                do { try fm.moveItem(at: partFiles[0], to: dest) }
                catch { failure = error }
            } else {
                do {
                    guard fm.createFile(atPath: dest.path, contents: nil) else { throw DLError.cannotWrite }
                    let out = try FileHandle(forWritingTo: dest)
                    defer { try? out.close() }
                    for pf in partFiles {
                        let src = try FileHandle(forReadingFrom: pf)
                        var finished = false
                        while !finished {
                            autoreleasepool {
                                let chunk = src.readData(ofLength: 8 * 1024 * 1024)
                                if chunk.isEmpty { finished = true } else { out.write(chunk) }
                            }
                        }
                        try? src.close()
                        _ = try? fm.removeItem(at: pf)
                    }
                } catch {
                    failure = error
                }
            }

            let attrs = try? fm.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            DispatchQueue.main.async {
                self?.finishMerge(id, dest: dest, error: failure, size: size)
            }
        }
    }

    private func finishMerge(_ id: String, dest: URL, error: Error?, size: Int64) {
        guard let it = item(id) else {
            try? FileManager.default.removeItem(at: dest)   // it was removed while finishing
            return
        }
        if let error = error {
            fail(id, error.localizedDescription)
            return
        }
        if it.total > 0 && size != it.total {
            fail(id, DLError.incomplete.localizedDescription)
            return
        }
        mutate(id) {
            $0.state = .completed
            $0.total = size
            $0.done = size
            $0.error = nil
            $0.parts = []
        }
        received[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        save()
        startNext()
    }

    private func fail(_ id: String, _ message: String) {
        cancelTasks(id)
        removeParts(id)
        starting.remove(id)
        received[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        if let it = item(id) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(it.fileName))
        }
        mutate(id) {
            $0.state = .failed
            $0.error = message
            $0.parts = []
            $0.done = 0
        }
        save()
        startNext()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    // MARK: URLSessionDownloadDelegate (all of these run on the main queue)

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let (id, idx) = parse(downloadTask.taskDescription) else { return }
        received[id, default: [:]][idx] = totalBytesWritten
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.4 else { return }
        lastPublish = now
        refreshProgress(id)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns, so move it right away
        guard let (id, idx) = parse(downloadTask.taskDescription),
              let it = item(id), it.state == .downloading,
              let part = it.parts.first(where: { $0.index == idx }) else { return }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let ranged = part.start >= 0
        let statusOK = ranged ? status == 206 : (200...299).contains(status)
        if !statusOK {
            if ranged && status == 200 { fail(id, DLError.noRange.localizedDescription) }
            else { fail(id, DLError.http(status).localizedDescription) }
            return
        }

        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: location.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if ranged && size != part.end - part.start + 1 {
            retryPart(id, idx, resume: nil, reason: DLError.incomplete.localizedDescription)
            return
        }

        let target = partURL(id, idx)
        _ = try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: location, to: target)
        } catch {
            fail(id, DLError.cannotWrite.localizedDescription)
            return
        }

        received[id, default: [:]][idx] = size
        mutate(id) { item in
            if let pi = item.parts.firstIndex(where: { $0.index == idx }) {
                item.parts[pi].done = true
            }
        }
        save()
        refreshProgress(id)

        if let updated = item(id), updated.parts.allSatisfy({ $0.done }) {
            merge(id)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let (id, idx) = parse(task.taskDescription),
              let it = item(id), it.state == .downloading else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // we cancelled it ourselves
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        retryPart(id, idx, resume: resume, reason: error.localizedDescription)
    }
}

// MARK: - Root View (kept as LiveCategoriesView so LeanIPTVApp.swift still works)

struct LiveCategoriesView: View {
    @StateObject private var model = IPTVViewModel()

    init() {
        _ = DownloadManager.shared   // start the download engine at launch so it can pick up unfinished downloads
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if model.isLoggedIn {
                    HomeView(model: model)
                } else {
                    LoginView(model: model)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var model: IPTVViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lean IPTV")
                .font(.largeTitle).fontWeight(.bold)
                .foregroundColor(.white)

            field(title: "URL TO XTREAM SERVER") {
                TextField("http://example.com:8080", text: $model.host)
                    .keyboardType(.URL)
            }
            field(title: "YOUR USERNAME") {
                TextField("username", text: $model.username)
            }
            field(title: "YOUR PASSWORD") {
                SecureField("password", text: $model.password)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button(action: { Task { await model.login() } }) {
                HStack {
                    if model.isLoading { ProgressView().padding(.trailing, 6) }
                    Text("Log in").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.red.opacity(0.85))
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(model.isLoading || model.host.isEmpty || model.username.isEmpty || model.password.isEmpty)

            Spacer()
        }
        .padding()
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.gray)
            content()
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Home (Live TV / Movies / Series / Downloads + search)

struct HomeView: View {
    @ObservedObject var model: IPTVViewModel
    @State private var tab: HomeTab = .live
    @State private var query = ""
    @AppStorage("data_saver") private var dataSaver = true

    private var kind: ContentKind { tab.kind ?? .live }
    private var cats: [IPTVCategory] { model.categories[kind] ?? [] }
    private var cleanQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Section", selection: $tab) {
                ForEach(HomeTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)

            if tab == .downloads {
                DownloadsView()
            } else {
                searchField

                if kind != .live {
                    Toggle(isOn: $dataSaver) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Data saver").foregroundColor(.white)
                            Text("Hides 4K/UHD, no poster images, small buffer")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .red))
                    .padding(.horizontal)
                }

                if cleanQuery.isEmpty {
                    categoryList
                } else {
                    SearchResultsView(model: model, kind: kind, query: cleanQuery)
                }
            }
        }
        .task(id: tab) {
            if let k = tab.kind, model.categories[k] == nil {
                await model.loadCategories(k)
            }
        }
        .onChange(of: tab) { _ in
            query = ""
        }
        .onChange(of: query) { _ in
            if tab != .downloads && !cleanQuery.isEmpty {
                Task { await model.loadLibrary(kind) }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Lean IPTV")
                .font(.largeTitle).fontWeight(.bold)
                .foregroundColor(.white)
            Spacer()
            Button("Log out") { model.logout() }
                .foregroundColor(.red)
        }
        .padding(.horizontal)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.gray)
            TextField("Search all \(kind.rawValue.lowercased())", text: $query)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.white)
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(kind.rawValue.uppercased()) CATEGORIES (\(cats.count))")
                .font(.subheadline)
                .foregroundColor(.gray)
                .padding(.horizontal)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(cats) { category in
                        NavigationLink(destination: ItemListView(model: model, kind: kind, category: category)) {
                            HStack {
                                Text(category.categoryName)
                                    .foregroundColor(.white)
                                    .font(.headline)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray)
                            }
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Search results (whole catalog)

struct SearchResultsView: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let query: String

    @AppStorage("data_saver") private var dataSaver = true

    private let maxResults = 300

    // Every word you type must appear in the title, in any order
    private var matches: [MediaItem] {
        guard let all = model.library[kind] else { return [] }
        let words = query.lowercased().split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return [] }
        return all.filter { item in
            if kind != .live && dataSaver {
                let n = item.searchKey
                if n.contains("4k") || n.contains("uhd") || n.contains("2160") { return false }
            }
            return words.allSatisfy { item.searchKey.contains($0) }
        }
    }

    var body: some View {
        let found = matches
        let shown = Array(found.prefix(maxResults))

        VStack(alignment: .leading, spacing: 10) {
            if model.libraryLoading.contains(kind) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading the full list (first search only)...")
                        .font(.caption).foregroundColor(.gray)
                }
                .padding(.horizontal)
            } else if let error = model.libraryError, model.library[kind] == nil {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            } else {
                Text(found.count > maxResults
                     ? "\(found.count) RESULTS · showing the first \(maxResults), keep typing to narrow"
                     : "\(found.count) RESULTS")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(shown) { item in
                        ItemRowLink(model: model,
                                    kind: kind,
                                    item: item,
                                    showIcon: kind == .live || !dataSaver)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Shared pieces

struct ItemDestination: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let item: MediaItem

    var body: some View {
        switch kind {
        case .live:
            PlayerView(title: item.name, url: model.liveURL(item), mode: .live)
        case .movies:
            PlayerView(title: item.name, url: model.movieURL(item), mode: .vod)
        case .series:
            EpisodeListView(model: model, series: item)
        }
    }
}

struct MediaRow: View {
    let name: String
    let icon: String?
    let symbol: String
    let showIcon: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showIcon, let icon = icon, let iconURL = URL(string: icon) {
                AsyncImage(url: iconURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 40, height: 40)
            }
            Text(name)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: symbol).foregroundColor(.gray)
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
    }
}

// A list row with the play link, plus a download arrow for movies
struct ItemRowLink: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let item: MediaItem
    let showIcon: Bool

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink(destination: ItemDestination(model: model, kind: kind, item: item)) {
                MediaRow(name: item.name,
                         icon: item.icon,
                         symbol: symbolName(for: kind),
                         showIcon: showIcon)
            }
            if kind == .movies {
                DownloadButton(title: item.name,
                               url: model.movieURL(item),
                               ext: item.ext)
            }
        }
    }
}

struct DownloadButton: View {
    let title: String
    let url: URL?
    let ext: String
    @ObservedObject private var downloads = DownloadManager.shared

    private func iconName(_ state: DLState?) -> String {
        switch state {
        case .none: return "arrow.down.circle"
        case .some(.queued): return "clock"
        case .some(.downloading), .some(.finishing): return "arrow.down.circle.fill"
        case .some(.completed): return "checkmark.circle.fill"
        case .some(.failed): return "arrow.clockwise.circle"
        }
    }

    var body: some View {
        let existing = url.flatMap { downloads.item(forRemote: $0.absoluteString) }
        Button(action: {
            guard let url = url else { return }
            downloads.add(title: title, remote: url, ext: ext)
        }) {
            Image(systemName: iconName(existing?.state))
                .font(.title2)
                .foregroundColor(existing?.state == .completed ? .green : .red)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Item list (one category)

struct ItemListView: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let category: IPTVCategory

    @AppStorage("data_saver") private var dataSaver = true
    @State private var query = ""

    private var shown: [MediaItem] {
        model.items.filter { item in
            let n = item.name.uppercased()
            if kind != .live && dataSaver && (n.contains("4K") || n.contains("UHD") || n.contains("2160")) {
                return false
            }
            return query.isEmpty || n.contains(query.uppercased())
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(shown.count) ITEMS")
                        .font(.subheadline).foregroundColor(.gray)
                    if model.isLoading { ProgressView().scaleEffect(0.8) }
                }
                .padding(.horizontal)

                TextField("Search this category", text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in
                            ItemRowLink(model: model,
                                        kind: kind,
                                        item: item,
                                        showIcon: kind == .live || !dataSaver)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationBarTitle(category.categoryName, displayMode: .inline)
        .navigationBarHidden(false)
        .task { await model.loadItems(kind, category: category) }
    }
}

// MARK: - Episodes

struct EpisodeListView: View {
    @ObservedObject var model: IPTVViewModel
    let series: MediaItem

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var episodes: [Episode] = []
    @State private var loading = true

    private func downloadTitle(_ ep: Episode) -> String {
        "\(series.name) · S\(ep.season)E\(ep.number) \(ep.title)"
    }

    private func downloadAll() {
        for ep in episodes {
            if let url = model.episodeURL(ep) {
                downloads.add(title: downloadTitle(ep), remote: url, ext: ep.ext)
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("EPISODES (\(episodes.count))")
                        .font(.subheadline).foregroundColor(.gray)
                    if loading { ProgressView().scaleEffect(0.8) }
                    Spacer()
                    if !episodes.isEmpty {
                        Button(action: downloadAll) {
                            Label("Download all", systemImage: "arrow.down.circle")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)

                if !loading && episodes.isEmpty {
                    Text("No episodes found").font(.caption).foregroundColor(.gray).padding(.horizontal)
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(episodes) { ep in
                            HStack(spacing: 8) {
                                NavigationLink(destination: PlayerView(title: ep.title,
                                                                       url: model.episodeURL(ep),
                                                                       mode: .vod)) {
                                    MediaRow(name: "S\(ep.season) E\(ep.number) · \(ep.title)",
                                             icon: nil,
                                             symbol: "play.fill",
                                             showIcon: false)
                                }
                                DownloadButton(title: downloadTitle(ep),
                                               url: model.episodeURL(ep),
                                               ext: ep.ext)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationBarTitle(series.name, displayMode: .inline)
        .navigationBarHidden(false)
        .task {
            loading = true
            episodes = await model.loadEpisodes(for: series)
            loading = false
        }
    }
}

// MARK: - Downloads tab

struct DownloadsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("dl_connections") private var connections = 4
    @AppStorage("dl_wifi_only") private var wifiOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $connections, in: 1...8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connections per download: \(connections)")
                        .foregroundColor(.white)
                    Text("More = faster, but some providers refuse extra connections. Lower it if downloads fail.")
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .padding(.horizontal)

            Toggle(isOn: $wifiOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi only").foregroundColor(.white)
                    Text("Off = downloads also use mobile data")
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .red))
            .padding(.horizontal)

            Text("Downloads keep going with the phone locked. Swiping the app away stops them. Stored: \(formatBytes(downloads.usedBytes))")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal)

            if downloads.items.isEmpty {
                Text("Nothing downloaded yet. Tap the arrow next to a movie or episode.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(downloads.items.reversed()) { item in
                        DownloadRow(item: item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject private var downloads = DownloadManager.shared

    private var progressText: String {
        var s = formatBytes(item.done)
        if item.total > 0 { s += " of " + formatBytes(item.total) }
        if let speed = downloads.speeds[item.id] { s += "  ·  " + formatBytes(Int64(speed)) + "/s" }
        return s
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            switch item.state {
            case .queued:
                Text("Waiting…").font(.caption).foregroundColor(.gray)
            case .downloading:
                if item.total > 0 {
                    ProgressView(value: Double(min(item.done, item.total)), total: Double(item.total))
                        .progressViewStyle(LinearProgressViewStyle(tint: .red))
                } else {
                    ProgressView()
                }
                Text(progressText).font(.caption).foregroundColor(.gray)
            case .finishing:
                Text("Finishing up…").font(.caption).foregroundColor(.gray)
            case .completed:
                Text(formatBytes(item.total) + " · tap to play")
                    .font(.caption).foregroundColor(.gray)
            case .failed:
                Text(item.error ?? "Failed")
                    .font(.caption).foregroundColor(.red)
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if item.state == .completed, let local = downloads.localURL(for: item) {
                NavigationLink(destination: PlayerView(title: item.title, url: local, mode: .vod)) {
                    HStack {
                        info
                        Spacer()
                        Image(systemName: "play.fill").foregroundColor(.gray)
                    }
                }
            } else {
                info
                Spacer()
            }

            if item.state == .failed {
                Button(action: { downloads.retry(item.id) }) {
                    Image(systemName: "arrow.clockwise").foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Button(action: { downloads.remove(item.id) }) {
                Image(systemName: "trash").foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
    }
}

// MARK: - VLC player

enum PlaybackMode { case live, vod }

final class VLCController: ObservableObject {
    let player = VLCMediaPlayer()

    func start(url: URL, options: [String]) {
        player.stop()
        let media = VLCMedia(url: url)
        for o in options { media.addOption(o) }
        player.media = media
        player.play()
    }

    func stop() {
        player.stop()
    }
}

struct VLCSurface: UIViewRepresentable {
    let controller: VLCController
    let onReady: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.player.drawable = view
        DispatchQueue.main.async { onReady() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerView: View {
    let title: String
    let url: URL?
    let mode: PlaybackMode

    // Saved settings
    @AppStorage("live_caching") private var liveCaching = 1500   // ms of buffer for live TV
    @AppStorage("data_saver") private var dataSaver = true

    @StateObject private var controller = VLCController()
    @State private var connecting = true
    @State private var showControls = true
    @State private var progress: Double = 0
    @State private var scrubbing = false
    @State private var playing = true
    @State private var elapsed = "0:00"
    @State private var total = "0:00"

    private let steps = [300, 500, 800, 1200, 1500, 2000, 3000, 5000]
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if url != nil {
                VLCSurface(controller: controller, onReady: { startPlayback() })
                    .ignoresSafeArea(edges: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showControls.toggle() } }
            } else {
                Text("Could not build stream URL").foregroundColor(.red)
            }

            if connecting && url != nil {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(1.2)
                    Text("Connecting...")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }

            if showControls && url != nil {
                VStack {
                    Spacer()
                    controlsPanel
                }
            }
        }
        .navigationBarTitle(title, displayMode: .inline)
        .navigationBarHidden(false)
        .onAppear {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Audio session error: \(error)")
            }
            UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on while watching
        }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(poll) { _ in tick() }
    }

    // MARK: Playback

    private func startPlayback() {
        guard let url = url else { return }
        connecting = true
        var opts: [String]
        switch mode {
        case .live:
            opts = [":network-caching=\(liveCaching)",
                    ":live-caching=\(liveCaching)",
                    ":clock-jitter=0",
                    ":clock-synchro=0"]
        case .vod:
            let cache = dataSaver ? 1500 : 4000
            opts = [":network-caching=\(cache)"]
            if dataSaver {
                // Only affects providers that serve adaptive (HLS/DASH) movies
                opts += [":adaptive-maxheight=720", ":adaptive-maxwidth=1280"]
            }
        }
        controller.start(url: url, options: opts)
    }

    private func changeBuffer(by direction: Int) {
        let idx = steps.firstIndex(where: { $0 >= liveCaching }) ?? (steps.count - 1)
        let newIdx = min(max(idx + direction, 0), steps.count - 1)
        liveCaching = steps[newIdx]
        startPlayback()
    }

    private func tick() {
        let p = controller.player
        playing = p.isPlaying
        if p.isPlaying { connecting = false }
        if mode == .vod && !scrubbing {
            progress = Double(p.position)
            elapsed = clock(Int(p.time.intValue))
            total = clock(Int(p.media?.length.intValue ?? 0))
        }
    }

    private func seek(by seconds: Double) {
        let p = controller.player
        let lengthMs = Double(p.media?.length.intValue ?? 0)
        guard lengthMs > 0 else { return }
        let newPos = Double(p.position) + (seconds * 1000) / lengthMs
        p.position = Float(min(max(newPos, 0), 0.999))
    }

    private func clock(_ ms: Int) -> String {
        let s = max(ms, 0) / 1000
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: Controls

    @ViewBuilder
    private var controlsPanel: some View {
        switch mode {
        case .live: liveControls
        case .vod: vodControls
        }
    }

    private var liveControls: some View {
        VStack(spacing: 8) {
            Text("Live buffer: " + String(format: "%.1f", Double(liveCaching) / 1000) + " s")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white)
            HStack(spacing: 12) {
                Button(action: { changeBuffer(by: -1) }) {
                    Label("Lower delay", systemImage: "minus.circle")
                }
                Button(action: { changeBuffer(by: 1) }) {
                    Label("More stable", systemImage: "plus.circle")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.white)
            Text("Lower = closer to live. Raise it if the picture lags.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.65))
    }

    private var vodControls: some View {
        VStack(spacing: 6) {
            Slider(value: $progress, in: 0...1, onEditingChanged: { editing in
                scrubbing = editing
                if !editing { controller.player.position = Float(progress) }
            })
            HStack {
                Text(elapsed).font(.caption2).foregroundColor(.white)
                Spacer()
                Text(total).font(.caption2).foregroundColor(.white)
            }
            HStack(spacing: 30) {
                Button(action: { seek(by: -30) }) {
                    Image(systemName: "gobackward.30").font(.title2)
                }
                Button(action: {
                    if controller.player.isPlaying { controller.player.pause() }
                    else { controller.player.play() }
                }) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title)
                }
                Button(action: { seek(by: 30) }) {
                    Image(systemName: "goforward.30").font(.title2)
                }
            }
            .foregroundColor(.white)
        }
        .padding(12)
        .background(Color.black.opacity(0.65))
    }
}
