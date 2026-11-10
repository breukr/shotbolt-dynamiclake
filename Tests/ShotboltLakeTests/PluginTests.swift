import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShotboltLakeCore

final class StatusTests: XCTestCase {
    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/status-v1.json")
    }

    func testDecodesTheAppsContractFixture() throws {
        let status = try ShotboltStatus.decode(Data(contentsOf: Self.fixture))
        XCTAssertEqual(status.schemaVersion, 1)
        XCTAssertEqual(status.app, .init(version: "1.3.0", build: "15", pid: 4242))
        XCTAssertEqual(status.recording, .init(state: .recording, kind: .video, elapsed: 75.5))
        XCTAssertEqual(status.captures.map(\.kind), [.screenshot, .video])
        XCTAssertEqual(status.captures[0].title, "Pricing table")
        XCTAssertNil(status.captures[1].thumbnail)
        XCTAssertEqual(status.updatedAt.timeIntervalSince1970, 1_793_102_475.5, accuracy: 0.001)
        XCTAssertEqual(status.recordingStart()!.timeIntervalSince1970, 1_793_102_400, accuracy: 0.001)
        XCTAssertEqual(status.captures[0].app, "Safari")
        XCTAssertEqual(status.captures[0].category, "web")
        XCTAssertTrue(status.captures[0].kept)
        XCTAssertEqual(status.captures[1].duration, 42.5)
        XCTAssertFalse(status.captures[1].kept)
        XCTAssertTrue(status.pro)
        XCTAssertEqual(status.lastTake?.outcome, .saved)
        XCTAssertEqual(status.lastTake?.capture, status.captures[1].id)
    }

    func testOneBadCaptureIsSkippedNotTheWholeFile() throws {
        var text = try String(contentsOf: Self.fixture, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"createdAt\" : \"2026-10-27T12:00:00.000Z\"", with: "\"createdAt\" : \"yesterday\"")
        let status = try ShotboltStatus.decode(Data(text.utf8))
        XCTAssertEqual(status.captures.map(\.kind), [.video])
    }

    func testValuesFromANewerShotboltDoNotBreakTheFile() throws {
        var text = try String(contentsOf: Self.fixture, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"kind\" : \"video\",\n      \"saved\"", with: "\"kind\" : \"hologram\",\n      \"saved\"")
        text = text.replacingOccurrences(of: "\"state\" : \"recording\"", with: "\"state\" : \"rewinding\"")
        let status = try ShotboltStatus.decode(Data(text.utf8))
        XCTAssertEqual(status.captures[1].kind, .other)
        XCTAssertEqual(status.recording?.state, .other)
    }

    func testResolve() throws {
        let status = try ShotboltStatus.decode(Data(contentsOf: Self.fixture))
        let now = Date()
        XCTAssertEqual(ShotboltState.resolve(installed: false, runningPIDs: [], launchedAt: nil, status: nil, now: now), .notInstalled)
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [], launchedAt: nil, status: status, now: now), .notRunning)
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [4242], launchedAt: nil, status: status, now: now), .ready(status))
        // A file left by an earlier launch: a Shotbolt that started a moment ago has not written yet, an older one never will.
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [99], launchedAt: now.addingTimeInterval(-2), status: status, now: now),
                       .notRunning)
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [99], launchedAt: now.addingTimeInterval(-60), status: status, now: now),
                       .needsUpdate)
        var off = status; off.enabled = false
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [4242], launchedAt: nil, status: off, now: now), .disabled)
        var newer = status; newer.schemaVersion = 2
        XCTAssertEqual(ShotboltState.resolve(installed: true, runningPIDs: [4242], launchedAt: nil, status: newer, now: now), .pluginOutdated)
    }

    func testFramesRoundTripAndWaitForTheRest() throws {
        let a = try Frames.encode(["type": "lakeOpened"], maxSize: 1024)
        let b = try Frames.encode(["type": "action", "actionID": "capture-area"], maxSize: 1024)
        var buffer = a + b.prefix(6)
        XCTAssertEqual(try Frames.decode(&buffer, maxSize: 1024).map { $0["type"] as? String }, ["lakeOpened"])
        buffer += b.dropFirst(6)
        XCTAssertEqual(try Frames.decode(&buffer, maxSize: 1024).first?["actionID"] as? String, "capture-area")
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertThrowsError(try Frames.encode(["text": String(repeating: "x", count: 2000)], maxSize: 1024))
        var huge = Data([0x00, 0x10, 0x00, 0x00, 0x7B])
        XCTAssertThrowsError(try Frames.decode(&huge, maxSize: 1024), "a frame over the limit ends the connection")
    }

    func testActionsRoundTripAndMapToShotboltCommands() {
        let id = UUID()
        let actions: [PluginAction] = [.captureArea, .captureWindow, .captureFullscreen, .recordScreen, .openHistory, .pauseRecording,
                                       .stopRecording, .copy(id), .open(id), .pin(id), .reveal(id), .launchShotbolt, .getShotbolt, .openSettings]
        for action in actions { XCTAssertEqual(PluginAction(actionID: action.actionID), action, action.actionID) }
        XCTAssertEqual(PluginAction.copy(id).shotboltCommand, "copy-capture?id=\(id.uuidString)")
        XCTAssertEqual(PluginAction.stopRecording.shotboltCommand, "stop-recording")
        XCTAssertNil(PluginAction.launchShotbolt.shotboltCommand)
        XCTAssertNil(PluginAction(actionID: "copy:not-a-uuid"))
        XCTAssertNil(PluginAction(actionID: "rm -rf"))
    }

    func testWords() {
        let now = Date()
        XCTAssertEqual(Surfaces.relativeTime(now.addingTimeInterval(-20), now: now), "Just now")
        XCTAssertEqual(Surfaces.relativeTime(now.addingTimeInterval(-125), now: now), "2 min ago")
        XCTAssertEqual(Surfaces.duration(75.9), "1:16", "rounded, like Quick Access")
        XCTAssertEqual(Surfaces.duration(3725), "1:02:05")
        let untitled = ShotboltStatus.Capture(id: UUID(), kind: .gif, createdAt: now, file: "/x.gif", width: 800, height: 600)
        XCTAssertEqual(Surfaces.title(of: untitled), "GIF")
        XCTAssertEqual(Surfaces.subtitle(of: untitled, now: now), "Just now", "the title already says GIF; no pixel size")
        var timed = untitled; timed.duration = 8.2
        XCTAssertEqual(Surfaces.subtitle(of: timed, now: now), "0:08 · Just now")
        var titled = untitled; titled.title = "Onboarding\nflow"
        XCTAssertEqual(Surfaces.title(of: titled), "Onboarding flow")
        XCTAssertEqual(Surfaces.subtitle(of: titled, now: now), "GIF · Just now")
        var fromApp = ShotboltStatus.Capture(id: UUID(), kind: .video, createdAt: now.addingTimeInterval(-300), file: "/x.mov", width: 1, height: 1,
                                             duration: 65, app: "Keynote", category: "design")
        XCTAssertEqual(Surfaces.title(of: fromApp), "Keynote", "the app before the kind of content")
        XCTAssertEqual(Surfaces.subtitle(of: fromApp, now: now), "Video · 1:05 · 5 min ago")
        fromApp.app = "  "
        XCTAssertEqual(Surfaces.title(of: fromApp), "Design")
        fromApp.category = "something-new"
        XCTAssertEqual(Surfaces.title(of: fromApp), "Video", "an unknown category is not shown")
    }
}

