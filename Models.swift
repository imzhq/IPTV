import Foundation
import SwiftUI

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

// END OF FILE
