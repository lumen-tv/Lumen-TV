import AVKit
import MediaPlayer
import SwiftUI

// The film player's controls, laid out like Apple's own TV app player (Hayat 2026-11-03, from
// screenshots of it on iPhone and iPad; without its Share and Extras buttons): dark glass circles
// and capsules over a dimmed picture, in the system font.

/// Dark glass: iOS 26's Liquid Glass where there is one, else a dark blur with a faint rim.
struct PlayerGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(Color.black.opacity(0.35), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func playerGlass<S: Shape>(_ shape: S) -> some View { modifier(PlayerGlass(shape: shape)) }
}

/// A round glass button with an SF Symbol: close, −10 s, play/pause, +10 s.
struct PlayerCircleButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 50
    var iconSize: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .playerGlass(Circle())
        .accessibilityLabel(label)
    }
}

/// Several icon buttons sharing one glass capsule (Picture in Picture + AirPlay; speed, audio,
/// subtitles).
struct PlayerCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 8)
            .frame(height: 50)
            .playerGlass(Capsule())
    }
}

/// One icon in a `PlayerCapsule`.
struct PlayerIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
    }
}

/// "Info", "Continue Watching": text pills along the bottom. White while their panel is open.
struct PlayerPill: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 20)
                .frame(height: 46)
                .background(selected ? Capsule().fill(.white) : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .playerGlass(Capsule())
    }
}

#if os(iOS)
/// The phone's own volume, as Apple's player shows it. iOS has no public call to set it; the
/// accepted way is the slider inside an (invisible) `MPVolumeView`, which also keeps iOS's
/// volume banner from covering the film while you drag.
@MainActor
@Observable
final class SystemVolume {
    private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored fileprivate weak var slider: UISlider?
    /// The hidden volume view, to find its slider again if it wasn't there yet.
    @ObservationIgnored fileprivate weak var view: MPVolumeView?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // The volume buttons change it too.
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let value = session.outputVolume
            Task { @MainActor in
                guard let self, abs(self.level - value) > 0.001 else { return }
                self.level = value
            }
        }
    }

    func set(_ value: Float) {
        let clamped = min(1, max(0, value))
        level = clamped
        if slider == nil, let view { slider = Self.findSlider(in: view) }
        guard let slider else { return }
        // Setting `value` alone only moved the hidden slider: the volume didn't change. The
        // slider changes the volume in its value-changed action, so that action is sent too.
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    /// The slider sits a few views deep in newer iOS versions, not directly inside.
    fileprivate static func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let slider = sub as? UISlider { return slider }
            if let slider = findSlider(in: sub) { return slider }
        }
        return nil
    }
}

/// The hidden `MPVolumeView` `SystemVolume` sets the volume through. Must be on screen (tiny,
/// nearly transparent) for iOS to treat it as the visible volume control.
struct HiddenVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        volume.view = view
        // Its slider is made a moment later.
        DispatchQueue.main.async {
            volume.slider = SystemVolume.findSlider(in: view)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        volume.view = uiView
        if volume.slider == nil { volume.slider = SystemVolume.findSlider(in: uiView) }
    }
}

#endif

