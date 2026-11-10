import Foundation

/// Decides which live activities to create, update and dismiss as Shotbolt's state changes. No I/O: it returns the commands,
/// and the plugin sends them.
///
/// - A take shows from its countdown until it is saved, then turns green ("Recording saved", Copy) for a few seconds.
/// - With "Show New Screenshots", each new capture shows for a few seconds, unless a take is on screen.
/// - The captures that were there when the plugin started are never announced.
public struct ActivityPlanner {
    public static let savedDuration: TimeInterval = 6
    public static let captureDuration: TimeInterval = 5
    /// A take saved longer ago than this is not announced (the plugin started late, or Shotbolt took long).
    public static let savedWindow: TimeInterval = 120
    /// How long "Saving recording" waits for the file to reach History after the take ended.
    public static let saveWait: TimeInterval = 10

    /// What makes the recording activity change: anything else is the running clock, which `tick` advances (or, without numeric
    /// text, DynamicLake's timer runs by itself).
    struct RecordingKey: Equatable {
        var state: ShotboltStatus.Recording.State
        var kind: ShotboltStatus.Recording.Kind
        /// Whole seconds, so a feed rewritten a moment later with the same take does not resend it.
        var start: Int
        var countdownEnd: Int?
        /// A lid opened or closed mid-take changes how the compact activity is drawn: the activity goes again, as an update.
        var style: CompactStyle = .symbols
    }

    private var known: Set<UUID>?
    private var recordingKey: RecordingKey?
    /// The recording activity exists (recording, or showing "saved").
    private var recordingShown = false
    private var savedUntil: Date?
    /// The capture "saved" shows, so its Copy can say "Copied".
    private var savedCapture: ShotboltStatus.Capture?
    /// When the take on screen started: an older `lastTake` in the feed is the previous take's.
    private var takeStartedAt: Date?
    /// The take ended while saving; its file is not in the feed yet.
    private var awaitingSaveUntil: Date?
    private var captureShown = false
    private var captureUntil: Date?
    /// The take whose compact clock `tick` advances (`Surfaces.compactClock`), the text the notch shows and when it changes.
    private var clockStatus: ShotboltStatus?
    private var clockText: String?
    private var clockAt: Date?
    /// The style the clock ticks in, and the one the saved take's activity was sent in.
    private var clockStyle: CompactStyle = .symbols
    private var savedStyle: CompactStyle = .symbols

    public init() {}

