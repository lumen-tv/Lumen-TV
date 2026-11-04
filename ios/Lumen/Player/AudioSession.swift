import AVFoundation

enum AVAudioSessionHelper {
    /// Sound plays even with the silent switch on, as in other video apps.
    static func activate() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
    }
}
