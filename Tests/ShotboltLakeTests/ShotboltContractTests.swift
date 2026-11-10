import XCTest
@testable import ShotboltLakeCore

/// What the plugin asks of Shotbolt, checked against the `shotbolt://` commands Shotbolt 1.2.4 to 1.3.0 accept and what their
/// Settings show. When Shotbolt's commands change, these lists are the place to say so.
final class ShotboltContractTests: XCTestCase {
    /// The commands without a capture that Shotbolt answers (1.2.4 to 1.3.0).
    static let simpleCommands: Set<String> = [
        "capture-area", "capture-window", "capture-fullscreen", "record-screen", "capture-text", "scrolling-capture", "record-gif",
        "pause-recording", "capture-area-timer", "open-history", "open-settings", "stop-recording",
    ]
    /// The commands on one capture, by the name before `-capture`; each takes `?id=<capture id>`, `keep` also `&on=1|0`.
    static let captureCommands: Set<String> = ["copy", "open", "pin", "reveal", "copy-text", "ai-copy", "keep"]
    /// The command Shotbolt still carries out with "Let other apps control Shotbolt" off. Any other one is turned down then.
    static let allowedWhenSwitchOff: Set<String> = ["open-settings"]

    /// Every action, once. `index` has no default, so a new action does not compile until it is listed, and the count check
    /// fails until it is in `all`.
    static func everyAction(_ id: UUID) -> [PluginAction] {
        func index(_ action: PluginAction) -> Int {
            switch action {
            case .captureArea: 0
            case .captureWindow: 1
            case .captureFullscreen: 2
            case .recordScreen: 3
            case .openHistory: 4
            case .captureText: 5
            case .scrollingCapture: 6
            case .recordGIF: 7
            case .selfTimer: 8
            case .pauseRecording: 9
            case .stopRecording: 10
            case .copy: 11
            case .open: 12
            case .pin: 13
            case .reveal: 14
            case .copyText: 15
            case .aiCopy: 16
            case .keep(_, true): 17
            case .keep(_, false): 18
            case .focus: 19
            case .toggleMore: 20
            case .launchShotbolt: 21
            case .getShotbolt: 22
            case .openSettings: 23
            }
        }
        let all: [PluginAction] = [.captureArea, .captureWindow, .captureFullscreen, .recordScreen, .openHistory, .captureText,
                                   .scrollingCapture, .recordGIF, .selfTimer, .pauseRecording, .stopRecording, .copy(id), .open(id),
                                   .pin(id), .reveal(id), .copyText(id), .aiCopy(id), .keep(id, true), .keep(id, false), .focus(id),
                                   .toggleMore, .launchShotbolt, .getShotbolt, .openSettings]
        XCTAssertEqual(all.map(index).sorted(), Array(0...23), "every action listed once")
        return all
    }

    func testEveryCommandIsOneShotboltAcceptsWithItsParameters() throws {
        let id = UUID()
        for action in Self.everyAction(id) {
            XCTAssertEqual(PluginAction(actionID: action.actionID), action, "round trip of \(action.actionID)")
            guard let command = action.shotboltCommand else { continue }
            // A command is the link's host, and its parameters are the query.
            let url = try XCTUnwrap(URL(string: "shotbolt://" + command), command)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let name = try XCTUnwrap(url.host, command)
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            // A plain command is matched by its whole name: `scrolling-capture` also ends in "-capture" but takes no capture id.
            if Self.simpleCommands.contains(name) {
                XCTAssertTrue(query.isEmpty, "\(command) takes no parameters")
            } else {
                XCTAssertTrue(name.hasSuffix("-capture"), "\(command) is not a Shotbolt command")
                let base = String(name.dropLast("-capture".count))
                XCTAssertTrue(Self.captureCommands.contains(base), command)
                XCTAssertEqual(query["id"].flatMap(UUID.init(uuidString:)), id, command)
                if base == "keep" {
                    XCTAssertEqual(Set(query.keys), ["id", "on"], command)
                    XCTAssertTrue(["1", "0"].contains(query["on"]), command)
                } else {
                    XCTAssertEqual(Set(query.keys), ["id"], command)
                }
            }
        }
        XCTAssertEqual(PluginAction.keep(id, true).shotboltCommand, "keep-capture?id=\(id.uuidString)&on=1")
        XCTAssertEqual(PluginAction.keep(id, false).shotboltCommand, "keep-capture?id=\(id.uuidString)&on=0")
        XCTAssertEqual(PluginAction.selfTimer.shotboltCommand, "capture-area-timer", "the area after Settings' delay")
    }

