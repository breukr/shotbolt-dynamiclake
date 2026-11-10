import Foundation

/// The plugin's view of Shotbolt: the feed and the running app, and the ways to act on it. The executable's `MacLink` talks
/// to the real thing; tests pass their own.
public protocol ShotboltLink: AnyObject {
    func currentState(now: Date) -> ShotboltState
    /// A `shotbolt://` command without the scheme, such as `capture-area` or `copy-capture?id=…`.
    func send(_ command: String)
    func launchShotbolt()
    func openWebsite()
    /// The capture's file is written, so it can be dragged out.
    func fileReady(_ path: String) -> Bool
    /// Asks Shotbolt for its feed: it writes it only while a companion asked in the last few minutes.
    func subscribe()
}

/// The plugin's loop, without the socket: `handle` takes what DynamicLake sends, `tick` does what is due, and every command
/// for DynamicLake goes through `output`. Nothing runs on a clock of its own: the executable calls `tick` after each event (a
/// message, Shotbolt's change notification, Shotbolt quitting) and at `nextWake`, so an idle plugin sleeps.
public final class Plugin {
    /// A safety net only while Shotbolt is ready: it announces every change, and the executable hears it quit.
    public static let pollInterval: TimeInterval = 60
    /// While Shotbolt is not there (yet): how soon a launch, or an old Shotbolt without the feed, shows.
    public static let waitingPollInterval: TimeInterval = 10
    /// Shotbolt keeps its feed for 10 minutes after the last ask.
    public static let subscribeInterval: TimeInterval = 240
    /// While a capture's file is still being written, so it can be dragged as soon as it is.
    public static let lakeRefreshInterval: TimeInterval = 3
    /// After DynamicLake rejected something (its rate limit, say), the lake goes again whole, a few times at most.
    public static let retryAfterError: TimeInterval = 2
    public static let maxRetries = 3
    public static let copiedFeedback: TimeInterval = 1.2
    public static let closeAfterCopy: TimeInterval = 0.7
    /// After `closeLake`, so the lake is gone before an overlay or window opens.
    public static let actionAfterClose: TimeInterval = 0.3

    private let link: ShotboltLink
    private var features: HostFeatures
    private let loadSettings: () -> PluginSettings
    private let output: (JSON) throws -> Void
    private let log: (String) -> Void
    private let thumbnails: ThumbnailAssets

    private var settings: PluginSettings
    private var planner = ActivityPlanner()
    public private(set) var state: ShotboltState?
    public private(set) var lakeVisible = false
    private var lakeNeedsSend = true
    /// The lake as DynamicLake shows it, so the next one goes as a patch of what changed; nil means send it whole.
    private var lastLake: JSON?
    private var statusDirty = true
    private var nextPoll = Date.distantPast
    private var lastSubscribe = Date.distantPast
    private var nextLakeRefresh: Date?
    private var retries = 0
    private var retryAt: Date?
    private var copied: (id: UUID, until: Date)?
    /// The capture picked in the filmstrip, shown large until the lake closes.
    private var focusedID: UUID?
    private var moreOpen = false
    private var closeLakeAt: Date?
    private var delayed: [(at: Date, action: PluginAction)] = []

    public init(link: ShotboltLink, features: HostFeatures, loadSettings: @escaping () -> PluginSettings,
                thumbnails: ThumbnailAssets = ThumbnailAssets(), log: @escaping (String) -> Void = { _ in },
                output: @escaping (JSON) throws -> Void) {
        self.link = link
        self.features = features
        self.loadSettings = loadSettings
        self.settings = loadSettings()
        self.thumbnails = thumbnails
        self.log = log
        self.output = output
    }

    /// Shotbolt said its feed changed, or quit: read it on the next tick instead of waiting for the poll.
    public func markStatusChanged() { statusDirty = true }

    /// The Shotbolt process the feed came from, so the executable hears it quit.
    public var shotboltPID: Int32? { state?.status?.app.pid }

