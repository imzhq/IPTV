import SwiftUI

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

// END OF FILE