    /// The commands for a new state. `assetID` registers a capture's thumbnail when one is needed; `style` is how the compact
    /// activity is drawn now (a host without numeric text always gets `.symbols`).
    public mutating func update(_ state: ShotboltState, settings: PluginSettings, features: HostFeatures, now: Date,
                                style: CompactStyle = .symbols, assetID: (ShotboltStatus.Capture) -> String?) -> [JSON] {
        guard let status = state.status else { return dismissAll() }
        let style = style.effective(features)
        var out: [JSON] = []
        let fresh = status.captures.filter { known?.contains($0.id) == false }
        let firstLook = known == nil
        known = (known ?? []).union(status.captures.map(\.id))

        if let recording = status.recording, settings.showRecordings, recording.state != .other {
            let start = Surfaces.wholeSeconds(status.recordingStart()?.timeIntervalSince1970 ?? 0, .toNearestOrAwayFromZero)
            let key = RecordingKey(state: recording.state, kind: recording.kind,
                                   start: recording.state == .paused ? Surfaces.wholeSeconds(recording.elapsed) : start,
                                   countdownEnd: recording.countdownEndsAt.map {
                                       Surfaces.wholeSeconds($0.timeIntervalSince1970, .toNearestOrAwayFromZero)
                                   }, style: style)
            if recordingKey == nil { takeStartedAt = status.recordingStart() ?? now }
            let clock = features.numericText ? Surfaces.compactClock(status, now: now, style: style) : nil
            clockStyle = style
            if key != recordingKey || savedUntil != nil,
               let command = Surfaces.recordingActivity(status, now: now, create: !recordingShown, features: features, style: style) {
                out.append(command)
                recordingShown = true
                clockText = clock?.slot["text"] as? String
                clockAt = clock?.next
            } else if clock != nil {
                // The same take in a newer feed: `tick` checks the clock against what the notch shows.
                clockAt = now
            }
            clockStatus = clock == nil ? nil : status
            recordingKey = key
            savedUntil = nil
            awaitingSaveUntil = nil
            if captureShown { out.append(dismissCapture()) }
            return out
        }

        if let ended = recordingKey ?? (awaitingSaveUntil != nil ? RecordingKey(state: .saving, kind: .other, start: 0) : nil) {
            // The take ended: saved, still on its way to History, or discarded. Shotbolt says which (`lastTake`); an older
            // Shotbolt does not, and then a new video or GIF is the saved take and "saving" means a file is coming.
            recordingKey = nil
            stopClock()
            let take = status.lastTake.flatMap { take in
                take.endedAt >= (takeStartedAt ?? .distantPast).addingTimeInterval(-1) && now.timeIntervalSince(take.endedAt) < Self.savedWindow ? take : nil
            }
            let saved: ShotboltStatus.Capture?
            let fileComing: Bool
            if let take {
                saved = take.outcome == .saved ? take.capture.flatMap { id in status.captures.first { $0.id == id } } : nil
                fileComing = take.outcome == .saved
            } else {
                saved = fresh.first { ($0.kind == .video || $0.kind == .gif) && now.timeIntervalSince($0.createdAt) < Self.savedWindow }
                fileComing = ended.state == .saving || ended.state == .converting
            }
            if let saved, settings.showRecordings, recordingShown {
                out.append(Surfaces.savedActivity(saved, assetID: assetID(saved), create: false, features: features, style: style))
                savedUntil = now.addingTimeInterval(Self.savedDuration)
                savedCapture = saved
                savedStyle = style
                awaitingSaveUntil = nil
                return out
            }
            if fileComing, settings.showRecordings, recordingShown {
                if awaitingSaveUntil == nil { awaitingSaveUntil = now.addingTimeInterval(Self.saveWait) }
                return out
            }
            if recordingShown { out.append(dismissRecording()) }
        } else if !settings.showRecordings, recordingShown {
            out.append(dismissRecording())
        } else if let saved = savedCapture, savedUntil != nil, style != savedStyle {
            // The style changed while "saved" shows: the same moment, drawn the new way.
            out.append(Surfaces.savedActivity(saved, assetID: assetID(saved), create: false, features: features, style: style))
            savedStyle = style
        }

        if !firstLook, settings.showNewCaptures, savedUntil == nil, let newest = fresh.first(where: { $0.kind != .other }),
           now.timeIntervalSince(newest.createdAt) < Self.savedWindow {
            out.append(Surfaces.captureActivity(newest, assetID: assetID(newest), features: features))
            captureShown = true
            captureUntil = now.addingTimeInterval(Self.captureDuration)
        }
        return out
    }

    /// Copy ran for `id`: when "saved" shows that capture, it says so.
    public mutating func copied(_ id: UUID, features: HostFeatures) -> [JSON] {
        guard let capture = savedCapture, capture.id == id, savedUntil != nil else { return [] }
        return [Surfaces.copiedUpdate(capture, features: features)]
    }

    /// When `tick` next changes something, if anything shows: the clock's next second, or an activity to end.
    public var nextDeadline: Date? { [savedUntil ?? awaitingSaveUntil, captureUntil, clockAt].compactMap { $0 }.min() }

    /// Advances the compact clock and ends what has been on screen long enough.
    public mutating func tick(now: Date) -> [JSON] {
        var out: [JSON] = []
        if let status = clockStatus, let recording = status.recording, let at = clockAt, now >= at {
            if let clock = Surfaces.compactClock(status, now: now, style: clockStyle) {
                let text = clock.slot["text"] as? String
                if text != clockText { out.append(Surfaces.clockUpdate(clock.slot, recording: recording, style: clockStyle)); clockText = text }
                // A wake a moment early finds the same second: it waits for the next one rather than spinning.
                clockAt = clock.next.map { max($0, now.addingTimeInterval(0.05)) }
            } else {
                stopClock()
            }
        }
        if let until = savedUntil ?? awaitingSaveUntil, now >= until { out.append(dismissRecording()) }
        if let until = captureUntil, now >= until { out.append(dismissCapture()) }
        return out
    }

    private mutating func stopClock() {
        clockStatus = nil
        clockText = nil
        clockAt = nil
    }

    private mutating func dismissAll() -> [JSON] {
        var out: [JSON] = []
        if recordingShown { out.append(dismissRecording()) }
        if captureShown { out.append(dismissCapture()) }
        recordingKey = nil
        awaitingSaveUntil = nil
        return out
    }

    private mutating func dismissRecording() -> JSON {
        recordingShown = false
        stopClock()
        savedUntil = nil
        savedCapture = nil
        takeStartedAt = nil
        awaitingSaveUntil = nil
        return Surfaces.dismiss(Surfaces.recordingActivityID)
    }

    private mutating func dismissCapture() -> JSON {
        captureShown = false
        captureUntil = nil
        return Surfaces.dismiss(Surfaces.captureActivityID)
    }
}