final class PlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let features = HostFeatures()

    func status(_ recording: ShotboltStatus.Recording? = nil, captures: [ShotboltStatus.Capture] = [], at time: Date? = nil) -> ShotboltState {
        .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 1), recording: recording, captures: captures,
                              updatedAt: time ?? now))
    }

    func capture(_ kind: ShotboltStatus.Capture.Kind, at time: Date) -> ShotboltStatus.Capture {
        ShotboltStatus.Capture(id: UUID(), kind: kind, createdAt: time, file: "/tmp/x", width: 10, height: 10)
    }

    func types(_ commands: [JSON]) -> [String] {
        commands.map { "\($0["type"] as? String ?? "?") \($0["activityID"] as? String ?? "")" }
    }

    func testATakeFromCountdownToSaved() {
        var planner = ActivityPlanner()
        let old = capture(.screenshot, at: now.addingTimeInterval(-600))
        let settings = PluginSettings()
        func step(_ state: ShotboltState, _ time: TimeInterval) -> [String] {
            types(planner.update(state, settings: settings, features: features, now: now.addingTimeInterval(time), assetID: { _ in nil }))
        }
        XCTAssertEqual(step(status(captures: [old]), 0), [])
        XCTAssertEqual(step(status(.init(state: .starting, kind: .video, elapsed: 0, countdownEndsAt: now.addingTimeInterval(3)), captures: [old]), 1),
                       ["create recording"])
        XCTAssertEqual(step(status(.init(state: .recording, kind: .video, elapsed: 0), captures: [old], at: now.addingTimeInterval(4)), 4),
                       ["update recording"])
        // The same take a moment later: the timer runs by itself, nothing is resent.
        XCTAssertEqual(step(status(.init(state: .recording, kind: .video, elapsed: 6), captures: [old], at: now.addingTimeInterval(10)), 10), [])
        XCTAssertEqual(step(status(.init(state: .paused, kind: .video, elapsed: 8), captures: [old], at: now.addingTimeInterval(12)), 12),
                       ["update recording"])
        XCTAssertEqual(step(status(.init(state: .saving, kind: .video, elapsed: 8), captures: [old]), 20), ["update recording"])
        // The take left the feed before its file reached History: still "saving", then "saved".
        XCTAssertEqual(step(status(captures: [old]), 21), [])
        let video = capture(.video, at: now.addingTimeInterval(21))
        let saved = planner.update(status(captures: [video, old]), settings: settings, features: features, now: now.addingTimeInterval(22),
                                   assetID: { _ in nil })
        XCTAssertEqual(types(saved), ["update recording"])
        XCTAssertEqual(saved.first?["presentSneakPeek"] as? Int, 3)
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(23))), [])
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(22 + ActivityPlanner.savedDuration))), ["dismiss recording"])
    }

    func clockText(_ command: JSON?) -> String? {
        (((command?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON)?["rightSlot"] as? JSON)?["text"] as? String
    }

    func clockTint(_ command: JSON?) -> String? {
        (((command?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON)?["rightSlot"] as? JSON)?["tint"] as? String
    }

    func testTheCompactClockTicksOncePerSecondAndStopsWhenPaused() {
        var planner = ActivityPlanner()
        let created = planner.update(status(.init(state: .recording, kind: .video, elapsed: 41.6)), settings: PluginSettings(),
                                     features: features, now: now, assetID: { _ in nil })
        XCTAssertEqual(clockText(created.first), "0:41\u{2800}\u{2800}", "short numeric text, ended by two blanks that keep it off the edge")
        XCTAssertEqual(clockTint(created.first), "red", "red while the take records")
        XCTAssertEqual(planner.nextDeadline, now.addingTimeInterval(0.4))
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(0.3))), [], "not its second yet")
        let next = planner.tick(now: now.addingTimeInterval(0.4))
        XCTAssertEqual(types(next), ["update recording"])
        XCTAssertEqual(clockText(next.first), "0:42\u{2800}\u{2800}")
        XCTAssertEqual(clockTint(next.first), "red")
        XCTAssertEqual(((next.first?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON)?.keys.sorted(), ["leftSlot", "rightSlot"],
                       "the dot goes along, or DynamicLake drops it")
        XCTAssertEqual(planner.nextDeadline, now.addingTimeInterval(1.4))

        // A newer feed of the same take resends nothing unless the second moved on.
        XCTAssertEqual(types(planner.update(status(.init(state: .recording, kind: .video, elapsed: 42.1), at: now.addingTimeInterval(0.5)),
                                            settings: PluginSettings(), features: features, now: now.addingTimeInterval(0.5),
                                            assetID: { _ in nil })), [])
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(0.5))), [])

        let paused = planner.update(status(.init(state: .paused, kind: .video, elapsed: 43.2), at: now.addingTimeInterval(1.6)),
                                    settings: PluginSettings(), features: features, now: now.addingTimeInterval(1.6), assetID: { _ in nil })
        XCTAssertEqual(clockText(paused.first), "0:43\u{2800}\u{2800}")
        XCTAssertEqual(clockTint(paused.first), "white", "a frozen time is not a running take")
        XCTAssertNil(planner.nextDeadline, "a paused clock does not tick")
    }

    func testTheCountdownCountsDownInTheSameClock() {
        var planner = ActivityPlanner()
        let created = planner.update(status(.init(state: .starting, kind: .video, elapsed: 0, countdownEndsAt: now.addingTimeInterval(3))),
                                     settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })
        XCTAssertEqual(clockText(created.first), "0:03\u{2800}\u{2800}")
        XCTAssertEqual(clockTint(created.first), "white", "the countdown is not a running take")
        let second = planner.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(clockText(second.first), "0:02\u{2800}\u{2800}")
        XCTAssertEqual(clockTint(second.first), "white")
        XCTAssertEqual(((second.first?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON)?.keys.sorted(), ["leftSlot", "rightSlot"],
                       "the countdown's update keeps both slots too")
        XCTAssertEqual(clockText(planner.tick(now: now.addingTimeInterval(2)).first), "0:01\u{2800}\u{2800}")
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(2.5))), [])
    }

    func testAHostWithoutNumericTextKeepsItsOwnTimer() {
        var planner = ActivityPlanner()
        let plain = HostFeatures(numericText: false)
        let created = planner.update(status(.init(state: .recording, kind: .video, elapsed: 5)), settings: PluginSettings(),
                                     features: plain, now: now, assetID: { _ in nil })
        let slot = ((created.first?["surfaces"] as? JSON)?["compactLiveActivity"] as? JSON)?["rightSlot"] as? JSON
        XCTAssertEqual(slot?["type"] as? String, "timer")
        XCTAssertNil(planner.nextDeadline)
    }

    func testADiscardedTakeLeavesAtOnce() {
        var planner = ActivityPlanner()
        _ = planner.update(status(.init(state: .recording, kind: .gif, elapsed: 2)), settings: PluginSettings(), features: features, now: now,
                           assetID: { _ in nil })
        XCTAssertEqual(types(planner.update(status(), settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })),
                       ["dismiss recording"])
    }

    func testASaveThatNeverArrivesStopsWaiting() {
        var planner = ActivityPlanner()
        _ = planner.update(status(.init(state: .saving, kind: .video, elapsed: 2)), settings: PluginSettings(), features: features, now: now,
                           assetID: { _ in nil })
        XCTAssertEqual(types(planner.update(status(), settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })), [])
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(ActivityPlanner.saveWait))), ["dismiss recording"])
    }

    func testNewCapturesShowOnlyWhenAskedAndNeverTheOnesFromBefore() {
        var planner = ActivityPlanner()
        let on = PluginSettings(showRecordings: true, showNewCaptures: true)
        let before = capture(.screenshot, at: now.addingTimeInterval(-5))
        XCTAssertEqual(types(planner.update(status(captures: [before]), settings: on, features: features, now: now, assetID: { _ in nil })), [])
        let new = capture(.screenshot, at: now)
        XCTAssertEqual(types(planner.update(status(captures: [new, before]), settings: on, features: features, now: now, assetID: { _ in nil })),
                       ["create capture"])
        XCTAssertEqual(types(planner.tick(now: now.addingTimeInterval(ActivityPlanner.captureDuration))), ["dismiss capture"])

        var quiet = ActivityPlanner()
        _ = quiet.update(status(captures: [before]), settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })
        XCTAssertEqual(types(quiet.update(status(captures: [new, before]), settings: PluginSettings(), features: features, now: now,
                                          assetID: { _ in nil })), [])
    }

    func testTurningRecordingsOffHidesTheTake() {
        var planner = ActivityPlanner()
        let take = status(.init(state: .recording, kind: .video, elapsed: 1))
        _ = planner.update(take, settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })
        XCTAssertEqual(types(planner.update(take, settings: PluginSettings(showRecordings: false), features: features, now: now,
                                            assetID: { _ in nil })), ["dismiss recording"])
        XCTAssertEqual(types(planner.update(take, settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })),
                       ["create recording"])
    }

    func testShotboltQuittingClearsTheNotch() {
        var planner = ActivityPlanner()
        _ = planner.update(status(.init(state: .recording, kind: .video, elapsed: 1)), settings: PluginSettings(), features: features, now: now,
                           assetID: { _ in nil })
        XCTAssertEqual(types(planner.update(.notRunning, settings: PluginSettings(), features: features, now: now, assetID: { _ in nil })),
                       ["dismiss recording"])
    }

    func testAnOlderHostGetsNoFieldsItWouldReject() {
        let old = HostFeatures(lake: false, lakeLayout: false, imageAssets: false, presentSneakPeek: false, numericText: false)
        let video = capture(.video, at: now)
        XCTAssertNil(Surfaces.savedActivity(video, assetID: nil, create: false, features: old)["presentSneakPeek"])
        let lake = Surfaces.lake(status(captures: [video]), context: .init(now: now), features: old)
        XCTAssertNil(lake["hideHeader"])
        XCTAssertNil(lake["content"])
        XCTAssertNil(lake["glance"])
    }
}

