import Foundation

/// Shotbolt's status feed, `Application Support/Shotbolt/Integrations/status.json`, as this plugin
/// reads it. Its own copy of the types: the plugin never links the app. Values this version does not know (a new capture kind,
/// a new recording state) decode as `.other` instead of failing the whole file. `Tests/Fixtures/status-v1.json` is the contract
/// both sides test against.
///
/// Any process of this user can write that file, so nothing in it is trusted: numbers and dates are kept only within sane
/// ranges (see `seconds` and `dates`), and at most `maxCaptures` captures are read. One odd value must never stop the plugin,
/// because DynamicLake does not start a plugin again after it quits.
public struct ShotboltStatus: Decodable, Equatable, Sendable {
    /// The newest schema this plugin understands. A newer file means the plugin needs an update.
    public static let supportedSchema = 1

    /// Lengths and recorded time in seconds: a week at most. Shotbolt writes far less; anything outside is a broken file.
    public static let seconds: ClosedRange<Double> = 0...(7 * 24 * 3600)
    /// Dates from 1970 to 2500. Within this every date turns into whole seconds without overflow (a far-off date otherwise can).
    public static let dates = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 16_725_225_600)
    /// Shotbolt lists 12; a few more leave room for kinds a newer Shotbolt adds (they are skipped as `.other`), and a cap keeps
    /// an enormous list from growing memory.
    public static let maxCaptures = 50
    /// A countdown longer than this is not one Shotbolt runs: it is dropped and the take shows as starting.
    static let maxCountdown: TimeInterval = 3600

    public var schemaVersion: Int
    /// Shotbolt's "Let other apps control Shotbolt" switch (shotbolt:// links and scripts; Settings, Workflows from 1.3,
    /// Advanced before). Off: no recording and no captures, and buttons would do nothing.
    public var enabled: Bool
    public var app: App
    public var recording: Recording?
    /// Newest first. A capture this version cannot read is left out, not the whole file.
    public var captures: [Capture]
    public var updatedAt: Date
    /// Shotbolt Pro: Pro-only actions show only then, so the notch never sells anything.
    public var pro: Bool
    /// How the last take ended, for two minutes after; nil before the first take and once those two minutes pass.
    public var lastTake: LastTake?

    public struct App: Decodable, Equatable, Sendable {
        public var version: String
        public var build: String
        public var pid: Int32

        public init(version: String, build: String, pid: Int32) {
            self.version = version; self.build = build; self.pid = pid
        }
    }

    public struct Recording: Decodable, Equatable, Sendable {
        public enum State: String, Sendable { case starting, recording, paused, saving, converting, other }
        public enum Kind: String, Sendable { case video, gif, other }

        public var state: State
        public var kind: Kind
        /// Seconds recorded at the feed's `updatedAt`, without the time paused.
        public var elapsed: Double
        public var countdownEndsAt: Date?

        public init(state: State, kind: Kind, elapsed: Double, countdownEndsAt: Date? = nil) {
            self.state = state; self.kind = kind; self.elapsed = elapsed; self.countdownEndsAt = countdownEndsAt
        }

        private enum Key: String, CodingKey { case state, kind, elapsed, countdownEndsAt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            // Out of range (or not a number at all) clamps: the take is still shown, with a time that makes sense.
            let elapsed = (try? c.decodeIfPresent(Double.self, forKey: .elapsed)).flatMap { $0 }
            self.init(state: try c.decode(State.self, forKey: .state), kind: try c.decode(Kind.self, forKey: .kind),
                      elapsed: ShotboltStatus.clampedSeconds(elapsed ?? 0),
                      countdownEndsAt: (try? c.decodeIfPresent(Date.self, forKey: .countdownEndsAt)).flatMap { $0 })
        }
    }

    public struct Capture: Decodable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case screenshot, video, gif, other }

        public var id: UUID
        public var kind: Kind
        /// One the person typed, or the automatic one when Shotbolt organises by content.
        public var title: String?
        public var createdAt: Date
        public var file: String
        public var thumbnail: String?
        public var width: Int
        public var height: Int
        public var saved: Bool
        /// Seconds, for videos and GIFs once Shotbolt measured them.
        public var duration: Double?
        /// The Keep star in History.
        public var kept: Bool
        /// The app under the capture, when Shotbolt knows it ("Safari").
        public var app: String?
        /// Shotbolt's content category ("code", "chat", ...), when it organises by content.
        public var category: String?

        public init(id: UUID, kind: Kind, title: String? = nil, createdAt: Date, file: String, thumbnail: String? = nil,
                    width: Int, height: Int, saved: Bool = false, duration: Double? = nil, kept: Bool = false,
                    app: String? = nil, category: String? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.createdAt = createdAt; self.file = file
            self.thumbnail = thumbnail; self.width = width; self.height = height; self.saved = saved
            self.duration = duration; self.kept = kept; self.app = app; self.category = category
        }

        private enum Key: String, CodingKey { case id, kind, title, createdAt, file, thumbnail, width, height, saved, duration, kept, app, category }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            self.init(id: try c.decode(UUID.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
                      title: try c.decodeIfPresent(String.self, forKey: .title), createdAt: try c.decode(Date.self, forKey: .createdAt),
                      file: try c.decode(String.self, forKey: .file), thumbnail: try c.decodeIfPresent(String.self, forKey: .thumbnail),
                      width: try c.decodeIfPresent(Int.self, forKey: .width) ?? 0, height: try c.decodeIfPresent(Int.self, forKey: .height) ?? 0,
                      saved: try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false,
                      duration: (try? c.decodeIfPresent(Double.self, forKey: .duration)).flatMap { $0 }.flatMap(ShotboltStatus.validSeconds),
                      kept: (try? c.decodeIfPresent(Bool.self, forKey: .kept)) ?? false,
                      app: try? c.decodeIfPresent(String.self, forKey: .app), category: try? c.decodeIfPresent(String.self, forKey: .category))
        }
    }

    public struct LastTake: Decodable, Equatable, Sendable {
        public enum Outcome: String, Sendable { case saved, discarded, failed, other }

        public var endedAt: Date
        public var outcome: Outcome
        /// The saved capture.
        public var capture: UUID?

        public init(endedAt: Date, outcome: Outcome, capture: UUID? = nil) {
            self.endedAt = endedAt; self.outcome = outcome; self.capture = capture
        }
    }

    public init(schemaVersion: Int = ShotboltStatus.supportedSchema, enabled: Bool = true, app: App, recording: Recording? = nil,
                captures: [Capture] = [], updatedAt: Date, pro: Bool = false, lastTake: LastTake? = nil) {
        self.schemaVersion = schemaVersion; self.enabled = enabled; self.app = app; self.recording = recording
        self.captures = captures; self.updatedAt = updatedAt; self.pro = pro; self.lastTake = lastTake
    }

    private enum Key: String, CodingKey { case schemaVersion, enabled, app, recording, captures, updatedAt, pro, lastTake }

    public init(from decoder: Decoder) throws {
        /// One capture that does not decode (a bad date from a future build) is skipped.
        struct Lossy: Decodable {
            let capture: Capture?
            init(from decoder: Decoder) throws { capture = try? Capture(from: decoder) }
        }
        let c = try decoder.container(keyedBy: Key.self)
        // The newest `maxCaptures` only: the rest of a longer list is never decoded.
        var captures: [Capture] = []
        if c.contains(.captures), try c.decodeNil(forKey: .captures) == false {
            var list = try c.nestedUnkeyedContainer(forKey: .captures)
            var read = 0
            while !list.isAtEnd, read < Self.maxCaptures {
                read += 1
                if let capture = try list.decode(Lossy.self).capture { captures.append(capture) }
            }
        }
        let updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        var recording = (try? c.decodeIfPresent(Recording.self, forKey: .recording)).flatMap { $0 }
        if let end = recording?.countdownEndsAt, abs(end.timeIntervalSince(updatedAt)) > Self.maxCountdown { recording?.countdownEndsAt = nil }
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion), enabled: try c.decode(Bool.self, forKey: .enabled),
                  app: try c.decode(App.self, forKey: .app), recording: recording, captures: captures, updatedAt: updatedAt,
                  pro: (try? c.decodeIfPresent(Bool.self, forKey: .pro)) ?? false,
                  lastTake: (try? c.decodeIfPresent(LastTake.self, forKey: .lastTake)).flatMap { $0 })
    }

    /// `value` when it is a length Shotbolt could write, else nil.
    static func validSeconds(_ value: Double) -> Double? { value.isFinite && Self.seconds.contains(value) ? value : nil }

    /// `value` pulled into `seconds` (not a number: 0).
    static func clampedSeconds(_ value: Double) -> Double {
        value.isFinite ? min(max(value, Self.seconds.lowerBound), Self.seconds.upperBound) : 0
    }

    public static func decode(_ data: Data) throws -> ShotboltStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
            // A far-off date fails like a malformed one: the capture is skipped, an optional date dropped.
            guard let date, ShotboltStatus.dates.contains(date) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date in range: \(text.prefix(40))"))
            }
            return date
        }
        return try decoder.decode(ShotboltStatus.self, from: data)
    }

    /// The feed with each thumbnail kept only when the file really lies inside `folder` (Shotbolt's own support folder, the one
    /// that holds the feed), after following `..` and symbolic links as the system does. The path from the feed is replaced by
    /// that real path, so what is read later is what was checked. A picture not written yet keeps its place: its folder is
    /// checked instead and the plain file name added, so it shows by itself once Shotbolt writes it. Anything else gets the
    /// placeholder. Capture files themselves are not limited: they live wherever the person saves them.
    public func keepingThumbnails(inside folder: URL) -> ShotboltStatus {
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        /// The real path of `path`, or for a file that does not exist yet, its real folder and its own name.
        func resolve(_ path: String) -> String? {
            if let resolved = real(path) { return resolved }
            let name = (path as NSString).lastPathComponent
            guard path.hasPrefix("/"), !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  let parent = real((path as NSString).deletingLastPathComponent) else { return nil }
            let candidate = (parent as NSString).appendingPathComponent(name)
            // Something is there that cannot be followed (a link to nowhere): it could point anywhere later, so no.
            var info = stat()
            return lstat(candidate, &info) == 0 ? nil : candidate
        }
        var copy = self
        let root = real(folder.path).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for index in copy.captures.indices {
            guard let path = copy.captures[index].thumbnail else { continue }
            if let root, let resolved = resolve(path), resolved.hasPrefix(root) {
                copy.captures[index].thumbnail = resolved
            } else {
                copy.captures[index].thumbnail = nil
            }
        }
        return copy
    }

    /// The moment a running take started, without its pauses: what a counting-up timer starts from.
    public func recordingStart() -> Date? {
        guard let recording else { return nil }
        return updatedAt.addingTimeInterval(-recording.elapsed)
    }
}

