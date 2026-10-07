import SwiftUI
import AVKit

struct Category: Codable, Identifiable {
    let category_id: String
    let category_name: String
    var id: String { category_id }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category_name = try container.decode(String.self, forKey: .category_name)
        if let strID = try? container.decode(String.self, forKey: .category_id) {
            category_id = strID
        } else if let intID = try? container.decode(Int.self, forKey: .category_id) {
            category_id = String(intID)
        } else {
            category_id = ""
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case category_id, category_name
    }
}

struct LiveStream: Codable, Identifiable {
    let num: Int?
    let name: String
    let stream_type: String?
    let stream_id: Int
    let stream_icon: String?
    let category_id: String?
    let container_extension: String?
    
    var id: Int { stream_id }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        num = try container.decodeIfPresent(Int.self, forKey: .num)
        name = try container.decode(String.self, forKey: .name)
        stream_type = try container.decodeIfPresent(String.self, forKey: .stream_type)
        
        if let intID = try? container.decode(Int.self, forKey: .stream_id) {
            stream_id = intID
        } else if let strID = try? container.decode(String.self, forKey: .stream_id), let parsed = Int(strID) {
            stream_id = parsed
        } else {
            stream_id = 0
        }
        
        stream_icon = try container.decodeIfPresent(String.self, forKey: .stream_icon)
        
        if let strCat = try? container.decode(String.self, forKey: .category_id) {
            category_id = strCat
        } else if let intCat = try? container.decode(Int.self, forKey: .category_id) {
            category_id = String(intCat)
        } else {
            category_id = nil
        }
        
        container_extension = try container.decodeIfPresent(String.self, forKey: .container_extension)
    }
    
    enum CodingKeys: String, CodingKey {
        case num, name, stream_type, stream_id, stream_icon, category_id, container_extension
    }
}

struct SeriesItem: Codable, Identifiable {
    let num: Int?
    let name: String
    let series_id: Int
    let cover: String?
    let category_id: String?
    
    var id: Int { series_id }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        num = try container.decodeIfPresent(Int.self, forKey: .num)
        name = try container.decode(String.self, forKey: .name)
        
        if let intID = try? container.decode(Int.self, forKey: .series_id) {
            series_id = intID
        } else if let strID = try? container.decode(String.self, forKey: .series_id), let parsed = Int(strID) {
            series_id = parsed
        } else {
            series_id = 0
        }
        
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        
        if let strCat = try? container.decode(String.self, forKey: .category_id) {
            category_id = strCat
        } else if let intCat = try? container.decode(Int.self, forKey: .category_id) {
            category_id = String(intCat)
        } else {
            category_id = nil
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case num, name, series_id, cover, category_id
    }
}

struct Episode: Codable, Identifiable {
    let id: String
    let episode_num: Int
    let title: String
    let container_extension: String?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        episode_num = try container.decodeIfPresent(Int.self, forKey: .episode_num) ?? 1
        container_extension = try container.decodeIfPresent(String.self, forKey: .container_extension)
        
        if let strID = try? container.decode(String.self, forKey: .id) {
            id = strID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            id = UUID().uuidString
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id, episode_num, title, container_extension
    }
}

