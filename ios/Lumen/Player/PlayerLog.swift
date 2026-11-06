import Foundation

/// A small record of what the film player saw (VLC's time, length and state once a second, plus
/// opens, jumps and reopens), kept in Caches/Lumen/player-log.txt, for tracking down timeline
/// problems from a real provider. Never holds links (they carry the password) or names: just
/// numbers. Kept under about 1 MB (the older half is dropped).
enum PlayerLog {
    private static let queue = DispatchQueue(label: "lumen.player-log", qos: .utility)
    private static let file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lumen", isDirectory: true)
        .appendingPathComponent("player-log.txt")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func add(_ text: String) {
        let line = "\(stamp.string(from: .now)) \(text)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000,
               let all = try? Data(contentsOf: file) {
                try? all.suffix(size / 2).write(to: file)
            }
        }
    }

    /// Seconds as "1:02:03.4", easier to read in the log than raw numbers.
    static func t(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "?" }
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d:%02d.%d", whole / 3600, whole / 60 % 60, whole % 60, abs(tenths))
    }
}
