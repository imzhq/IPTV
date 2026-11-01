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

func symbolName(for kind: ContentKind) -> String {
    switch kind {
    case .live: return "play.fill"
    case .movies: return "film"
    case .series: return "tv"
    }
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

// MARK: - Root View (kept as LiveCategoriesView so LeanIPTVApp.swift still works)

struct LiveCategoriesView: View {
    @StateObject private var model = IPTVViewModel()

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

// MARK: - Home (Live TV / Movies / Series + search)

struct HomeView: View {
    @ObservedObject var model: IPTVViewModel
    @State private var kind: ContentKind = .live
    @State private var query = ""
    @AppStorage("data_saver") private var dataSaver = true

    private var cats: [IPTVCategory] { model.categories[kind] ?? [] }
    private var cleanQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Section", selection: $kind) {
                ForEach(ContentKind.allCases) { k in
                    Text(k.rawValue).tag(k)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)

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
        .task(id: kind) {
            if model.categories[kind] == nil {
                await model.loadCategories(kind)
            }
        }
        .onChange(of: kind) { _ in
            query = ""
        }
        .onChange(of: query) { _ in
            if !cleanQuery.isEmpty {
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
                        NavigationLink(destination: ItemDestination(model: model, kind: kind, item: item)) {
                            MediaRow(name: item.name,
                                     icon: item.icon,
                                     symbol: symbolName(for: kind),
                                     showIcon: kind == .live || !dataSaver)
                        }
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
                            NavigationLink(destination: ItemDestination(model: model, kind: kind, item: item)) {
                                MediaRow(name: item.name,
                                         icon: item.icon,
                                         symbol: symbolName(for: kind),
                                         showIcon: kind == .live || !dataSaver)
                            }
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

    @State private var episodes: [Episode] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("EPISODES (\(episodes.count))")
                        .font(.subheadline).foregroundColor(.gray)
                    if loading { ProgressView().scaleEffect(0.8) }
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
                            NavigationLink(destination: PlayerView(title: ep.title,
                                                                   url: model.episodeURL(ep),
                                                                   mode: .vod)) {
                                MediaRow(name: "S\(ep.season) E\(ep.number) · \(ep.title)",
                                         icon: nil,
                                         symbol: "play.fill",
                                         showIcon: false)
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
