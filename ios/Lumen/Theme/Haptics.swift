import UIKit

/// Light taps you feel (iPhone; iPads have no haptic engine, so nothing happens there):
/// a click when changing channel or tab, a soft tap when adding or removing a favourite or
/// My List item.
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    static func select() { selection.selectionChanged() }
    static func tap() { impact.impactOccurred() }
}
