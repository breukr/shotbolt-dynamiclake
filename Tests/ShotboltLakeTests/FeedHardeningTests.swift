import XCTest
import ImageIO
@testable import ShotboltLakeCore

/// Any process of this user can write the feed file, so a broken or hostile one must decode or be skipped, and then nothing the
/// plugin does with it may stop the plugin: DynamicLake does not start it again.
final class FeedHardeningTests: XCTestCase {
    let id = UUID(), videoID = UUID()

    /// A feed with every number and date in it; each placeholder is replaced by a test value.
    func feed(state: String = "recording", elapsed: String = "12.5", countdown: String = "\"2026-11-10T09:00:03Z\"",
              duration: String = "42.5", width: String = "1440", height: String = "900", createdAt: String = "\"2026-11-10T08:59:00Z\"",
              updatedAt: String = "\"2026-11-10T09:00:00Z\"", endedAt: String = "\"2026-11-10T08:59:30Z\"") -> String {
        """
        {"schemaVersion":1,"enabled":true,"pro":true,"app":{"version":"1.3.0","build":"18","pid":7},"updatedAt":\(updatedAt),
         "recording":{"state":"\(state)","kind":"video","elapsed":\(elapsed),"countdownEndsAt":\(countdown)},
         "lastTake":{"endedAt":\(endedAt),"outcome":"saved","capture":"\(videoID.uuidString)"},
         "captures":[
          {"id":"\(videoID.uuidString)","kind":"video","createdAt":\(createdAt),"file":"/tmp/a.mov","width":\(width),"height":\(height),
           "saved":false,"kept":false,"duration":\(duration)},
          {"id":"\(id.uuidString)","kind":"screenshot","createdAt":\(createdAt),"file":"/tmp/a.png","width":\(width),"height":\(height),
           "saved":true,"kept":true}
         ]}
        """
    }

    static let numbers = ["1e300", "-1e300", "1e400", "-1e400", "0", "-5", "1e20", "-0.0", "9.2233720368547758e18", "\"x\"", "null"]
    static let dates = ["\"9999-12-31T23:59:59Z\"", "\"0001-01-01T00:00:00Z\"", "\"+275760-09-13T00:00:00Z\"", "\"2499-12-31T00:00:00Z\"",
                        "\"1970-01-01T00:00:00Z\"", "\"not a date\"", "1e300", "null"]

    /// Everything the plugin does with a state: the lake, the take's activity and clock, the planner and its ticks, the times.
    func exercise(_ status: ShotboltStatus, file: StaticString = #filePath, line: UInt = #line) {
        let features = HostFeatures()
        for now in [status.updatedAt, Date(), status.updatedAt.addingTimeInterval(3600 * 24 * 400)] {
            _ = Surfaces.lake(.ready(status), context: .init(now: now), features: features)
            _ = Surfaces.lake(.ready(status), context: .init(now: now), features: HostFeatures(lake: true, lakeLayout: false))
            _ = Surfaces.recordingActivity(status, now: now, create: true, features: features)
            _ = Surfaces.recordingActivity(status, now: now, create: false, features: HostFeatures(numericText: false))
            _ = Surfaces.compactClock(status, now: now)
            _ = Surfaces.nextTimeChange(status.captures.map(\.createdAt) + [status.updatedAt], now: now)
            for capture in status.captures {
                _ = Surfaces.subtitle(of: capture, now: now)
                _ = Surfaces.savedActivity(capture, assetID: nil, create: false, features: features)
                _ = Surfaces.captureActivity(capture, assetID: nil, features: features)
            }
            var planner = ActivityPlanner()
            let settings = PluginSettings(showRecordings: true, showNewCaptures: true)
            _ = planner.update(.ready(status), settings: settings, features: features, now: now, assetID: { _ in nil })
            var ended = status; ended.recording = nil
            _ = planner.update(.ready(ended), settings: settings, features: features, now: now, assetID: { _ in nil })
            _ = planner.update(.ready(status), settings: settings, features: features, now: now, assetID: { _ in nil })
            for step: TimeInterval in [0, 1, 60, 2_592_000] { _ = planner.tick(now: now.addingTimeInterval(step)) }
            _ = planner.nextDeadline
        }
    }