    /// With the switch off, the one button the lake offers is one Shotbolt still answers then.
    func testTheDisabledNoticeOffersOnlyWhatWorksWithTheSwitchOff() throws {
        let message = Surfaces.message(for: .disabled)
        let command = try XCTUnwrap(message.action?.shotboltCommand)
        XCTAssertTrue(Self.allowedWhenSwitchOff.contains(command))
    }

    /// Shotbolt writes the feed with `enabled: false` when the switch is off, in every version from 1.2.4. The notice names the
    /// switch and no pane: it was under Advanced up to 1.2.5 and is under Workflows from 1.3.
    func testTheDisabledNoticeIsTrueForEveryShotboltWithTheFeed() throws {
        for version in ["1.2.4", "1.2.5", "1.3.0"] {
            // What the feed holds with the switch off: no captures, no recording, no last take, `pro` false.
            let file = """
            {"app":{"build":"18","pid":7,"version":"\(version)"},"captures":[],"enabled":false,"pro":false,"schemaVersion":1,
             "updatedAt":"2026-11-10T09:00:00.125Z"}
            """
            let status = try ShotboltStatus.decode(Data(file.utf8))
            XCTAssertEqual(status.app.version, version)
            let state = ShotboltState.resolve(installed: true, runningPIDs: [7], launchedAt: nil, status: status, now: Date())
            XCTAssertEqual(state, .disabled, version)
            let message = Surfaces.message(for: state)
            XCTAssertTrue(message.detail.contains("Let other apps control Shotbolt"), message.detail)
            for pane in ["Advanced", "Workflows"] { XCTAssertFalse(message.detail.contains(pane), "\(version): \(message.detail)") }
            XCTAssertEqual(message.action, .openSettings)
            XCTAssertFalse(message.title.contains("\u{2014}") || message.detail.contains("\u{2014}"), "no em-dashes")
            // One short line in the lake and in DynaGlance.
            XCTAssertLessThanOrEqual(message.detail.count, 60)
        }
    }

    func menu(_ kind: ShotboltStatus.Capture.Kind, pro: Bool, kept: Bool = false) -> [(title: String, symbol: String, actionID: String)] {
        let capture = ShotboltStatus.Capture(id: UUID(), kind: kind, createdAt: Date(), file: "/tmp/x", width: 10, height: 10, kept: kept)
        return Surfaces.contextMenu(capture, pro: pro).map {
            ($0["title"] as? String ?? "", $0["systemImage"] as? String ?? "", $0["actionID"] as? String ?? "")
        }
    }

    /// History's names and symbols in 1.3, in History's order; Copy Text, AI-safe Copy and Pin to Screen only where Shotbolt
    /// does them (it refuses Copy Text and AI-safe Copy on a video or GIF); AI-safe Copy only with Pro.
    func testTheMenuUsesHistorysNamesAndOnlyOffersWhatShotboltDoesForThatKind() {
        XCTAssertEqual(menu(.screenshot, pro: true).map(\.title),
                       ["Annotate", "Copy", "Copy Text", "AI-safe Copy", "Pin to Screen", "Keep", "Show in Finder"])
        XCTAssertEqual(menu(.screenshot, pro: false).map(\.title), ["Annotate", "Copy", "Copy Text", "Pin to Screen", "Keep", "Show in Finder"])
        XCTAssertEqual(menu(.screenshot, pro: true).first?.symbol, "pencil.and.scribble", "1.3's one Annotate symbol")
        XCTAssertEqual(menu(.screenshot, pro: true)[3].symbol, "wand.and.sparkles", "AI-safe Copy's symbol in Shotbolt")
        XCTAssertEqual(menu(.video, pro: true, kept: true).map(\.title), ["Edit Video", "Copy", "Stop Keeping", "Show in Finder"])
        XCTAssertEqual(menu(.gif, pro: true).map(\.title), ["Open", "Copy", "Keep", "Show in Finder"])
        for kind in [ShotboltStatus.Capture.Kind.video, .gif] {
            let ids = menu(kind, pro: true).map(\.actionID)
            XCTAssertFalse(ids.contains { $0.hasPrefix("copy-text:") || $0.hasPrefix("ai-copy:") || $0.hasPrefix("pin:") }, "\(kind)")
        }
    }

