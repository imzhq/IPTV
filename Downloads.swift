import Foundation
import SwiftUI

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
        let p = d.appendingPathComponent("parts", isDirectory: true)
        try? fm.createDirectory(at: p, withIntermediateDirectories: true)
        dir = d
        partsDir = p
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

                // These were being assembled when the app closed, so they have to start again
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
                        do {
                            try self.checkSpace(needed: info.total)
                        } catch {
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
                    for part in parts { self.startPart(id, part.index, resumeData: nil) }
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
        for part in it.parts {
            if part.done {
                if part.start >= 0 { sum += part.end - part.start + 1 }
                else { sum += max(it.total, received[id]?[part.index] ?? 0) }
            } else {
                sum += received[id]?[part.index] ?? 0
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
            let finalError = failure
            DispatchQueue.main.async {
                self?.finishMerge(id, dest: dest, error: finalError, size: size)
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
        guard let parsed = parse(downloadTask.taskDescription) else { return }
        received[parsed.0, default: [:]][parsed.1] = totalBytesWritten
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.4 else { return }
        lastPublish = now
        refreshProgress(parsed.0)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns, so move it right away
        guard let parsed = parse(downloadTask.taskDescription) else { return }
        let id = parsed.0
        let idx = parsed.1
        guard let it = item(id), it.state == .downloading,
              let part = it.parts.first(where: { $0.index == idx }) else { return }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let ranged = part.start >= 0
        let statusOK = ranged ? status == 206 : (200...299).contains(status)
        if !statusOK {
            if ranged && status == 200 {
                fail(id, DLError.noRange.localizedDescription)
            } else {
                fail(id, DLError.http(status).localizedDescription)
            }
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
        mutate(id) { entry in
            if let pi = entry.parts.firstIndex(where: { $0.index == idx }) {
                entry.parts[pi].done = true
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
              let parsed = parse(task.taskDescription),
              let it = item(parsed.0), it.state == .downloading else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // we cancelled it ourselves
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        retryPart(parsed.0, parsed.1, resume: resume, reason: error.localizedDescription)
    }
}

// END OF FILE