    func testEveryNumberAndDateFieldDecodesOrIsSkippedAndNeverStopsThePlugin() {
        var variants: [String] = []
        for state in ["recording", "paused", "starting", "saving"] {
            for value in Self.numbers {
                variants += [feed(state: state, elapsed: value), feed(state: state, duration: value), feed(state: state, width: value),
                             feed(state: state, height: value)]
            }
            for value in Self.dates {
                variants += [feed(state: state, countdown: value), feed(state: state, createdAt: value), feed(state: state, updatedAt: value),
                             feed(state: state, endedAt: value)]
            }
        }
        var decoded = 0
        for text in variants {
            guard let status = try? ShotboltStatus.decode(Data(text.utf8)) else { continue } // refused whole: the plugin shows a notice
            decoded += 1
            exercise(status)
            for capture in status.captures {
                XCTAssertTrue(ShotboltStatus.dates.contains(capture.createdAt))
                if let duration = capture.duration { XCTAssertTrue(ShotboltStatus.seconds.contains(duration)) }
            }
            if let recording = status.recording {
                XCTAssertTrue(ShotboltStatus.seconds.contains(recording.elapsed))
                if let end = recording.countdownEndsAt { XCTAssertLessThanOrEqual(abs(end.timeIntervalSince(status.updatedAt)), 3600) }
            }
        }
        XCTAssertGreaterThan(decoded, variants.count / 2, "most broken values are dropped or clamped, not the whole file")
    }

    func testOutOfRangeValuesAreDroppedOrClamped() throws {
        let huge = try ShotboltStatus.decode(Data(feed(elapsed: "1e300", duration: "1e300").utf8))
        XCTAssertEqual(huge.recording?.elapsed, ShotboltStatus.seconds.upperBound, "a take's time clamps")
        XCTAssertNil(huge.captures[0].duration, "a length out of range is unknown")
        let negative = try ShotboltStatus.decode(Data(feed(elapsed: "-1e300", duration: "-5").utf8))
        XCTAssertEqual(negative.recording?.elapsed, 0)
        XCTAssertNil(negative.captures[0].duration)
        let farCountdown = try ShotboltStatus.decode(Data(feed(state: "starting", countdown: "\"2499-12-31T00:00:00Z\"").utf8))
        XCTAssertNil(farCountdown.recording?.countdownEndsAt, "no countdown runs for centuries")
        let farCapture = try ShotboltStatus.decode(Data(feed(createdAt: "\"9999-12-31T23:59:59Z\"").utf8))
        XCTAssertTrue(farCapture.captures.isEmpty, "captures with a far-off date are skipped")
        XCTAssertThrowsError(try ShotboltStatus.decode(Data(feed(updatedAt: "\"9999-12-31T23:59:59Z\"").utf8)))
    }

