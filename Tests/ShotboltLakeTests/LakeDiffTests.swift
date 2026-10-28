import XCTest
@testable import ShotboltLakeCore

/// What goes to DynamicLake when the lake changes: a patch of the components that changed, so a scrolled filmstrip stays where
/// it is, or the whole lake when its shape changed.
final class LakeDiffTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var status: ShotboltStatus!

    override func setUp() { status = DemoPayloads.sampleStatus(now: now, captureCount: 5) }

    func lake(_ context: Surfaces.LakeContext, status: ShotboltStatus? = nil) -> JSON {
        Surfaces.lake(.ready(status ?? self.status), context: context, features: HostFeatures())
    }

    func ids(_ patches: [JSON]?) -> [String]? { patches?.compactMap { $0["id"] as? String } }

    func testNothingChangedSendsNothing() {
        let context = Surfaces.LakeContext(now: now)
        XCTAssertEqual(ids(LakeDiff.patches(from: lake(context), to: lake(context))), [])
    }

    func testCopyTurnsOnlyItsButtonIntoACheck() {
        let newest = status.captures[0].id
        XCTAssertEqual(ids(LakeDiff.patches(from: lake(.init(now: now)), to: lake(.init(copiedID: newest, now: now)))),
                       ["band-copy", "glance-copy-\(newest.uuidString)"])
    }

    func testAMinuteLaterOnlyTheTimeChanges() {
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(ids(LakeDiff.patches(from: lake(.init(now: now)), to: lake(.init(now: later)))), ["band-subtitle"])
    }

    func testPickingATileReplacesTheLargeCaptureAndTheFilmstripByID() {
        let patched = ids(LakeDiff.patches(from: lake(.init(now: now)), to: lake(.init(focusedID: status.captures[2].id, now: now))))
        XCTAssertEqual(patched, ["band", "strip"], "the strip holds every capture but the one shown large")
    }

    func testANewCaptureReplacesTheListsWholeAndMoreOnlyTheToolRow() {
        var grown = status!
        grown.captures.insert(ShotboltStatus.Capture(id: UUID(), kind: .screenshot, createdAt: now, file: "/n.png", width: 1, height: 1), at: 0)
        XCTAssertEqual(ids(LakeDiff.patches(from: lake(.init(now: now)), to: lake(.init(now: now), status: grown))),
                       ["band", "strip", "glance-captures"], "lists that gained a child are replaced whole, by id")
        XCTAssertEqual(ids(LakeDiff.patches(from: lake(.init(now: now)), to: lake(.init(moreOpen: true, now: now)))), ["toolbar"],
                       "More swaps the tools in place, so the lake keeps its height")
        XCTAssertNil(LakeDiff.patches(from: nil, to: lake(.init(now: now))), "the first lake goes whole")
    }

    func testPatchesGoSixteenAtATime() {
        let components = (0..<20).map { ["type": "text", "id": "t\($0)", "text": "x"] as JSON }
        let commands = LakeDiff.commands(components)
        XCTAssertEqual(commands.map { ($0["components"] as? [JSON])?.count }, [16, 4])
        XCTAssertTrue(commands.allSatisfy { $0["type"] as? String == "lakePatch" })
    }
}