/// Top right: a bar you drag for the volume, and the speaker.
struct VolumeCapsule: View {
    let volume: SystemVolume
    var width: CGFloat = 170
    let touched: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: max(6, geo.size.width * CGFloat(volume.level)))
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            volume.set(Float(drag.location.x / max(geo.size.width, 1)))
                            touched()
                        }
                )
            }
            .frame(width: width)
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 50)
        .playerGlass(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume.level * 100)) percent")
        .accessibilityAdjustableAction { direction in
            volume.set(volume.level + (direction == .increment ? 0.1 : -0.1))
        }
    }

    private var icon: String {
        switch volume.level {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Elapsed time, the bar, time left ("−2:12:00"), on one line as in Apple's player. The bar has
/// no knob: drag anywhere along it (it thickens while you do); the picture follows the finger
/// (`VodPlayerModel.scrub`) and letting go lands exactly there. Its own view because it reads
/// the position, which changes twice a second: only this part redraws then.
struct PlayerTimeline: View {
    let model: VodPlayerModel
    @Binding var scrubbing: Double?
    let touched: () -> Void
    /// Where the drag started, for the bubble's "+12:30".
    @State private var scrubStart: Double?

    var body: some View {
        let shown = scrubbing ?? model.position
        let length = max(model.duration, 1)
        HStack(spacing: 14) {
            Text(formatTime(shown))
            GeometryReader { geo in
                let fraction = CGFloat(min(1, max(0, shown / length)))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: max(scrubbing == nil ? 6 : 12, geo.size.width * fraction))
                }
                .frame(height: scrubbing == nil ? 6 : 12)
                .frame(maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
                .contentShape(Rectangle())
                // While dragging: a bubble over your finger with the time you'd land on and how far
                // that is from where you started (Hayat 2026-11-03; thumbnails would need a second
                // connection to the provider, which allows one).
                .overlay(alignment: .topLeading) {
                    if let scrubbing {
                        TimeBubble(time: scrubbing, change: scrubStart.map { scrubbing - $0 })
                            .position(x: min(max(geo.size.width * fraction, 50), max(geo.size.width - 50, 50)),
                                      y: geo.size.height / 2 - 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: scrubbing == nil)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let value = Double(min(1, max(0, drag.location.x / max(geo.size.width, 1)))) * length
                            if scrubbing == nil { scrubStart = model.position }
                            scrubbing = value
                            model.scrub(to: value)
                            touched()
                        }
                        .onEnded { _ in
                            if let target = scrubbing { model.seek(to: target) }
                            scrubbing = nil
                            scrubStart = nil
                        }
                )
            }
            .frame(height: 28)
            Text("−" + formatTime(max(0, model.duration - shown)))
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(scrubbing == nil ? 0.7 : 1))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(formatTime(shown)) of \(formatTime(model.duration))")
        .accessibilityAdjustableAction { direction in
            model.seek(to: max(0, model.position + (direction == .increment ? 10 : -10)))
        }
    }
}

/// "1:12:30" with "+12:30" under it, over the finger while scrubbing.
private struct TimeBubble: View {
    let time: Double
    let change: Double?

    var body: some View {
        VStack(spacing: 1) {
            Text(formatTime(time))
                .font(.system(size: 17, weight: .semibold))
            if let change, abs(change) >= 1 {
                Text((change > 0 ? "+" : "−") + formatTime(abs(change)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .playerGlass(Capsule())
        .fixedSize()
    }
}

/// Playback speed (the gauge).
struct SpeedMenu: View {
    let model: VodPlayerModel
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "1× (Normal)" : "\(speed.formatted())×").tag(speed)
                }
            }
        } label: {
            PlayerIcon(systemImage: "gauge.with.dots.needle.67percent")
        }
        .plainMenu()
        .accessibilityLabel("Playback speed")
    }
}

/// Audio languages (the waveform). Picking one also remembers it for the next film.
struct AudioMenu: View {
    let model: VodPlayerModel

    var body: some View {
        Menu {
            let tracks = model.audioTracks()
            if tracks.isEmpty {
                Text("Only one audio track")
            } else {
                Section("Audio") {
                    ForEach(tracks, id: \.id) { track in
                        Button { model.selectAudio(track.id) } label: {
                            if track.selected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        }
                    }
                }
            }
        } label: {
            PlayerIcon(systemImage: "waveform")
        }
        .plainMenu()
        .accessibilityLabel("Audio")
    }
}

/// Subtitles (the speech bubble). Picking one also remembers it for the next film.
struct SubtitleMenu: View {
    let model: VodPlayerModel

    var body: some View {
        Menu {
            let tracks = model.subtitleTracks()
            if tracks.count < 2 {
                Text("No subtitles in this video")
            } else {
                Section("Subtitles") {
                    ForEach(tracks, id: \.id) { track in
                        Button { model.selectSubtitle(track.id) } label: {
                            if track.selected { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        }
                    }
                }
            }
        } label: {
            PlayerIcon(systemImage: "captions.bubble")
        }
        .plainMenu()
        .accessibilityLabel("Subtitles")
    }
}
