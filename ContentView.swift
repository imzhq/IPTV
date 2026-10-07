import SwiftUI
import AVKit

struct Category: Codable, Identifiable {
    let category_id: String
    let category_name: String
    var id: String { category_id }
}

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL: String = ""
    @AppStorage("username") private var username: String = ""
    @AppStorage("password") private var password: String = ""
    
    @State private var categories: [Category] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if serverURL.isEmpty || username.isEmpty || password.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("IPTV Login")
                            .font(.largeTitle)
                            .bold()
                        
                        TextField("Server URL (e.g., http://line.provider.com:8080)", text: $serverURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        TextField("Username", text: $username)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        SecureField("Password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button(action: {
                            fetchCategories()
                        }) {
                            Text("Connect")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.top, 10)
                        
                        if let errorMessage = errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                    .padding()
                } else {
                    List {
                        Section(header: Text("Live TV Categories")) {
                            if isLoading {
                                ProgressView("Loading categories...")
                            } else if categories.isEmpty {
                                Text("No categories found. Check credentials.")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(categories) { category in
                                    NavigationLink(destination: Text("Streams for \(category.category_name)")) {
                                        HStack {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: 40, height: 40)
                                                .cornerRadius(6)
                                            
                                            Text(category.category_name)
                                                .font(.headline)
                                                .padding(.leading, 8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Lean IPTV")
                    .toolbar {
                        Button("Logout") {
                            serverURL = ""
                            username = ""
                            password = ""
                            categories = []
                        }
                    }
                }
            }
        }
        .onAppear {
            if !serverURL.isEmpty && !username.isEmpty && !password.isEmpty {
                fetchCategories()
            }
        }
    }
    
    func fetchCategories() {
        let cleanURL = serverURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(cleanURL)/player_api.php?username=\(username)&password=\(password)&action=get_live_categories") else {
            errorMessage = "Invalid URL format"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    errorMessage = error.localizedDescription
                    return
                }
                
                guard let data = data else {
                    errorMessage = "No data received"
                    return
                }
                
                do {
                    let decodedCategories = try JSONDecoder().decode([Category].self, from: data)
                    self.categories = decodedCategories
                } catch {
                    errorMessage = "Failed to parse categories. Verify credentials."
                }
            }
        }.resume()
    }
}