    public func handle(_ message: JSON, now: Date) throws {
        switch message["type"] as? String {
        case "lakeOpened":
            lakeVisible = true
            lakeNeedsSend = true
            statusDirty = true
            retries = 0
        case "lakeClosed":
            lakeVisible = false
            // Next time it opens on the newest capture, with More closed.
            focusedID = nil
            moreOpen = false
            lakeNeedsSend = true
        case "action":
            guard let id = message["actionID"] as? String else { return }
            guard let action = PluginAction(actionID: id) else { return log("unknown action \(id)") }
            try perform(action, now: now)
        case "error":
            let error = message["error"] as? String ?? "?"
            log("DynamicLake rejected a message: \(error)")
            if features.imageActions, error.contains("'actionID'") || error.contains("'title'") {
                // An older DynamicLake: no clickable pictures. The same lake without them, at once.
                features.imageActions = false
                lastLake = nil
                lakeNeedsSend = true
            } else if retries < Self.maxRetries {
                // A rejected lake or patch leaves the lake as it was: send it whole in a moment, a few times at most.
                retries += 1
                lastLake = nil
                retryAt = now.addingTimeInterval(Self.retryAfterError)
            }
        case "response":
            if message["ok"] as? Bool == false { log("DynamicLake: \(message)") }
        default:
            break
        }
    }

    public func tick(now: Date) throws {
        let latestSettings = loadSettings()
        var replan = false
        if latestSettings != settings { settings = latestSettings; replan = true }

        if now >= lastSubscribe.addingTimeInterval(Self.subscribeInterval) { subscribe(now) }
        if statusDirty || now >= nextPoll {
            statusDirty = false
            let latest = link.currentState(now: now)
            nextPoll = now.addingTimeInterval(latest.status == nil ? Self.waitingPollInterval : Self.pollInterval)
            // No feed from the Shotbolt that runs: it may have just started, or let the feed lapse. Ask again.
            if latest.status == nil, now >= lastSubscribe.addingTimeInterval(2) { subscribe(now) }
            if latest != state {
                state = latest
                lakeNeedsSend = true
                replan = true
                retries = 0
            }
        }
        if replan, let state { try send(planner.update(state, settings: settings, features: features, now: now, assetID: assetID)) }
        try send(planner.tick(now: now))

        for (index, item) in delayed.enumerated().reversed() where now >= item.at {
            delayed.remove(at: index)
            run(item.action)
        }
        if let copied, now >= copied.until { self.copied = nil; lakeNeedsSend = true }
        if let closeAt = closeLakeAt, now >= closeAt {
            closeLakeAt = nil
            try output(Surfaces.closeLake())
        }
        if let at = retryAt, now >= at { retryAt = nil; lakeNeedsSend = true }
        if lakeVisible, let at = nextLakeRefresh, now >= at {
            nextLakeRefresh = nil
            lakeNeedsSend = true // a time ("2 min ago") changed, or a file finished writing
        }
        if lakeNeedsSend {
            lakeNeedsSend = false
            if features.lake, let state {
                try sendLake(state, now: now)
                scheduleLakeRefresh(state, now: now)
            }
        }
    }

    /// When `tick` next has something to do: the earliest deadline (copy feedback, a delayed action, an activity to end, the
    /// lake's times while it shows), and at the latest the next poll. The past means now.
    public func nextWake(now: Date) -> Date {
        if statusDirty || lakeNeedsSend { return now }
        var wake = nextPoll
        for case let deadline? in [planner.nextDeadline, copied?.until, closeLakeAt, delayed.map(\.at).min(), retryAt,
                                   lastSubscribe.addingTimeInterval(Self.subscribeInterval),
                                   lakeVisible ? nextLakeRefresh : nil] {
            wake = min(wake, deadline)
        }
        return max(wake, now)
    }

