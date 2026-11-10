import CoreGraphics
import Foundation

/// Decides the compact style (`CompactStyle`) from the display arrangement and where DynamicLake draws its island. Pure: the
/// executable gathers the values (displays, which one is primary, the host's on-screen window frames) and tests pass their own.
///
/// `.symbols` is right in one arrangement only: the island is on the primary display and that display has a notch. Checked live
/// in DynamicLake Playground 1.2 (14) on 2026-11-10, with a MacBook (notch) and two external displays:
/// - (b) notch display primary, island on it: symbols are placed well inside the island;
/// - (c) an external display primary, island on the notch display: images touch the rounded edge and are cut;
/// - (a) island on a display without a notch: images are not drawn at all;
/// - (d) notch display primary, island on an external display (DynamicLake's Target Display): images are not drawn there either.
/// Text is drawn and placed right in all four, so every doubt resolves to `.text`.
public enum IslandPlacement {
    /// One active display, in the global top-left coordinate space that window frames use.
    public struct Display: Equatable, Sendable {
        public var id: UInt32
        public var bounds: CGRect
        public var hasNotch: Bool

        public init(id: UInt32, bounds: CGRect, hasNotch: Bool) {
            self.id = id; self.bounds = bounds; self.hasNotch = hasNotch
        }
    }

    /// Where the island was found.
    public enum Island: String, Equatable, Sendable { case onPrimary = "yes", elsewhere = "no", notFound = "not found" }

    public struct Decision: Equatable, Sendable {
        public var style: CompactStyle
        public var primaryHasNotch: Bool
        public var island: Island
        public var displayCount: Int

        /// One line for `--check`: no ids, frames or names.
        public var reason: String {
            "primary display notch: \(primaryHasNotch ? "yes" : "no"), island on primary: \(island.rawValue), displays: \(displayCount)"
        }
    }

    /// An island window's top edge sits at its display's top: measured 6 pt above it (Y -6 on a display at Y 0), so within
    /// this many points counts.
    static let topTolerance: CGFloat = 12
    /// And it is centred on that display: measured exactly (a 988 pt window at X 1010 on a 3008 pt display), so within this
    /// many points counts. A window in the middle of the screen (Playground's Settings, 620 x 732) is not at the top.
    static let centreTolerance: CGFloat = 8

    /// The display an island-like window sits at the top of, or nil when the window is not one: its top within
    /// `topTolerance` of a display's top, picked by the window's horizontal centre, and centred on it within `centreTolerance`.
    static func islandDisplay(of window: CGRect, among displays: [Display]) -> Display? {
        let display = displays.first { display in
            display.bounds.minX <= window.midX && window.midX < display.bounds.maxX && abs(window.minY - display.bounds.minY) <= topTolerance
        }
        guard let display, abs(window.midX - display.bounds.midX) <= centreTolerance else { return nil }
        return display
    }

    /// `.symbols` only when the primary display has a notch and every island-like host window is on it. With no such window
    /// (the host hides it, draws differently, or the list is unavailable) only a Mac with that one display gets symbols: the
    /// island can be nowhere else there.
    public static func decide(primary: UInt32, displays: [Display], hostWindows: [CGRect]) -> Decision {
        let primaryHasNotch = displays.first { $0.id == primary }?.hasNotch ?? false
        let islands = hostWindows.compactMap { islandDisplay(of: $0, among: displays) }
        let island: Island = islands.isEmpty ? .notFound : islands.allSatisfy { $0.id == primary } ? .onPrimary : .elsewhere
        let symbols: Bool
        switch island {
        case .onPrimary: symbols = primaryHasNotch
        case .elsewhere: symbols = false
        case .notFound: symbols = primaryHasNotch && displays.count == 1 && displays.first?.id == primary
        }
        return Decision(style: symbols ? .symbols : .text, primaryHasNotch: primaryHasNotch, island: island, displayCount: displays.count)
    }
}