struct SeriesDetail: Codable {
    let episodes: [String: [Episode]]?
}

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL: String = ""
    @AppStorage("username") private var username: String = ""
    @AppStorage("password") private var password: String = ""
    
    @State private var selectedTab: Int = 0
    @State private var liveCategories: [Category] = []
    @State private var seriesCategories: [Category] = []
    @State private var liveStreams: [LiveStream] = []
    @State private var seriesItems: [SeriesItem] = []
    
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if serverURL.isEmpty || username.isEmpty || password.isEmpty {
                    LoginView(serverURL: $serverURL, username: $username, password: $password, onLogin: loadAllData)
                } else {
                    Picker("Tabs", selection: $selectedTab) {
                        Text("Live TV").tag(0)
                        Text("Series").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding()
                    
                    if isLoading {
                        Spacer()
                        ProgressView("Loading channels...")
                        Spacer()
                    } else {
                        List {
                            if selectedTab == 0 {
                                Section(header: Text("Live Categories")) {
                                    ForEach(liveCategories) { category in
                                        NavigationLink(destination: LiveChannelListView(categoryName: category.category_name, streams: liveStreams.filter { $0.category_id == category.category_id }, serverURL: serverURL, username: username, password: password)) {
                                            Text(category.category_name)
                                                .font(.headline)
                                        }
                                    }
                                }
                            } else {
                                Section(header: Text("Series Categories")) {
                                    ForEach(seriesCategories) { category in
                                        NavigationLink(destination: SeriesListView(categoryName: category.category_name, categoryId: category.category_id, serverURL: serverURL, username: username, password: password)) {
                                            Text(category.category_name)
                                                .font(.headline)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lean IPTV")
            .toolbar {
                if !serverURL.isEmpty {
                    Button("Logout") {
                        serverURL = ""
                        username = ""
                        password = ""
                        liveCategories = []
                        seriesCategories = []
                        liveStreams = []
                        seriesItems = []
                    }
                }
            }
        }
    }
    
    func loadAllData() {
        let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let liveCatURL = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_live_categories"),
              let liveChanURL = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_live_streams"),
              let seriesCatURL = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_series_categories") else {
            errorMessage = "Invalid URL"
            return
        }
        
        isLoading = true
        
        URLSession.shared.dataTask(with: liveCatURL) { data, _, _ in
            if let data = data, let decoded = try? JSONDecoder().decode([Category].self, from: data) {
                DispatchQueue.main.async { self.liveCategories = decoded }
            }
        }.resume()
        
        URLSession.shared.dataTask(with: liveChanURL) { data, _, _ in
            if let data = data, let decoded = try? JSONDecoder().decode([LiveStream].self, from: data) {
                DispatchQueue.main.async { self.liveStreams = decoded }
            }
        }.resume()
        
        URLSession.shared.dataTask(with: seriesCatURL) { data, _, _ in
            DispatchQueue.main.async { self.isLoading = false }
            if let data = data, let decoded = try? JSONDecoder().decode([Category].self, from: data) {
                DispatchQueue.main.async { self.seriesCategories = decoded }
            }
        }.resume()
    }
}

struct LoginView: View {
    @Binding var serverURL: String
    @Binding var username: String
    @Binding var password: String
    var onLogin: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Xtream Login")
                .font(.largeTitle)
                .bold()
            
            TextField("Server URL", text: $serverURL)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            Button(action: onLogin) {
                Text("Connect")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding(.top, 10)
        }
        .padding()
    }
}

struct LiveChannelListView: View {
    let categoryName: String
    let streams: [LiveStream]
    let serverURL: String
    let username: String
    let password: String
    
    var body: some View {
        List(streams) { stream in
            let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
            let ext = stream.container_extension ?? "m3u8"
            let streamLink = "\(cleanURL)/live/\(username)/\(password)/\(stream.stream_id).\(ext)"
            
            NavigationLink(destination: PlayerView(streamURL: streamLink)) {
                Text(stream.name)
                    .font(.headline)
            }
        }
        .navigationTitle(categoryName)
    }
}

struct SeriesListView: View {
    let categoryName: String
    let categoryId: String
    let serverURL: String
    let username: String
    let password: String
    
    @State private var series: [SeriesItem] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading series...")
            } else {
                List(series) { item in
                    NavigationLink(destination: EpisodeListView(seriesId: item.series_id, seriesName: item.name, serverURL: serverURL, username: username, password: password)) {
                        Text(item.name)
                            .font(.headline)
                    }
                }
            }
        }
        .navigationTitle(categoryName)
        .onAppear(perform: fetchSeries)
    }
    
    func fetchSeries() {
        let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_series&category_id=\(categoryId)") else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async { self.isLoading = false }
            if let data = data, let decoded = try? JSONDecoder().decode([SeriesItem].self, from: data) {
                DispatchQueue.main.async { self.series = decoded }
            }
        }.resume()
    }
}

struct EpisodeListView: View {
    let seriesId: Int
    let seriesName: String
    let serverURL: String
    let username: String
    let password: String
    
    @State private var episodes: [String: [Episode]] = [:]
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading episodes...")
            } else {
                List {
                    ForEach(episodes.keys.sorted(), id: \.self) { season in
                        Section(header: Text("Season \(season)")) {
                            if let eps = episodes[season] {
                                ForEach(eps) { ep in
                                    let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
                                    let ext = ep.container_extension ?? "mp4"
                                    let epLink = "\(cleanURL)/series/\(username)/\(password)/\(ep.id).\(ext)"
                                    
                                    NavigationLink(destination: PlayerView(streamURL: epLink)) {
                                        Text("E\(ep.episode_num): \(ep.title)")
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(seriesName)
        .onAppear(perform: fetchEpisodes)
    }
    
    func fetchEpisodes() {
        let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_series_info&series_id=\(seriesId)") else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async { self.isLoading = false }
            if let data = data, let decoded = try? JSONDecoder().decode(SeriesDetail.self, from: data), let eps = decoded.episodes {
                DispatchQueue.main.async { self.episodes = eps }
            }
        }.resume()
    }
}

struct PlayerView: View {
    let streamURL: String
    
    var body: some View {
        VideoPlayer(player: AVPlayer(url: URL(string: streamURL)!))
            .edgesIgnoringSafeArea(.all)
    }
}
