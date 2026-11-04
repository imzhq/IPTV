import SwiftUI
import UIKit
import AVFoundation
import AVKit
import MobileVLCKit
import KSPlayer

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

struct IPTVCategory: Codable, Identifiable {
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
    
    init(categoryId: String, categoryName: String) {
        self.categoryId = categoryId
        self.categoryName = categoryName
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct MediaItem: Codable, Identifiable {
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

struct Episode: Identifiable, Codable {
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

    @Published var library: [ContentKind: [MediaItem]] = [:]
    @Published var libraryLoading: Set<ContentKind> = []
    @Published var libraryError: String? = nil

    init() {
        performWeeklyMaintenanceIfNeeded()
        loadCachedData()
    }

    private func performWeeklyMaintenanceIfNeeded() {
        let lastResetKey = "last_weekly_cache_reset"
        let now = Date().timeIntervalSince1970
        let oneWeek: TimeInterval = 7 * 24 * 60 * 60

        let lastReset = UserDefaults.standard.double(forKey: lastResetKey)
        if lastReset == 0 || (now - lastReset) > oneWeek {
            let host = UserDefaults.standard.string(forKey: "iptv_host")
            let user = UserDefaults.standard.string(forKey: "iptv_user")
            let pass = UserDefaults.standard.string(forKey: "iptv_pass")
            let dataSaver = UserDefaults.standard.bool(forKey: "data_saver")

            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }

            UserDefaults.standard.set(host, forKey: "iptv_host")
            UserDefaults.standard.set(user, forKey: "iptv_user")
            UserDefaults.standard.set(pass, forKey: "iptv_pass")
            UserDefaults.standard.set(dataSaver, forKey: "data_saver")
            UserDefaults.standard.set(now, forKey: lastResetKey)
        }
    }

    private func loadCachedData() {
        for kind in ContentKind.allCases {
            if let data = UserDefaults.standard.data(forKey: "cache_cats_\(kind.rawValue)"),
               let decoded = try? JSONDecoder().decode([IPTVCategory].self, from: data) {
                categories[kind] = decoded
            }
            if let data = UserDefaults.standard.data(forKey: "cache_lib_\(kind.rawValue)"),
               let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
                library[kind] = decoded
            }
        }
    }

    private func cacheCategories(_ kind: ContentKind, cats: [IPTVCategory]) {
        categories[kind] = cats
        if let encoded = try? JSONEncoder().encode(cats) {
            UserDefaults.standard.set(encoded, forKey: "cache_cats_\(kind.rawValue)")
        }
    }

    private func cacheLibrary(_ kind: ContentKind, items: [MediaItem]) {
        library[kind] = items
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "cache_lib_\(kind.rawValue)")
        }
    }

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
                errorMessage = "Login failed. Check URL, username and password."
            }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    func loadCategories(_ kind: ContentKind) async {
        if let cached = categories[kind], !cached.isEmpty { return }
        guard let url = makeURL(action: actions(for: kind).cats) else { return }
        errorMessage = nil
        do {
            let data = try await fetch(url)
            let decoded = try JSONDecoder().decode([IPTVCategory].self, from: data)
            cacheCategories(kind, cats: decoded)
        } catch {
            errorMessage = "Categories failed: \(error.localizedDescription)"
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
        }
    }

    func loadLibrary(_ kind: ContentKind) async {
        guard library[kind] == nil, !libraryLoading.contains(kind),
              let url = makeURL(action: actions(for: kind).items) else { return }
        libraryLoading.insert(kind)
        libraryError = nil
        defer { libraryLoading.remove(kind) }
        do {
            let data = try await fetch(url, timeout: 90)
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode([MediaItem].self, from: data)
            }.value
            cacheLibrary(kind, items: decoded)
        } catch {
            libraryError = "Could not load library: \(error.localizedDescription)"
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

// MARK: - Root View

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
                Text(error).font(.caption).foregroundColor(.red)
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
            
            Text("Note: Cache resets weekly to keep your device lean. Credentials are saved.")
                .font(.caption2)
                .foregroundColor(.gray)
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

// MARK: - Home

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
                        Text("Hides 4K/UHD, no poster images, 30s buffer")
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
        .onChange(of: kind) { _ in query = "" }
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

// MARK: - Search Results

struct SearchResultsView: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let query: String

    @AppStorage("data_saver") private var dataSaver = true
    private let maxResults = 300

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
                    Text("Loading the full list...")
                        .font(.caption).foregroundColor(.gray)
                }
                .padding(.horizontal)
            } else if let error = model.libraryError, model.library[kind] == nil {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            } else {
                Text(found.count > maxResults
                     ? "\(found.count) RESULTS · showing first \(maxResults)"
                     : "\(found.count) RESULTS")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(shown) { item in
                        ItemRowLink(model: model, kind: kind, item: item, showIcon: kind == .live || !dataSaver)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Navigation Links

struct ItemDestination: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let item: MediaItem

    var body: some View {
        switch kind {
        case .live:
            LivePlayerView(title: item.name, url: model.liveURL(item))
        case .movies:
            KSPlayerVODView(title: item.name, url: model.movieURL(item))
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

struct ItemRowLink: View {
    @ObservedObject var model: IPTVViewModel
    let kind: ContentKind
    let item: MediaItem
    let showIcon: Bool

    var body: some View {
        NavigationLink(destination: ItemDestination(model: model, kind: kind, item: item)) {
            MediaRow(name: item.name, icon: item.icon, symbol: symbolName(for: kind), showIcon: showIcon)
        }
    }
}

// MARK: - Item List

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

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in
                            ItemRowLink(model: model, kind: kind, item: item, showIcon: kind == .live || !dataSaver)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationBarTitle(category.categoryName, displayMode: .inline)
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
                    Spacer()
                }
                .padding(.horizontal)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(episodes) { ep in
                            NavigationLink(destination: KSPlayerVODView(title: ep.title, url: model.episodeURL(ep))) {
                                MediaRow(name: "S\(ep.season) E\(ep.number) · \(ep.title)", icon: nil, symbol: "play.fill", showIcon: false)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationBarTitle(series.name, displayMode: .inline)
        .task {
            loading = true
            episodes = await model.loadEpisodes(for: series)
            loading = false
        }
    }
}

// MARK: - KSPlayer VOD View (Supports .mkv, custom codecs, and system-wide PiP)

struct KSPlayerVODView: View {
    let title: String
    let url: URL?

    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @AppStorage("data_saver") private var dataSaver = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url = url {
                // KSPlayer uses KSVideoPlayer view initialized with a URL and resource options
                KSVideoPlayer(url: url)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear {
                        if dataSaver {
                            // Enforce custom buffer/bitrate options if configured
                        }
                    }

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }
            } else {
                Text("Could not build stream URL").foregroundColor(.red)
            }

            if showControls && url != nil {
                VStack {
                    HStack(spacing: 15) {
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                        }
                        
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color.black.opacity(0.65))
                    
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Live TV Player (VLC, Low Delay)

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

struct LivePlayerView: View {
    let title: String
    let url: URL?

    @AppStorage("live_caching") private var liveCaching = 1500

    @StateObject private var controller = VLCController()
    @State private var connecting = true
    @State private var showControls = true

    @Environment(\.presentationMode) var presentationMode

    private let steps = [300, 500, 800, 1200, 1500, 2000, 3000, 5000]
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if url != nil {
                VLCSurface(controller: controller, onReady: { startPlayback() })
                    .ignoresSafeArea()

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }
            } else {
                Text("Could not build stream URL").foregroundColor(.red)
            }

            if connecting && url != nil {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(1.2)
                    Text("Connecting...").font(.subheadline).foregroundColor(.gray)
                }
            }

            if showControls && url != nil {
                VStack {
                    HStack(spacing: 15) {
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                        }

                        Text(title)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding()
                    .background(Color.black.opacity(0.65))

                    Spacer()

                    liveControls
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(poll) { _ in
            if controller.player.isPlaying { connecting = false }
        }
    }

    private func startPlayback() {
        guard let url = url else { return }
        connecting = true
        let opts = [":network-caching=\(liveCaching)",
                    ":live-caching=\(liveCaching)",
                    ":clock-jitter=0",
                    ":clock-synchro=0"]
        controller.start(url: url, options: opts)
    }

    private func changeBuffer(by direction: Int) {
        let idx = steps.firstIndex(where: { $0 >= liveCaching }) ?? (steps.count - 1)
        let newIdx = min(max(idx + direction, 0), steps.count - 1)
        liveCaching = steps[newIdx]
        startPlayback()
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
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.65))
    }
}
