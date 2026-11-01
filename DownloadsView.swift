import SwiftUI

// MARK: - Download button (movies and episodes)

struct DownloadButton: View {
    let title: String
    let url: URL?
    let ext: String
    @ObservedObject private var downloads = DownloadManager.shared

    private func iconName(_ state: DLState?) -> String {
        switch state {
        case .none: return "arrow.down.circle"
        case .some(.queued): return "clock"
        case .some(.downloading), .some(.finishing): return "arrow.down.circle.fill"
        case .some(.completed): return "checkmark.circle.fill"
        case .some(.failed): return "arrow.clockwise.circle"
        }
    }

    var body: some View {
        let existing = url.flatMap { downloads.item(forRemote: $0.absoluteString) }
        Button(action: {
            guard let url = url else { return }
            downloads.add(title: title, remote: url, ext: ext)
        }) {
            Image(systemName: iconName(existing?.state))
                .font(.title2)
                .foregroundColor(existing?.state == .completed ? .green : .red)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Downloads tab

struct DownloadsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("dl_connections") private var connections = 4
    @AppStorage("dl_wifi_only") private var wifiOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $connections, in: 1...8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connections per download: \(connections)")
                        .foregroundColor(.white)
                    Text("More = faster, but some providers refuse extra connections. Lower it if downloads fail.")
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .padding(.horizontal)

            Toggle(isOn: $wifiOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi only").foregroundColor(.white)
                    Text("Off = downloads also use mobile data")
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .red))
            .padding(.horizontal)

            Text("Downloads keep going with the phone locked. Swiping the app away stops them. Stored: \(formatBytes(downloads.usedBytes))")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal)

            if downloads.items.isEmpty {
                Text("Nothing downloaded yet. Tap the arrow next to a movie or episode.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(downloads.items.reversed()) { item in
                        DownloadRow(item: item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject private var downloads = DownloadManager.shared

    private var progressText: String {
        var s = formatBytes(item.done)
        if item.total > 0 { s += " of " + formatBytes(item.total) }
        if let speed = downloads.speeds[item.id] { s += "  ·  " + formatBytes(Int64(speed)) + "/s" }
        return s
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            switch item.state {
            case .queued:
                Text("Waiting…").font(.caption).foregroundColor(.gray)
            case .downloading:
                if item.total > 0 {
                    ProgressView(value: Double(min(item.done, item.total)), total: Double(item.total))
                        .progressViewStyle(LinearProgressViewStyle(tint: .red))
                } else {
                    ProgressView()
                }
                Text(progressText).font(.caption).foregroundColor(.gray)
            case .finishing:
                Text("Finishing up…").font(.caption).foregroundColor(.gray)
            case .completed:
                Text(formatBytes(item.total) + " · tap to play")
                    .font(.caption).foregroundColor(.gray)
            case .failed:
                Text(item.error ?? "Failed")
                    .font(.caption).foregroundColor(.red)
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if item.state == .completed, let local = downloads.localURL(for: item) {
                NavigationLink(destination: PlayerView(title: item.title, url: local, mode: .vod)) {
                    HStack {
                        info
                        Spacer()
                        Image(systemName: "play.fill").foregroundColor(.gray)
                    }
                }
            } else {
                info
                Spacer()
            }

            if item.state == .failed {
                Button(action: { downloads.retry(item.id) }) {
                    Image(systemName: "arrow.clockwise").foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Button(action: { downloads.remove(item.id) }) {
                Image(systemName: "trash").foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
    }
}

// END OF FILE