/// The loop with a fake Shotbolt: what reaches DynamicLake, and what reaches Shotbolt, for what the person does.
final class PluginLoopTests: XCTestCase {
    final class FakeLink: ShotboltLink {
        var state: ShotboltState
        var sent: [String] = []
        var launched = 0
        init(_ state: ShotboltState) { self.state = state }
        func currentState(now: Date) -> ShotboltState { state }
        func send(_ command: String) { sent.append(command) }
        func launchShotbolt() { launched += 1 }
        func openWebsite() {}
        var ready: (String) -> Bool = { _ in true }
        func fileReady(_ path: String) -> Bool { ready(path) }
        var subscribed = 0
        func subscribe() { subscribed += 1 }
    }

    let now = Date()
    let id = UUID()
    var link: FakeLink!
    var output: [JSON] = []
    var plugin: Plugin!

    override func setUp() {
        let capture = ShotboltStatus.Capture(id: id, kind: .screenshot, createdAt: now, file: "/tmp/a.png", width: 10, height: 10)
        link = FakeLink(.ready(ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 1), captures: [capture], updatedAt: now)))
        plugin = Plugin(link: link, features: HostFeatures(), loadSettings: { PluginSettings() }) { [unowned self] in self.output.append($0) }
    }

    func testSendsTheLakeOnceAtLaunchAndOnlyWhenItChanges() throws {
        try plugin.tick(now: now)
        XCTAssertEqual(output.compactMap { $0["type"] as? String }, ["asset", "lake"], "the blank square for a picture not written yet, then the lake")
        output.removeAll()
        try plugin.tick(now: now.addingTimeInterval(0.1))
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        try plugin.tick(now: now.addingTimeInterval(0.2))
        XCTAssertEqual(output.count, 0, "the same lake is not sent again")
    }

    func testCopyShowsTheCheckmarkThenClosesTheLake() throws {
        try plugin.tick(now: now)
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        output.removeAll()
        try plugin.handle(["type": "action", "actionID": "copy:\(id.uuidString)", "surface": "lake"], now: now)
        XCTAssertEqual(link.sent, ["copy-capture?id=\(id.uuidString)"])
        try plugin.tick(now: now.addingTimeInterval(0.1))
        XCTAssertTrue(String(describing: output).contains("checkmark"))
        try plugin.tick(now: now.addingTimeInterval(Plugin.closeAfterCopy))
        XCTAssertEqual(output.last?["type"] as? String, "closeLake")
    }

    /// Shotbolt 1.3 may ask "edited or original?" before it copies a video, so the lake shows no check for one; it still
    /// sends Copy and closes, so Shotbolt's question is in view.
    func testCopyingAVideoInTheLakeSendsItAndClosesTheLakeWithoutACheck() throws {
        let video = ShotboltStatus.Capture(id: id, kind: .video, createdAt: now, file: "/tmp/a.mov", width: 10, height: 10, duration: 5)
        link.state = .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), captures: [video], updatedAt: now))
        try plugin.tick(now: now)
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        output.removeAll()
        try plugin.handle(["type": "action", "actionID": "copy:\(id.uuidString)", "surface": "lake"], now: now)
        XCTAssertEqual(link.sent, ["copy-capture?id=\(id.uuidString)"])
        try plugin.tick(now: now.addingTimeInterval(0.1))
        XCTAssertEqual(output.count, 0, "no copied state, so no lake patch")
        XCTAssertEqual(plugin.nextWake(now: now.addingTimeInterval(0.1)), now.addingTimeInterval(Plugin.closeAfterCopy),
                       "the lake close is still due")
        try plugin.tick(now: now.addingTimeInterval(Plugin.closeAfterCopy))
        XCTAssertEqual(output.map { $0["type"] as? String }, ["closeLake"])
        XCTAssertFalse(String(describing: output).contains("checkmark"))
    }

    /// A take saved a moment ago cannot have been edited yet: its sneak peek still says Copied.
    func testCopyingTheSavedTakeFromItsSneakPeekStillSaysCopied() throws {
        let app = ShotboltStatus.App(version: "1.3.0", build: "18", pid: 1)
        link.state = .ready(ShotboltStatus(app: app, recording: .init(state: .recording, kind: .video, elapsed: 3), updatedAt: now))
        try plugin.tick(now: now)
        link.state = .ready(ShotboltStatus(app: app, recording: .init(state: .saving, kind: .video, elapsed: 4), updatedAt: now))
        plugin.markStatusChanged()
        try plugin.tick(now: now.addingTimeInterval(1))
        let video = ShotboltStatus.Capture(id: id, kind: .video, createdAt: now.addingTimeInterval(2), file: "/tmp/a.mov", width: 10, height: 10)
        link.state = .ready(ShotboltStatus(app: app, captures: [video], updatedAt: now.addingTimeInterval(2)))
        plugin.markStatusChanged()
        try plugin.tick(now: now.addingTimeInterval(2))
        XCTAssertTrue(output.contains { $0["presentSneakPeek"] as? Int == 3 }, "the saved take shows")
        output.removeAll()
        try plugin.handle(["type": "action", "activityID": "recording", "actionID": "copy:\(id.uuidString)", "surface": "sneakPeek"],
                          now: now.addingTimeInterval(3))
        XCTAssertEqual(link.sent, ["copy-capture?id=\(id.uuidString)"])
        XCTAssertEqual(output.first?["activityID"] as? String, "recording")
        XCTAssertTrue(String(describing: output.first ?? [:]).contains("Copied"))
    }

    /// A thumbnail not written yet: the open lake looks again soon, so the picture shows once Shotbolt writes it.
    func testAnOpenLakeLooksAgainWhileAThumbnailIsMissing() throws {
        let capture = ShotboltStatus.Capture(id: id, kind: .screenshot, createdAt: now, file: "/tmp/a.png", thumbnail: "/tmp/not-yet.png",
                                             width: 10, height: 10)
        link.state = .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), captures: [capture], updatedAt: now))
        link.ready = { $0 != "/tmp/not-yet.png" }
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        try plugin.tick(now: now)
        XCTAssertEqual(plugin.nextWake(now: now), now.addingTimeInterval(Plugin.lakeRefreshInterval))
        link.ready = { _ in true }
        try plugin.tick(now: now.addingTimeInterval(Plugin.lakeRefreshInterval))
        XCTAssertEqual(plugin.nextWake(now: now.addingTimeInterval(Plugin.lakeRefreshInterval)), now.addingTimeInterval(60),
                       "once it is there, only the next time change")
    }

    func testSleepsUntilThePollWhenNothingIsDue() throws {
        try plugin.tick(now: now)
        XCTAssertEqual(plugin.nextWake(now: now), now.addingTimeInterval(Plugin.pollInterval))
        plugin.markStatusChanged()
        XCTAssertEqual(plugin.nextWake(now: now), now, "a change notification is read at once")
    }

    func testWakesForTheCopyFeedbackAndTheLakesTimes() throws {
        try plugin.tick(now: now)
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        try plugin.tick(now: now)
        XCTAssertEqual(plugin.nextWake(now: now), now.addingTimeInterval(60), "wakes when Just now becomes 1 min ago, not on a clock")
        try plugin.handle(["type": "action", "actionID": "copy:\(id.uuidString)", "surface": "lake"], now: now)
        try plugin.tick(now: now)
        XCTAssertEqual(plugin.nextWake(now: now), now.addingTimeInterval(Plugin.closeAfterCopy))
    }

    func testAnOlderHostGetsTheLakeAgainWithoutClickablePictures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = ShotboltStatus.Capture(id: id, kind: .screenshot, createdAt: now, file: "/tmp/a.png", thumbnail: file.path, width: 10, height: 10)
        link.state = .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 1), captures: [capture], updatedAt: now))
        plugin = Plugin(link: link, features: HostFeatures(), loadSettings: { PluginSettings() },
                        thumbnails: ThumbnailAssets(encode: { _, _ in Data([1]) })) { [unowned self] in self.output.append($0) }
        func picture(_ command: JSON?) -> JSON? {
            func find(_ value: Any) -> JSON? {
                if let object = value as? JSON {
                    if object["id"] as? String == "band-image" { return object }
                    return object.values.lazy.compactMap(find).first
                }
                return (value as? [Any])?.lazy.compactMap(find).first
            }
            return command.flatMap(find)
        }
        try plugin.tick(now: now)
        XCTAssertEqual(picture(output.last)?["actionID"] as? String, "open:\(id.uuidString)", "the picture opens the capture")
        output.removeAll()
        try plugin.handle(["type": "error", "error": "Unknown field 'actionID' at $.lake.content[1].children[0]."], now: now)
        try plugin.tick(now: now)
        XCTAssertEqual(output.map { $0["type"] as? String }, ["lake"], "sent again whole, at once")
        XCTAssertNotNil(picture(output.first))
        XCTAssertNil(picture(output.first)?["actionID"], "without clickable pictures")
    }

    func testCaptureButtonsCloseTheLakeBeforeShotboltStarts() throws {
        try plugin.tick(now: now)
        try plugin.handle(["type": "lakeOpened", "trigger": "click"], now: now)
        output.removeAll()
        try plugin.handle(["type": "action", "actionID": "capture-area", "surface": "lake"], now: now)
        XCTAssertEqual(output.map { $0["type"] as? String }, ["closeLake"])
        XCTAssertEqual(link.sent, [])
        try plugin.tick(now: now.addingTimeInterval(Plugin.actionAfterClose))
        XCTAssertEqual(link.sent, ["capture-area"])
    }

    func testStopFromTheSneakPeekGoesStraightToShotbolt() throws {
        link.state = .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 1),
                                           recording: .init(state: .recording, kind: .video, elapsed: 3), updatedAt: now))
        try plugin.tick(now: now)
        XCTAssertTrue(output.contains { $0["type"] as? String == "create" })
        try plugin.handle(["type": "action", "activityID": "recording", "actionID": "stop-recording", "surface": "sneakPeek"], now: now)
        XCTAssertEqual(link.sent, ["stop-recording"])
    }

    func testNotRunningOffersToOpenShotbolt() throws {
        link.state = .notRunning
        try plugin.tick(now: now)
        XCTAssertTrue(String(describing: output).contains("launch-shotbolt"))
        try plugin.handle(["type": "action", "actionID": "launch-shotbolt", "surface": "lake"], now: now)
        XCTAssertEqual(link.launched, 1)
    }

    func testThumbnailsAreRegisteredBeforeTheLakeThatShowsThem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = ShotboltStatus.Capture(id: id, kind: .screenshot, createdAt: now, file: "/tmp/a.png", thumbnail: file.path, width: 10, height: 10)
        link.state = .ready(ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 1), captures: [capture], updatedAt: now))
        plugin = Plugin(link: link, features: HostFeatures(), loadSettings: { PluginSettings() },
                        thumbnails: ThumbnailAssets(encode: { _, _ in Data([1, 2, 3]) })) { [unowned self] in self.output.append($0) }
        try plugin.tick(now: now)
        XCTAssertEqual(output.map { $0["type"] as? String }, ["asset", "lake"])
        XCTAssertTrue(String(describing: output[1]).contains("thumb-0"))
    }
}

/// The thumbnail assets themselves: square, small, and badged for videos and GIFs. `SHOTBOLT_THUMB_DUMP=<dir>` writes them out
/// to look at.
final class ThumbnailTests: XCTestCase {
    func testSquareJPEGsUnderTheAssetLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, width, height) in [("wide", 640, 400), ("tall", 400, 1600)] {
            let file = folder.appendingPathComponent("\(name).png")
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 60, width: width, height: 60)) // a title bar along the top
            let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            for kind in [ShotboltStatus.Capture.Kind.screenshot, .video, .gif] {
                let data = try XCTUnwrap(ThumbnailAssets.jpeg(path: file.path, kind: kind))
                XCTAssertLessThan(data.count, 192 * 1024)
                let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                XCTAssertEqual(image.width, ThumbnailAssets.side)
                XCTAssertEqual(image.height, ThumbnailAssets.side)
                if let dump = ProcessInfo.processInfo.environment["SHOTBOLT_THUMB_DUMP"] {
                    try data.write(to: URL(fileURLWithPath: dump).appendingPathComponent("\(name)-\(kind.rawValue).jpg"))
                }
            }
        }
    }
}