    /// The toolbar uses Shotbolt 1.3's own symbols for the same commands (its menu bar menu and shortcuts).
    func testTheToolbarUsesShotboltsSymbols() {
        func symbols(moreOpen: Bool) -> [String: String] {
            let children = Surfaces.toolbar(moreOpen: moreOpen)["children"] as? [JSON] ?? []
            return Dictionary(uniqueKeysWithValues: children.compactMap { child -> (String, String)? in
                guard let action = (child["actionID"] as? String).flatMap(PluginAction.init(actionID:)), action != .toggleMore,
                      let command = action.shotboltCommand, let symbol = child["systemImage"] as? String else { return nil }
                return (command, symbol)
            })
        }
        XCTAssertEqual(symbols(moreOpen: false), [
            "capture-area": "rectangle.dashed", "capture-window": "macwindow", "capture-fullscreen": "rectangle.expand.diagonal",
            "record-screen": "record.circle", "open-history": "square.grid.2x2",
        ])
        XCTAssertEqual(symbols(moreOpen: true), [
            "capture-text": "text.viewfinder", "scrolling-capture": "arrow.up.and.down.text.horizontal", "record-gif": "photo.stack",
            "capture-area-timer": "timer.square", "open-history": "square.grid.2x2",
        ])
    }

    /// The main row fits the big lake's base width only with the toolbar's own 4 pt gap (checked live, Playground 1.2).
    func testTheToolbarKeepsItsTightGapAndShortTitles() {
        let toolbar = Surfaces.toolbar(moreOpen: false)
        XCTAssertEqual(toolbar["spacing"] as? Double, 4)
        let titles = (toolbar["children"] as? [JSON] ?? []).filter { $0["shape"] as? String == "roundedRect" }.compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["Area", "Window", "Fullscreen", "Record"])
    }

    /// The notice's icon is rounded in the lake layout; the basic lake (without `lakeLayout`) gets no `cornerRadius`.
    func testTheNoticeIconIsRoundedOnlyInTheLakeLayout() {
        func icons(_ value: Any) -> [JSON] {
            if let object = value as? JSON {
                return (object["source"] as? String == "appIcon" ? [object] : []) + object.values.flatMap(icons)
            }
            return (value as? [Any])?.flatMap(icons) ?? []
        }
        for state in [ShotboltState.notInstalled, .notRunning, .needsUpdate, .pluginOutdated, .disabled] {
            let lake = icons(Surfaces.lake(state, context: .init(now: Date()), features: HostFeatures()))
            XCTAssertEqual(lake.count, 2, "the lake and DynaGlance")
            XCTAssertTrue(lake.allSatisfy { ($0["cornerRadius"] as? NSNumber)?.doubleValue == 8 && ($0["size"] as? NSNumber)?.doubleValue == 36 }, "\(state)")
            let basic = icons(Surfaces.lake(state, context: .init(now: Date()), features: HostFeatures(lake: true, lakeLayout: false)))
            XCTAssertFalse(basic.isEmpty)
            XCTAssertTrue(basic.allSatisfy { $0["cornerRadius"] == nil }, "\(state)")
        }
    }

    func testTheBandOffersCopyTextOnlyForAScreenshot() {
        func titles(_ kind: ShotboltStatus.Capture.Kind) -> [String] {
            let capture = ShotboltStatus.Capture(id: UUID(), kind: kind, createdAt: Date(), file: "/tmp/x", width: 10, height: 10)
            let status = ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), captures: [capture], updatedAt: Date())
            let band = Surfaces.band(capture, status: status, context: .init(now: Date()))
            func find(_ value: Any) -> JSON? {
                if let object = value as? JSON {
                    if object["id"] as? String == "band-actions" { return object }
                    return object.values.lazy.compactMap(find).first
                }
                return (value as? [Any])?.lazy.compactMap(find).first
            }
            return (find(band)?["children"] as? [JSON] ?? []).compactMap { $0["title"] as? String }
        }
        XCTAssertEqual(titles(.screenshot), ["Copy", "Annotate", "Copy Text"])
        XCTAssertEqual(titles(.video), ["Copy", "Edit Video", "Show in Finder"])
        XCTAssertEqual(titles(.gif), ["Copy", "Open", "Show in Finder"])
    }
}
