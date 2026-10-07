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
                        ProgressView("Loading content...")
                        Spacer()
                    } else {
                        List {
                            if selectedTab == 0 {
                                Section(header: Text("Live Categories (\(liveCategories.count))")) {
                                    ForEach(liveCategories) { category in
                                        NavigationLink(destination: LiveChannelListView(categoryName: category.category_name, streams: liveStreams.filter { $0.category_id == category.category_id }, serverURL: serverURL, username: username, password: password)) {
                                            Text(category.category_name)
                                                .font(.headline)
                                        }
                                    }
                                }
                            } else {
                                Section(header: Text("Series Categories (\(seriesCategories.count))")) {
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
            .onAppear {
                if !serverURL.isEmpty {
                    loadAllData()
                }
            }
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
            if let data = data {
                if let decoded = try? JSONDecoder().decode([Category].self, from: data) {
                    DispatchQueue.main.async { self.liveCategories = decoded }
                } else if let rawString = String(data: data, encoding: .utf8) {
                    print("Live Cat JSON Error: \(rawString)")
                }
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
