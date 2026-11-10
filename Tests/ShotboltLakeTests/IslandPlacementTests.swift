import XCTest
@testable import ShotboltLakeCore

/// Where the island is, and so which compact style: symbols only with the island on a primary display that has a notch.
final class IslandPlacementTests: XCTestCase {
    // The arrangement measured live: an external 4K primary at the origin, the MacBook to its left and lower, a second
    // external to the right.
    let external = IslandPlacement.Display(id: 3, bounds: CGRect(x: 0, y: 0, width: 3008, height: 1692), hasNotch: false)
    let macBook = IslandPlacement.Display(id: 1, bounds: CGRect(x: -1496, y: 1080, width: 1496, height: 967), hasNotch: true)
    let second = IslandPlacement.Display(id: 5, bounds: CGRect(x: 3008, y: 0, width: 3008, height: 1692), hasNotch: false)

    /// The island window as measured: 988 x 524, centred, its top 6 pt above the display's top.
    func island(on display: IslandPlacement.Display, dx: CGFloat = 0, dy: CGFloat = -6) -> CGRect {
        CGRect(x: display.bounds.midX - 494 + dx, y: display.bounds.minY + dy, width: 988, height: 524)
    }

    func style(primary: IslandPlacement.Display, _ displays: [IslandPlacement.Display], windows: [CGRect]) -> CompactStyle {
        IslandPlacement.decide(primary: primary.id, displays: displays, hostWindows: windows).style
    }

    func testSymbolsOnlyWithTheIslandOnAPrimaryDisplayWithANotch() {
        let alone = IslandPlacement.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true)
        XCTAssertEqual(style(primary: alone, [alone], windows: [island(on: alone)]), .symbols, "(b) a MacBook on its own")
        XCTAssertEqual(style(primary: macBook, [macBook, external, second], windows: [island(on: macBook)]), .symbols,
                       "(b') the notch display primary, externals too, the island on the notch")
        XCTAssertEqual(style(primary: external, [external, macBook, second], windows: [island(on: macBook)]), .text,
                       "(c) an external primary, the island on the notch display")
        XCTAssertEqual(style(primary: external, [external, macBook, second], windows: [island(on: external)]), .text,
                       "(a) the island on a display without a notch")
        XCTAssertEqual(style(primary: macBook, [macBook, external, second], windows: [island(on: external)]), .text,
                       "(d) the notch display primary, the island on an external display")
        XCTAssertEqual(style(primary: macBook, [macBook, external], windows: [island(on: macBook), island(on: external)]), .text,
                       "islands on two displays")
    }

    func testWithoutAnIslandOnlyASingleNotchDisplayGetsSymbols() {
        let alone = IslandPlacement.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true)
        let none = IslandPlacement.decide(primary: 1, displays: [alone], hostWindows: [])
        XCTAssertEqual(none.style, .symbols)
        XCTAssertEqual(none.island, .notFound)
        XCTAssertEqual(style(primary: macBook, [macBook, external], windows: []), .text, "several displays: it could be anywhere")
        XCTAssertEqual(style(primary: external, [external], windows: []), .text, "one display without a notch")
        XCTAssertEqual(IslandPlacement.decide(primary: 9, displays: [macBook], hostWindows: []).style, .text, "a primary not in the list")
        XCTAssertEqual(IslandPlacement.decide(primary: 1, displays: [], hostWindows: []).style, .text, "no displays at all")
    }

    func testOnlyACentredWindowAtTheTopIsAnIsland() {
        let settings = CGRect(x: macBook.bounds.midX - 310, y: macBook.bounds.midY - 366, width: 620, height: 732)
        XCTAssertNil(IslandPlacement.islandDisplay(of: settings, among: [macBook]), "a Settings window in the middle")
        XCTAssertNil(IslandPlacement.islandDisplay(of: island(on: macBook, dx: 40), among: [macBook]), "at the top but not centred")
        XCTAssertNil(IslandPlacement.islandDisplay(of: island(on: macBook, dy: 30), among: [macBook]), "centred but below the top")
        XCTAssertEqual(IslandPlacement.islandDisplay(of: island(on: macBook), among: [macBook]), macBook, "6 pt above the top counts")
        XCTAssertEqual(IslandPlacement.islandDisplay(of: island(on: macBook, dx: 7, dy: 11), among: [macBook]), macBook, "within the tolerances")
        // A Settings window on the notch display does not make an island there: the external island still decides.
        XCTAssertEqual(style(primary: macBook, [macBook, external], windows: [settings, island(on: external)]), .text)
        XCTAssertEqual(style(primary: macBook, [macBook, external], windows: [settings, island(on: macBook)]), .symbols)
    }

    func testDisplaysAtNegativeCoordinates() {
        // The notch display left of and below the external primary (X -1496, Y 1080), and one above it at negative Y.
        let above = IslandPlacement.Display(id: 7, bounds: CGRect(x: -400, y: -1440, width: 2560, height: 1440), hasNotch: false)
        XCTAssertEqual(IslandPlacement.islandDisplay(of: island(on: macBook), among: [external, macBook, above]), macBook)
        XCTAssertEqual(IslandPlacement.islandDisplay(of: island(on: above), among: [external, macBook, above]), above)
        let notchPrimary = IslandPlacement.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true)
        let left = IslandPlacement.Display(id: 4, bounds: CGRect(x: -2560, y: -300, width: 2560, height: 1440), hasNotch: false)
        XCTAssertEqual(style(primary: notchPrimary, [notchPrimary, left], windows: [island(on: notchPrimary)]), .symbols)
        XCTAssertEqual(style(primary: notchPrimary, [notchPrimary, left], windows: [island(on: left)]), .text)
    }

    func testTheReasonLineSaysNoIdsOrFrames() {
        let decision = IslandPlacement.decide(primary: 3, displays: [external, macBook, second], hostWindows: [island(on: external)])
        XCTAssertEqual(decision.reason, "primary display notch: no, island on primary: yes, displays: 3")
    }
}
