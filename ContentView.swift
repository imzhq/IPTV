import SwiftUI
import AVKit

// MARK: - Models

struct LiveCategory: Decodable, Identifiable {
    var id: String { categoryId }
    let categoryId: String
    let categoryName: String

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Some providers send category_id as a number, others as a string
        if let s = try? c.decode(String.self, forKey: .categoryId) {
            categoryId = s
        } else {
            categoryId = String(try c.decode(Int.self, forKey: .categoryId))
        }
        categoryName = (try? c.decode(String.self, forKey: .categoryName)) ?? "Unnamed"
    }
}

struct LiveChannel: Decodable, Identifiable {
    let id: Int
    let name: String
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case id = "stream_id"
        case name
        case icon = "stream_icon"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .id) {
            id = i
        } else if let s = try? c.decode(String.self, forKey: .id), let i = Int(s) {
            id = i
        } else {
            id = 0
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? "Unknown"
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
    }
}

// MARK: - ViewModel

@MainActor
class IPTVViewModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "iptv_host") ?? ""
    @Published var username: String = UserDefaults.standard.string(forKey: "iptv_user") ?? ""
    @Published var password: String = UserDefaults.standard.string(forKey: "iptv_pass") ?? ""

    @Published var categories: [LiveCategory] = []
    @Published var channels: [LiveChannel] = []
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    // Normalised server address, e.g. "http://line.example.top" or "http://host:8080"
    private var baseURL: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }

    private func makeURL(action: String? = nil, extra: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: baseURL + "/player_api.php") else { return nil }
        var items = [
            URLQueryItem(name: "username", value: username.trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "password", value: password.trimmingCharacters(in: .whitespaces))
        ]
        if let action = action { items.append(URLQueryItem(name: "action", value: action)) }
        comps.queryItems = items + extra
        return comps.url
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 25)
        // Some providers block the default iOS user agent
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("❌ HTTP status: \(http.statusCode)")
            throw URLError(.badServerResponse)
        }
        return data
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
                await loadCategories()
                if errorMessage == nil { isLoggedIn = true }
            } else {
                errorMessage = "Login failed. Check the URL, username and password."
            }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
            print("❌ Login error: \(error)")
        }
    }

    func loadCategories() async {
        guard let url = makeURL(action: "get_live_categories") else { return }
        do {
            let data = try await fetch(url)
            categories = try JSONDecoder().decode([LiveCategory].self, from: data)
            print("✅ Loaded \(categories.count) categories")
        } catch {
            errorMessage = "Categories failed: \(error.localizedDescription)"
            print("❌ Categories error: \(error)")
        }
    }

    func loadChannels(for category: LiveCategory) async {
        isLoading = true
        errorMessage = nil
        channels = []
        defer { isLoading = false }

        let extra = [URLQueryItem(name: "category_id", value: category.categoryId)]
        guard let url = makeURL(action: "get_live_streams", extra: extra) else { return }
        do {
            let data = try await fetch(url)
            channels = try JSONDecoder().decode([LiveChannel].self, from: data)
            print("✅ Loaded \(channels.count) channels")
        } catch {
            errorMessage = "Channels failed: \(error.localizedDescription)"
            print("❌ Channels error: \(error)")
        }
    }

    // Try ".ts" instead of ".m3u8" if your provider doesn't serve HLS
    func streamURL(for channel: LiveChannel) -> URL? {
        let u = username.trimmingCharacters(in: .whitespaces)
        let p = password.trimmingCharacters(in: .whitespaces)
        return URL(string: "\(baseURL)/live/\(u)/\(p)/\(channel.id).m3u8")
    }

    func logout() {
        isLoggedIn = false
        categories = []
        channels = []
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
                    CategoryListView(model: model)
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

// MARK: - Categories

struct CategoryListView: View {
    @ObservedObject var model: IPTVViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lean IPTV")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
                Button("Log out") { model.logout() }
                    .foregroundColor(.red)
            }
            .padding(.horizontal)

            Text("LIVE CATEGORIES (\(model.categories.count))")
                .font(.subheadline)
                .foregroundColor(.gray)
                .padding(.horizontal)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.categories) { category in
                        NavigationLink(destination: ChannelListView(model: model, category: category)) {
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

// MARK: - Channels

struct ChannelListView: View {
    @ObservedObject var model: IPTVViewModel
    let category: LiveCategory

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CHANNELS (\(model.channels.count))")
                        .font(.subheadline).foregroundColor(.gray)
                    if model.isLoading { ProgressView().scaleEffect(0.8) }
                }
                .padding(.horizontal)

                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.channels) { channel in
                            NavigationLink(destination: PlayerView(channel: channel, url: model.streamURL(for: channel))) {
                                HStack(spacing: 12) {
                                    if let icon = channel.icon, let iconURL = URL(string: icon) {
                                        if #available(iOS 15.0, *) {
                                            AsyncImage(url: iconURL) { image in
                                                image.resizable().scaledToFit()
                                            } placeholder: {
                                                Color.gray.opacity(0.2)
                                            }
                                            .frame(width: 40, height: 40)
                                        }
                                    }
                                    Text(channel.name)
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "play.fill").foregroundColor(.gray)
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
        .navigationBarTitle(category.categoryName, displayMode: .inline)
        .navigationBarHidden(false)
        .task { await model.loadChannels(for: category) }
    }
}