    private func perform(_ action: PluginAction, now: Date) throws {
        switch action {
        case .focus(let id):
            focusedID = id
            lakeNeedsSend = true
            return
        case .toggleMore:
            moreOpen.toggle()
            lakeNeedsSend = true
            return
        case .copy(let id):
            run(action)
            // From Shotbolt 1.3, Copy on a video edited in its video editor first asks "Share edited or original?" in a toast,
            // and the feed does not say which videos were edited. So a video gets no check in the lake or DynaGlance: it could
            // claim a copy that has not happened yet. The lake still closes, so Shotbolt's own toast shows. Older Shotbolts copy
            // a video at once, so there the missing check only costs a little feedback.
            if state?.status?.captures.first(where: { $0.id == id })?.kind != .video {
                copied = (id, now.addingTimeInterval(Self.copiedFeedback))
                lakeNeedsSend = true
            }
            // The saved take's sneak peek keeps its "Copied": that take was saved seconds ago, too soon to have been edited.
            try send(planner.copied(id, features: features))
            if lakeVisible, features.lakeLayout { closeLakeAt = now.addingTimeInterval(Self.closeAfterCopy) }
            return
        default:
            break
        }
        if action.closesLakeFirst, lakeVisible, features.lakeLayout {
            try output(Surfaces.closeLake())
            delayed.append((now.addingTimeInterval(Self.actionAfterClose), action))
            return
        }
        run(action)
    }

    private func run(_ action: PluginAction) {
        switch action {
        case .launchShotbolt: link.launchShotbolt()
        case .getShotbolt: link.openWebsite()
        default:
            if let command = action.shotboltCommand { link.send(command) }
        }
        statusDirty = true
    }

    private func subscribe(_ now: Date) {
        lastSubscribe = now
        link.subscribe()
    }

    private func assetID(_ capture: ShotboltStatus.Capture) -> String? {
        features.imageAssets ? thumbnails.assetID(for: capture) : nil
    }

    private func send(_ commands: [JSON]) throws {
        guard !commands.isEmpty else { return }
        for asset in thumbnails.takePending() { try output(asset) }
        for command in commands { try output(command) }
    }

    private func sendLake(_ state: ShotboltState, now: Date) throws {
        var context = Surfaces.LakeContext(assetID: assetID, canDrag: { [link] in link.fileReady($0.file) }, copiedID: copied?.id,
                                           focusedID: focusedID, moreOpen: moreOpen, imageActions: features.imageActions, now: now)
        if features.imageAssets { context.blank = { [thumbnails] in thumbnails.blankID() } }
        let lake = Surfaces.lake(state, context: context, features: features)
        for asset in thumbnails.takePending() { try output(asset) }
        // Without lakeLayout there is no lakePatch: the whole lake, when it changed.
        let patches = features.lakeLayout ? LakeDiff.patches(from: lastLake, to: lake) : lastLake.flatMap { NSDictionary(dictionary: $0).isEqual(to: lake) ? [] : nil }
        switch patches {
        case let patches? where patches.isEmpty: return
        case let patches?: for command in LakeDiff.commands(patches) { try output(command) }
        case nil: try output(Surfaces.lakeCommand(lake))
        }
        lastLake = lake
    }

    /// When the lake that was just sent goes out of date by itself: a file that finishes writing can be dragged, and "Just now"
    /// becomes "1 min ago".
    private func scheduleLakeRefresh(_ state: ShotboltState, now: Date) {
        let captures = Array(state.status?.captures.prefix(Surfaces.maxLakeRows) ?? [])
        // A file or a thumbnail still being written: look again soon, so the picture shows once it is there.
        let writing = captures.contains { !link.fileReady($0.file) || $0.thumbnail.map { !link.fileReady($0) } == true }
        nextLakeRefresh = writing ? now.addingTimeInterval(Self.lakeRefreshInterval) : Surfaces.nextTimeChange(captures.map(\.createdAt), now: now)
    }
}
