#if os(macOS)
import AppKit
import SwiftUI

/// Updates for the Mac app, which isn't in the App Store. Each version is uploaded to the GitHub
/// release tagged `mac` (named "Lumen for Mac 1.1", the DMG always called Lumen.dmg, see
/// docs/MAC.md), so lumen-tv.github.io/mac and this check never change. At launch and from
/// Lumen → Check for Updates, Lumen reads that release; if its version is newer than this one,
/// it offers to download the new DMG (opened in the browser; drag Lumen to Applications again).
@MainActor
@Observable
final class MacUpdates {
    static let shared = MacUpdates()

    struct Update: Identifiable {
        let version: String
        let notes: String
        let download: URL
        var id: String { version }
    }

    /// A newer version, shown as an alert by `RootView`.
    var offer: Update?
    /// "You're up to date" (only after Check for Updates in the menu).
    var upToDate = false

    private static let release = URL(string: "https://api.github.com/repos/lumen-tv/Lumen-TV/releases/tags/mac")!
    private static let page = URL(string: "https://lumen-tv.github.io/mac")!

    func check(userAsked: Bool = false) async {
        var request = URLRequest(url: Self.release)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lumen-Mac", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              let version = Self.version(in: name) else {
            if userAsked { upToDate = true }
            return
        }
        guard Self.isNewer(version, than: Self.current) else {
            if userAsked { upToDate = true }
            return
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let url = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)) ?? Self.page
        offer = Update(version: version, notes: (json["body"] as? String) ?? "", download: url)
    }

    /// This copy's version, "1.0".
    nonisolated static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func download(_ update: Update) {
        NSWorkspace.shared.open(update.download)
        offer = nil
    }

    /// "Lumen for Mac 1.2.3" → "1.2.3".
    nonisolated static func version(in name: String) -> String? {
        name.split(separator: " ").last.map(String.init).flatMap { $0.first?.isNumber == true ? $0 : nil }
    }

    /// Compares 1.10 > 1.9 number by number.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

extension View {
    /// The update alerts, on the root.
    func macUpdateAlerts() -> some View { modifier(MacUpdateAlerts()) }
}

private struct MacUpdateAlerts: ViewModifier {
    @Bindable private var updates = MacUpdates.shared

    func body(content: Content) -> some View {
        content
            .alert(item: $updates.offer) { update in
                Alert(
                    title: Text("Lumen \(update.version) is available"),
                    message: Text(update.notes.isEmpty ? "You have \(MacUpdates.current)." : update.notes),
                    primaryButton: .default(Text("Download")) { updates.download(update) },
                    secondaryButton: .cancel(Text("Later"))
                )
            }
            .alert("Lumen is up to date", isPresented: $updates.upToDate) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You have the newest version, \(MacUpdates.current).")
            }
    }
}
#endif