extension ShotboltStatus.Recording.State: Decodable {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

extension ShotboltStatus.Recording.Kind: Decodable {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

extension ShotboltStatus.LastTake.Outcome: Decodable {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

extension ShotboltStatus.Capture.Kind: Decodable {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// What the plugin knows about Shotbolt at this moment.
public enum ShotboltState: Equatable, Sendable {
    /// No Shotbolt on this Mac.
    case notInstalled
    case notRunning
    /// Shotbolt runs but has not written a feed for this launch: a version from before the feed.
    case needsUpdate
    /// The feed is newer than this plugin understands.
    case pluginOutdated
    /// "Let other apps control Shotbolt" is off.
    case disabled
    case ready(ShotboltStatus)

    public var status: ShotboltStatus? {
        if case .ready(let status) = self { return status }
        return nil
    }

    /// Decides from what the Mac says. `runningPIDs` are the processes with Shotbolt's bundle id; `launchedAt` the oldest one's
    /// launch. A Shotbolt that launched a moment ago has not written its feed yet, so it counts as not running for a few seconds
    /// rather than as one that needs an update.
    public static func resolve(installed: Bool, runningPIDs: [Int32], launchedAt: Date?, status: ShotboltStatus?, now: Date,
                               startupGrace: TimeInterval = 10) -> ShotboltState {
        guard !runningPIDs.isEmpty else { return installed ? .notRunning : .notInstalled }
        guard let status, runningPIDs.contains(status.app.pid) else {
            if let launchedAt, now.timeIntervalSince(launchedAt) < startupGrace { return .notRunning }
            return .needsUpdate
        }
        if status.schemaVersion > ShotboltStatus.supportedSchema { return .pluginOutdated }
        return status.enabled ? .ready(status) : .disabled
    }
}
