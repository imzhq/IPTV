import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

// MARK: - VLC player

enum PlaybackMode { case live, vod }

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

struct PlayerView: View {
    let title: String
    let url: URL?
    let mode: PlaybackMode

    // Saved settings
    @AppStorage("live_caching") private var liveCaching = 1500   // ms of buffer for live TV
    @AppStorage("data_saver") private var dataSaver = true

    @StateObject private var controller = VLCController()
    @State private var connecting = true
    @State private var showControls = true
    @State private var progress: Double = 0
    @State private var scrubbing = false
    @State private var playing = true
    @State private var elapsed = "0:00"
    @State private var total = "0:00"

    private let steps = [300, 500, 800, 1200, 1500, 2000, 3000, 5000]
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if url != nil {
                VLCSurface(controller: controller, onReady: { startPlayback() })
                    .ignoresSafeArea(edges: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showControls.toggle() } }
            } else {
                Text("Could not build stream URL").foregroundColor(.red)
            }

            if connecting && url != nil {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(1.2)
                    Text("Connecting...")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }

            if showControls && url != nil {
                VStack {
                    Spacer()
                    controlsPanel
                }
            }
        }
        .navigationBarTitle(title, displayMode: .inline)
        .navigationBarHidden(false)
        .onAppear {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Audio session error: \(error)")
            }
            UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on while watching
        }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(poll) { _ in tick() }
    }

    // MARK: Playback

    private func startPlayback() {
        guard let url = url else { return }
        connecting = true
        var opts: [String]
        switch mode {
        case .live:
            opts = [":network-caching=\(liveCaching)",
                    ":live-caching=\(liveCaching)",
                    ":clock-jitter=0",
                    ":clock-synchro=0"]
        case .vod:
            let cache = dataSaver ? 1500 : 4000
            opts = [":network-caching=\(cache)"]
            if dataSaver {
                // Only affects providers that serve adaptive (HLS/DASH) movies
                opts += [":adaptive-maxheight=720", ":adaptive-maxwidth=1280"]
            }
        }
        controller.start(url: url, options: opts)
    }

    private func changeBuffer(by direction: Int) {
        let idx = steps.firstIndex(where: { $0 >= liveCaching }) ?? (steps.count - 1)
        let newIdx = min(max(idx + direction, 0), steps.count - 1)
        liveCaching = steps[newIdx]
        startPlayback()
    }

    private func tick() {
        let p = controller.player
        playing = p.isPlaying
        if p.isPlaying { connecting = false }
        if mode == .vod && !scrubbing {
            progress = Double(p.position)
            elapsed = clock(Int(p.time.intValue))
            total = clock(Int(p.media?.length.intValue ?? 0))
        }
    }

    private func seek(by seconds: Double) {
        let p = controller.player
        let lengthMs = Double(p.media?.length.intValue ?? 0)
        guard lengthMs > 0 else { return }
        let newPos = Double(p.position) + (seconds * 1000) / lengthMs
        p.position = Float(min(max(newPos, 0), 0.999))
    }

    private func clock(_ ms: Int) -> String {
        let s = max(ms, 0) / 1000
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: Controls

    @ViewBuilder
    private var controlsPanel: some View {
        switch mode {
        case .live: liveControls
        case .vod: vodControls
        }
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
            Text("Lower = closer to live. Raise it if the picture lags.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.65))
    }

    private var vodControls: some View {
        VStack(spacing: 6) {
            Slider(value: $progress, in: 0...1, onEditingChanged: { editing in
                scrubbing = editing
                if !editing { controller.player.position = Float(progress) }
            })
            HStack {
                Text(elapsed).font(.caption2).foregroundColor(.white)
                Spacer()
                Text(total).font(.caption2).foregroundColor(.white)
            }
            HStack(spacing: 30) {
                Button(action: { seek(by: -30) }) {
                    Image(systemName: "gobackward.30").font(.title2)
                }
                Button(action: {
                    if controller.player.isPlaying { controller.player.pause() }
                    else { controller.player.play() }
                }) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title)
                }
                Button(action: { seek(by: 30) }) {
                    Image(systemName: "goforward.30").font(.title2)
                }
            }
            .foregroundColor(.white)
        }
        .padding(12)
        .background(Color.black.opacity(0.65))
    }
}

// END OF FILE
