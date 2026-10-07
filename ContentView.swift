import SwiftUI
import AVKit

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL: String = ""
    @AppStorage("username") private var username: String = ""
    @AppStorage("password") private var password: String = ""
    @State private var isLogined: Bool = false

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
                            isLogined = true
                        }) {
                            Text("Connect")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.top, 10)
                    }
                    .padding()
                } else {
                    List {
                        Section(header: Text("Channels")) {
                            NavigationLink(destination: PlayerView(streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")) {
                                HStack {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 40, height: 40)
                                        .cornerRadius(6)
                                    
                                    Text("Sample HD Stream")
                                        .font(.headline)
                                        .padding(.leading, 8)
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
                        }
                    }
                }
            }
        }
    }
}

struct PlayerView: View {
    let streamURL: String
    
    var body: some View {
        VideoPlayer(player: AVPlayer(url: URL(string: streamURL)!))
            .edgesIgnoringSafeArea(.all)
    }
}