    /// Values made in code, past the decoder: the arithmetic itself does not trap either.
    func testTheArithmeticIsSafeOnAnyDouble() {
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300, Double(Int.max), -Double(Int.max)] {
            _ = Surfaces.duration(value)
            _ = Surfaces.wholeSeconds(value, .up)
            let now = Date()
            for state in [ShotboltStatus.Recording.State.recording, .paused, .starting] {
                let status = ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1),
                                            recording: .init(state: state, kind: .gif, elapsed: value, countdownEndsAt: now.addingTimeInterval(3)),
                                            captures: [.init(id: id, kind: .video, createdAt: now, file: "/tmp/a.mov", width: 1, height: 1, duration: value)],
                                            updatedAt: now)
                exercise(status)
            }
        }
        XCTAssertEqual(Surfaces.wholeSeconds(.nan), 0)
        XCTAssertEqual(Surfaces.wholeSeconds(1e300), 1_000_000_000_000)
        XCTAssertEqual(Surfaces.duration(65.4), "1:05", "ordinary values read as before")
    }

    func testAtMostFiftyCapturesAreRead() throws {
        let one = """
        {"id":"%@","kind":"screenshot","createdAt":"2026-11-10T08:59:00Z","file":"/tmp/a.png","width":1,"height":1,"saved":false}
        """
        let list = (0..<500).map { _ in String(format: one, UUID().uuidString) }.joined(separator: ",")
        let text = """
        {"schemaVersion":1,"enabled":true,"app":{"version":"1.3.0","build":"18","pid":7},"updatedAt":"2026-11-10T09:00:00Z",
         "captures":[\(list)]}
        """
        XCTAssertEqual(try ShotboltStatus.decode(Data(text.utf8)).captures.count, ShotboltStatus.maxCaptures)
        let none = #"{"schemaVersion":1,"enabled":false,"app":{"version":"1.3.0","build":"18","pid":7},"updatedAt":"2026-11-10T09:00:00Z"}"#
        XCTAssertEqual(try ShotboltStatus.decode(Data(none.utf8)).captures, [], "a feed without the list still reads")
    }

    func testThumbnailsAreKeptOnlyInsideTheFeedsFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lake-thumbs-\(UUID().uuidString)")
        let support = base.appendingPathComponent("Shotbolt"), outside = base.appendingPathComponent("Elsewhere")
        defer { try? FileManager.default.removeItem(at: base) }
        for folder in ["Shotbolt/Thumbnails", "Shotbolt/Integrations", "Elsewhere"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let inside = support.appendingPathComponent("Thumbnails/a.png"), secret = outside.appendingPathComponent("secret.png")
        try Data([1]).write(to: inside)
        try Data([1]).write(to: secret)
        let link = support.appendingPathComponent("Thumbnails/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let dirLink = support.appendingPathComponent("Thumbnails/out")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: outside)
        let paths = [inside.path, support.path + "/Thumbnails/../../Elsewhere/secret.png", link.path, dirLink.path + "/secret.png",
                     dirLink.path + "/../Shotbolt/Thumbnails/a.png", secret.path, "Thumbnails/a.png", dirLink.path + "/not-yet.png",
                     support.path + "-evil/a.png", support.path + "/Thumbnails/dangling.png", support.path + "/Thumbnails/..",
                     support.path + "/Missing/not-yet.png"]
        try FileManager.default.createSymbolicLink(atPath: support.path + "/Thumbnails/dangling.png", withDestinationPath: outside.path + "/later.png")
        let captures = paths.map { ShotboltStatus.Capture(id: UUID(), kind: .screenshot, createdAt: Date(), file: "/tmp/x", thumbnail: $0, width: 1, height: 1) }
        let status = ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), captures: captures, updatedAt: Date())
        let kept = status.keepingThumbnails(inside: support).captures.map(\.thumbnail)
        let real = try XCTUnwrap(realpath(inside.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
        XCTAssertEqual(kept[0], real, "Shotbolt's own thumbnail, by its real path")
        for index in 1..<paths.count where index != 4 { XCTAssertNil(kept[index], paths[index]) }
        // `out/..` is Elsewhere's parent as the system follows it, so this path does lead back to Shotbolt's own thumbnail.
        XCTAssertEqual(kept[4], real)
        XCTAssertEqual(status.captures.map(\.file), status.keepingThumbnails(inside: support).captures.map(\.file), "files are not limited")
    }

    /// A thumbnail Shotbolt has not written yet keeps its path, and its picture shows on the next lake once the file is there.
    func testAThumbnailNotWrittenYetShowsOnceItIs() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("lake-late-\(UUID().uuidString)/Shotbolt")
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        let file = support.appendingPathComponent("Thumbnails/late.png")
        let capture = ShotboltStatus.Capture(id: id, kind: .screenshot, createdAt: Date(), file: "/tmp/a.png", thumbnail: file.path, width: 1, height: 1)
        let status = ShotboltStatus(app: .init(version: "1.3.0", build: "18", pid: 1), captures: [capture], updatedAt: Date())
            .keepingThumbnails(inside: support)
        let kept = try XCTUnwrap(status.captures.first?.thumbnail, "kept although the file is not there yet")
        XCTAssertTrue(kept.hasSuffix("/Shotbolt/Thumbnails/late.png"))

        let thumbnails = ThumbnailAssets()
        func lake() -> String {
            let context = Surfaces.LakeContext(assetID: { thumbnails.assetID(for: $0) }, now: Date())
            return String(describing: Surfaces.lake(.ready(status), context: context, features: HostFeatures()))
        }
        XCTAssertFalse(lake().contains("\"thumb-"), "the placeholder while there is no file")
        XCTAssertTrue(thumbnails.takePending().isEmpty)
        let image = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(lake().contains("\"thumb-"), "the next lake shows the picture")
        XCTAssertEqual(thumbnails.takePending().map { $0["type"] as? String }, ["asset"])
    }
}
