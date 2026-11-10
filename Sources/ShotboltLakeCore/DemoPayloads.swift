import Foundation

#if DEBUG
/// Every kind of command the plugin sends, from sample states: `shotbolt-lake --demo-json` prints them for checking against
/// DynamicLake, and the tests hold them to DynamicLake's limits. Debug builds only: sample data has no place in the package.
public enum DemoPayloads {
    public static func sampleStatus(now: Date, recording: ShotboltStatus.Recording? = nil, captureCount: Int = Surfaces.maxLakeRows)
        -> ShotboltStatus {
        let kinds: [ShotboltStatus.Capture.Kind] = [.screenshot, .video, .screenshot, .gif, .screenshot]
        let titles: [String?] = ["Pricing table", nil, "Bug: login button overlaps the field when the window is narrow", nil, nil]
        let apps: [String?] = ["Safari", "Keynote", nil, nil, nil]
        let categories: [String?] = ["web", nil, "code", nil, "chat"]
        let captures = (0..<captureCount).map { index -> ShotboltStatus.Capture in
            let kind = kinds[index % kinds.count]
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            let createdAt = now.addingTimeInterval(-Double(index) * 1800 - 30)
            let length: Double? = kind == .screenshot ? nil : 65.4
            return ShotboltStatus.Capture(id: id, kind: kind, title: titles[index % titles.count], createdAt: createdAt,
                                          file: "/Users/example/Pictures/Shotbolt/Capture \(index).png", width: 1440, height: 900,
                                          saved: index % 2 == 0, duration: length, kept: index % 3 == 0,
                                          app: apps[index % apps.count], category: categories[index % categories.count])
        }
        return ShotboltStatus(app: .init(version: "1.3.0", build: "15", pid: 4242), recording: recording, captures: captures,
                              updatedAt: now, pro: true)
    }

    public static func all(now: Date, features: HostFeatures = HostFeatures()) -> [JSON] {
        let assets: (ShotboltStatus.Capture) -> String? = { capture in
            Int(capture.id.uuidString.suffix(2)).map { $0 % 2 == 0 ? "thumb-\($0 % ThumbnailAssets.slotCount)" : nil } ?? nil
        }
        var context = Surfaces.LakeContext(assetID: assets, copiedID: UUID(uuidString: "00000000-0000-4000-8000-000000000002"), now: now)
        context.blank = { "blank" }
        let recordings: [ShotboltStatus.Recording] = [
            .init(state: .starting, kind: .video, elapsed: 0, countdownEndsAt: now.addingTimeInterval(3)),
            .init(state: .starting, kind: .gif, elapsed: 0),
            .init(state: .recording, kind: .video, elapsed: 75.4),
            .init(state: .recording, kind: .gif, elapsed: 4),
            .init(state: .paused, kind: .video, elapsed: 3725),
            .init(state: .saving, kind: .video, elapsed: 80),
            .init(state: .converting, kind: .gif, elapsed: 9),
        ]
        var out: [JSON] = []
        for (index, recording) in recordings.enumerated() {
            let status = sampleStatus(now: now, recording: recording)
            if let command = Surfaces.recordingActivity(status, now: now, create: index == 0, features: features) { out.append(command) }
            out.append(Surfaces.lakeCommand(Surfaces.lake(.ready(status), context: context, features: features)))
        }
        // The same takes in the text style (a primary display without a notch), and its clock's next second.
        for recording in recordings {
            let status = sampleStatus(now: now, recording: recording)
            if let command = Surfaces.recordingActivity(status, now: now, create: false, features: features, style: .text) { out.append(command) }
            if let clock = Surfaces.compactClock(status, now: now, style: .text) {
                out.append(Surfaces.clockUpdate(clock.slot, recording: recording, style: .text))
            }
        }
        let status = sampleStatus(now: now)
        out.append(Surfaces.savedActivity(status.captures[1], assetID: "thumb-1", create: false, features: features, style: .text))
        out.append(Surfaces.savedActivity(status.captures[1], assetID: "thumb-1", create: false, features: features))
        out.append(Surfaces.savedActivity(status.captures[3], assetID: nil, create: false, features: features))
        out.append(Surfaces.copiedUpdate(status.captures[1], features: features))
        // More open, a tile picked, a GIF and a screenshot large, and the patch between two of them.
        var picked = context
        picked.moreOpen = true
        picked.focusedID = status.captures[3].id
        let before = Surfaces.lake(.ready(status), context: context, features: features)
        let after = Surfaces.lake(.ready(status), context: picked, features: features)
        out.append(Surfaces.lakeCommand(after))
        picked.focusedID = status.captures[2].id
        picked.moreOpen = false
        let patched = Surfaces.lake(.ready(status), context: picked, features: features)
        out.append(contentsOf: LakeDiff.commands(LakeDiff.patches(from: before, to: patched) ?? []))
        out.append(Surfaces.captureActivity(status.captures[0], assetID: "thumb-0", features: features))
        out.append(Surfaces.captureActivity(status.captures[2], assetID: nil, features: features))
        out.append(Surfaces.dismiss(Surfaces.captureActivityID))
        out.append(Surfaces.lakeCommand(Surfaces.lake(.ready(status), context: context, features: features)))
        out.append(Surfaces.lakeCommand(Surfaces.lake(.ready(sampleStatus(now: now, captureCount: 0)), context: context, features: features)))
        out.append(Surfaces.lakeCommand(Surfaces.lake(.ready(sampleStatus(now: now, captureCount: 40)), context: context, features: features)))
        for state in [ShotboltState.notInstalled, .notRunning, .needsUpdate, .pluginOutdated, .disabled] {
            out.append(Surfaces.lakeCommand(Surfaces.lake(state, context: context, features: features)))
        }
        let basic = HostFeatures(lake: true, lakeLayout: false, imageAssets: false, presentSneakPeek: false, numericText: false)
        out.append(Surfaces.lakeCommand(Surfaces.lake(.ready(status), context: context, features: basic)))
        out.append(Surfaces.lakeCommand(Surfaces.lake(.notRunning, context: context, features: basic)))
        out.append(Surfaces.closeLake())
        return out
    }
}
#endif