// MARK: - Player (auto catch-up to live, no pauses, only on a good connection)

struct PlayerView: View {
    let channel: LiveChannel
    let url: URL?
    @State private var player: AVPlayer? = nil
    @State private var catchingUp = false
    @State private var showBanner = false
    @State private var noticeShown = false

    private let maxDelay: Double = 20        // start catching up when further behind than this
    private let targetDelay: Double = 10     // stop catching up at this delay
    private let catchUpRate: Float = 1.15    // playback speed while catching up
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Text("Could not build stream URL").foregroundColor(.red)
            }

            if showBanner {
                Text("Good connection — catching up to live")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(20)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationBarTitle(channel.name, displayMode: .inline)
        .navigationBarHidden(false)
        .onAppear {
            guard let url = url else { return }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain   // keeps voices natural when sped up
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            catchingUp = false
        }
        .onReceive(timer) { _ in tick() }
    }

    // MARK: Catch-up logic (no seeking, so no pauses)

    private func tick() {
        guard let p = player, let item = p.currentItem else { return }
        if p.timeControlStatus == .paused { catchingUp = false; return }   // respect the user pausing
        guard let edge = liveEdge() else { return }

        let delay = max(0, edge - CMTimeGetSeconds(p.currentTime()))

        if catchingUp {
            if delay <= targetDelay || !connectionIsGood(item) {
                p.rate = 1.0
                catchingUp = false
            }
        } else if delay > maxDelay && connectionIsGood(item) {
            catchingUp = true
            p.rate = catchUpRate
            showNotice()
        }
    }

    private func liveEdge() -> Double? {
        guard let item = player?.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        return CMTimeGetSeconds(CMTimeRangeGetEnd(range))
    }

    private func connectionIsGood(_ item: AVPlayerItem) -> Bool {
        guard item.isPlaybackLikelyToKeepUp,
              let ev = item.accessLog()?.events.last else { return false }
        let observed = ev.observedBitrate
        let indicated = ev.indicatedBitrate
        let fastEnough = indicated > 0 ? observed >= indicated * 2 : observed >= 6_000_000
        return fastEnough && bufferedAhead(item) >= 4
    }

    private func bufferedAhead(_ item: AVPlayerItem) -> Double {
        let now = CMTimeGetSeconds(item.currentTime())
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = CMTimeGetSeconds(r.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(r))
            if now >= start && now <= end { return end - now }
        }
        return 0
    }

    private func showNotice() {
        guard !noticeShown else { return }
        noticeShown = true
        withAnimation { showBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { showBanner = false }
        }
    }
}
