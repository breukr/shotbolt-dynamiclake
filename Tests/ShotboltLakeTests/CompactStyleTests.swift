import XCTest
@testable import ShotboltLakeCore

/// The compact activity in both styles: symbols where the primary display has a notch, text everywhere else.
final class CompactStyleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let blank = "\u{2800}"

    func status(_ recording: ShotboltStatus.Recording?, captures: [ShotboltStatus.Capture] = []) -> ShotboltStatus {
        ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), recording: recording, captures: captures, updatedAt: now)
    }

    func compact(_ command: JSON?) -> JSON { (command?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON ?? [:] }

    /// A slot as "type text tint", or "type" for anything that is not text.
    func describe(_ slot: Any?) -> String? {
        guard let slot = slot as? JSON else { return nil }
        let type = slot["type"] as? String ?? "?"
        guard type == "text" else { return type == "image" ? "image \(slot["systemImage"] as? String ?? "asset")" : type }
        XCTAssertEqual(slot["style"] as? String, "numeric")
        return "text \(slot["text"] as? String ?? "") \(slot["tint"] as? String ?? "")"
    }

    func slots(_ recording: ShotboltStatus.Recording, style: CompactStyle, features: HostFeatures = HostFeatures()) -> [String?] {
        let command = Surfaces.recordingActivity(status(recording), now: now, create: true, features: features, style: style)
        return [describe(compact(command)["leftSlot"]), describe(compact(command)["rightSlot"])]
    }

    func testTheTextStyleDrawsEveryMarkAsTextAfterTwoBlanks() {
        let lead = blank + blank
        XCTAssertEqual(slots(.init(state: .recording, kind: .video, elapsed: 42), style: .text),
                       ["text \(lead)\u{2B24} red", "text 0:42\(lead) red"])
        XCTAssertEqual(slots(.init(state: .paused, kind: .video, elapsed: 43.8), style: .text),
                       ["text \(lead)\u{2759}\u{2759} gray", "text 0:43\(lead) white"])
        XCTAssertEqual(slots(.init(state: .starting, kind: .video, elapsed: 0, countdownEndsAt: now.addingTimeInterval(3)), style: .text),
                       ["text \(lead)\u{25EF} red", "text 0:03\(lead) white"])
        XCTAssertEqual(slots(.init(state: .starting, kind: .gif, elapsed: 0), style: .text), ["text \(lead)\u{25EF} red", nil],
                       "no countdown, no clock: no right slot")
        for state in [ShotboltStatus.Recording.State.saving, .converting] {
            XCTAssertEqual(slots(.init(state: state, kind: .gif, elapsed: 9), style: .text), ["text \(lead)\u{22EF} gray", nil],
                           "no progress ring: it is not drawn there")
        }
        let video = ShotboltStatus.Capture(id: UUID(), kind: .video, createdAt: now, file: "/tmp/a.mov", width: 1, height: 1, duration: 5)
        let saved = compact(Surfaces.savedActivity(video, assetID: "thumb-1", create: false, features: HostFeatures(), style: .text))
        XCTAssertEqual([describe(saved["leftSlot"]), describe(saved["rightSlot"])], ["text \(lead)\u{2713} green", nil],
                       "the check alone, without the picture")
    }

    func testAnHourLongClockGetsOneBlank() {
        XCTAssertEqual(slots(.init(state: .paused, kind: .video, elapsed: 3725), style: .text)[1], "text 1:02:05\(blank) white")
        XCTAssertEqual(slots(.init(state: .recording, kind: .video, elapsed: 599), style: .text)[1], "text 9:59\(blank)\(blank) red")
        XCTAssertEqual(slots(.init(state: .recording, kind: .video, elapsed: 600), style: .text)[1], "text 10:00\(blank)\(blank) red",
                       "five characters still get two")
    }

    func testTheSymbolsStyleKeepsTodaysMarksAndAClockWithoutBlanks() {
        XCTAssertEqual(slots(.init(state: .recording, kind: .video, elapsed: 42), style: .symbols), ["image record.circle.fill", "text 0:42 red"])
        XCTAssertEqual(slots(.init(state: .paused, kind: .video, elapsed: 3725), style: .symbols), ["status", "text 1:02:05 white"])
        XCTAssertEqual(slots(.init(state: .starting, kind: .video, elapsed: 0), style: .symbols), ["image record.circle", "progress"])
        XCTAssertEqual(slots(.init(state: .saving, kind: .video, elapsed: 9), style: .symbols), ["status", "progress"])
        let video = ShotboltStatus.Capture(id: UUID(), kind: .video, createdAt: now, file: "/tmp/a.mov", width: 1, height: 1)
        let saved = compact(Surfaces.savedActivity(video, assetID: "thumb-1", create: false, features: HostFeatures()))
        XCTAssertEqual([describe(saved["leftSlot"]), describe(saved["rightSlot"])], ["status", "image asset"])
    }

    /// Only the compact activity changes: the sneak peek and the side capsule are the same in both styles.
    func testOnlyTheCompactActivityFollowsTheStyle() {
        for recording in [ShotboltStatus.Recording(state: .recording, kind: .video, elapsed: 42), .init(state: .paused, kind: .gif, elapsed: 3),
                          .init(state: .saving, kind: .video, elapsed: 3)] {
            let text = Surfaces.recordingActivity(status(recording), now: now, create: true, features: HostFeatures(), style: .text)!
            let symbols = Surfaces.recordingActivity(status(recording), now: now, create: true, features: HostFeatures(), style: .symbols)!
            for surface in ["sneakPeek", "extraLiveActivity"] {
                XCTAssertEqual((text["surfaces"] as! JSON)[surface] as? NSDictionary, (symbols["surfaces"] as! JSON)[surface] as? NSDictionary, surface)
            }
            XCTAssertEqual(text["size"] as? String, "large")
        }
    }

    func testAHostWithoutNumericTextIgnoresTheTextStyle() {
        let plain = HostFeatures(numericText: false)
        for recording in [ShotboltStatus.Recording(state: .recording, kind: .video, elapsed: 42), .init(state: .saving, kind: .video, elapsed: 3)] {
            let text = Surfaces.recordingActivity(status(recording), now: now, create: true, features: plain, style: .text)! as NSDictionary
            let symbols = Surfaces.recordingActivity(status(recording), now: now, create: true, features: plain, style: .symbols)! as NSDictionary
            XCTAssertEqual(text, symbols)
        }
        XCTAssertEqual(slots(.init(state: .recording, kind: .video, elapsed: 42), style: .text, features: plain)[1], "timer",
                       "its own timer, as before")
        var planner = ActivityPlanner()
        let take = ShotboltState.ready(status(.init(state: .recording, kind: .video, elapsed: 4)))
        _ = planner.update(take, settings: PluginSettings(), features: plain, now: now, style: .symbols, assetID: { _ in nil })
        XCTAssertEqual(planner.update(take, settings: PluginSettings(), features: plain, now: now, style: .text, assetID: { _ in nil }).count, 0,
                       "a style change means nothing to such a host")
    }

    /// A lid closed mid-take: one update in the new style, and the clock ticks on in it.
    func testAStyleChangeMidTakeSendsOneUpdateAndTicksOnInTheNewStyle() {
        var planner = ActivityPlanner()
        let take = ShotboltState.ready(status(.init(state: .recording, kind: .video, elapsed: 41.6)))
        let created = planner.update(take, settings: PluginSettings(), features: HostFeatures(), now: now, style: .symbols, assetID: { _ in nil })
        XCTAssertEqual(created.map { $0["type"] as? String }, ["create"])
        let changed = planner.update(take, settings: PluginSettings(), features: HostFeatures(), now: now.addingTimeInterval(0.2), style: .text,
                                     assetID: { _ in nil })
        XCTAssertEqual(changed.map { $0["type"] as? String }, ["update"], "an update, not a new activity")
        XCTAssertEqual(describe(compact(changed.first)["leftSlot"]), "text \(blank)\(blank)\u{2B24} red")
        XCTAssertEqual(describe(compact(changed.first)["rightSlot"]), "text 0:41\(blank)\(blank) red")
        let tick = planner.tick(now: now.addingTimeInterval(0.4))
        XCTAssertEqual(tick.count, 1)
        XCTAssertEqual(describe(compact(tick.first)["leftSlot"]), "text \(blank)\(blank)\u{2B24} red", "both slots, in the new style")
        XCTAssertEqual(describe(compact(tick.first)["rightSlot"]), "text 0:42\(blank)\(blank) red")
        XCTAssertEqual(planner.update(take, settings: PluginSettings(), features: HostFeatures(), now: now.addingTimeInterval(0.5), style: .text,
                                      assetID: { _ in nil }).count, 0, "the same style again sends nothing")
    }

    func testTheSavedTakeFollowsAStyleChange() {
        var planner = ActivityPlanner()
        let settings = PluginSettings()
        _ = planner.update(.ready(status(.init(state: .recording, kind: .video, elapsed: 4))), settings: settings, features: HostFeatures(),
                           now: now, style: .text, assetID: { _ in nil })
        let video = ShotboltStatus.Capture(id: UUID(), kind: .video, createdAt: now, file: "/tmp/a.mov", width: 1, height: 1)
        let saved = planner.update(.ready(status(nil, captures: [video])), settings: settings, features: HostFeatures(), now: now.addingTimeInterval(1),
                                   style: .text, assetID: { _ in "thumb-1" })
        XCTAssertEqual(describe(compact(saved.first)["leftSlot"]), "text \(blank)\(blank)\u{2713} green")
        let changed = planner.update(.ready(status(nil, captures: [video])), settings: settings, features: HostFeatures(),
                                     now: now.addingTimeInterval(2), style: .symbols, assetID: { _ in "thumb-1" })
        XCTAssertEqual(changed.map { $0["type"] as? String }, ["update"])
        XCTAssertEqual([describe(compact(changed.first)["leftSlot"]), describe(compact(changed.first)["rightSlot"])], ["status", "image asset"])
    }

    final class StyledLink: ShotboltLink {
        var state: ShotboltState
        var style: CompactStyle = .symbols
        init(_ state: ShotboltState) { self.state = state }
        func currentState(now: Date) -> ShotboltState { state }
        func send(_ command: String) {}
        func launchShotbolt() {}
        func openWebsite() {}
        func fileReady(_ path: String) -> Bool { true }
        func subscribe() {}
        func compactStyle() -> CompactStyle { style }
    }

    /// The loop asks for the style every tick and replans when it changed.
    func testThePluginFollowsTheLinksStyle() throws {
        let link = StyledLink(.ready(status(.init(state: .recording, kind: .video, elapsed: 3))))
        var output: [JSON] = []
        let plugin = Plugin(link: link, features: HostFeatures(), loadSettings: { PluginSettings() }) { output.append($0) }
        try plugin.tick(now: now)
        XCTAssertEqual(describe(compact(output.first { $0["type"] as? String == "create" })["leftSlot"]), "image record.circle.fill")
        output.removeAll()
        link.style = .text
        try plugin.tick(now: now.addingTimeInterval(0.1))
        let update = output.first { $0["type"] as? String == "update" }
        XCTAssertEqual(describe(compact(update)["leftSlot"]), "text \(blank)\(blank)\u{2B24} red")
    }
}
