import AVKit
import SwiftUI

/// Plays Apple's public HLS test stream, to check video, sound, rotation and Picture in Picture
/// on a new device before any playlist code exists. It's the same kind of stream (.m3u8) that
/// Lumen asks Xtream servers for.
struct TestPlayerView: View {
    private static let testStream = URL(
        string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    )!

    // @State keeps one AVPlayer for the life of this screen (like `remember` in Compose).
    @State private var player = AVPlayer(url: testStream)

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .horizontal)
            .background(.black)
            .navigationTitle("Test video")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Play sound even with the silent switch on, as video apps do.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                player.play()
            }
            .onDisappear { player.pause() }
    }
}
