import SwiftUI
import AVKit

struct ContentView: View {
    // A simple, text-based list for your categories and streams
    let categories = ["Live Sports", "FHD Movies", "Series", "24/7 Channels"]
    
    var body: some View {
        NavigationView {
            List(categories, id: \.self) { category in
                NavigationLink(destination: Text("Stream Player for \(category)")) {
                    HStack {
                        // Minimalist solid-color box instead of downloading high-res image posters
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .cornerRadius(6)
                        
                        Text(category)
                            .font(.headline)
                            .padding(.leading, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Lean IPTV")
        }
    }
}
