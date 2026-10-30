import SwiftUI

// MARK: - 1. Data Model for Categories
struct LiveCategory: Codable, Identifiable {
    var id: String { categoryId }
    
    let categoryId: String
    let categoryName: String
    let parentId: Int?
    
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }
}

// MARK: - 2. Network Manager / ViewModel
class IPTVViewModel: ObservableObject {
    @Published var categories: [LiveCategory] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // REPLACE THESE with your actual Xtream Codes provider credentials and URL
    private let baseURL = "http://your-provider-url.com:8080"
    private let username = "your_username"
    private let password = "your_password"

    func fetchLiveCategories() async {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        let endpoint = "\(baseURL)/player_api.php?username=\(username)&password=\(password)&action=get_live_categories"
        
        guard let url = URL(string: endpoint) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL structure"
                self.isLoading = false
            }
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("❌ Server returned status code: \(httpResponse.statusCode)")
            }
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("RAW API RESPONSE: \(jsonString)")
            }
            
            let decodedCategories = try JSONDecoder().decode([LiveCategory].self, from: data)
            
            DispatchQueue.main.async {
                self.categories = decodedCategories
                self.isLoading = false
                print("✅ Successfully loaded \(decodedCategories.count) categories!")
            }
            
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                print("❌ Failed to fetch or decode categories: \(error)")
            }
        }
    }
}

// MARK: - 3. SwiftUI Main View
struct LiveCategoriesView: View {
    // FIXED: Properly included 'var' here
    @StateObject private var model = IPTVViewModel()
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Lean IPTV")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    HStack(spacing: 12) {
                        Button(action: { selectedTab = 0 }) {
                            Text("Live TV")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selectedTab == 0 ? Color.gray.opacity(0.5) : Color.gray.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        
                        Button(action: { selectedTab = 1 }) {
                            Text("Series")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selectedTab == 1 ? Color.gray.opacity(0.5) : Color.gray.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                    
                    HStack {
                        Text("LIVE CATEGORIES (\(model.categories.count))")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        if model.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.leading, 8)
                        }
                    }
                    .padding(.horizontal)
                    
                    if let error = model.errorMessage {
                        Text("Error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(model.categories) { category in
                                HStack {
                                    Text(category.categoryName)
                                        .foregroundColor(.white)
                                        .font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                }
                                .padding()
                                .background(Color.gray.opacity(0.15))
                                .cornerRadius(10)
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .task {
                await model.fetchLiveCategories()
            }
        }
    }
}
