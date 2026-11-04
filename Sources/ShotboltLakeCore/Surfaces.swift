import Foundation

/// The JSON DynamicLake renders, built from Shotbolt's state. Pure functions: tests and `--demo-json` call them with any state.
///
/// Look: SF Symbols and DynamicLake's own components, quiet gray chrome, red only for a take that records (the menu bar's
/// stop button is red too), DynamicLake's gray paused mark, green for saved and copied, blue for the one main action (Copy). No file names
/// as titles: a capture without one is named by its app, its kind of content, or its kind.
public enum Surfaces {
    public static let recordingActivityID = "recording"
    public static let captureActivityID = "capture"
    /// The lake's own budget (DynamicLake rejects more): captures in the lake and in DynaGlance.
    public static let maxLakeRows = 12
    public static let maxGlanceRows = 6

    /// Sizes and gaps in points inside DynamicLake's big lake (540 × 230 before its own insets). Buttons follow DynaPaste,
    /// DynamicLake's own lake: 26 pt labeled, 24 pt symbols.
    enum Metrics {
        /// The capture shown large, and the filmstrip's tiles.
        static let band = 72.0, bandRadius = 12.0
        static let tile = 52.0, tileRadius = 9.0
        static let glanceThumb = 26.0, glanceRadius = 6.0
        /// Labeled buttons, plain symbol buttons in the toolbar, and in DynaGlance's narrow side.
        static let capsule = 26.0, toolbarSymbol = 24.0, glanceSymbol = 20.0
        /// Between the toolbar and the band, so both section gaps read alike (the strip's scroll brings its own inset).
        static let section = 8.0
        /// Between buttons in a row, the take row's parts, the band's picture and text, the text's lines, the filmstrip's tiles.
        static let row = 6.0, take = 8.0, bandGap = 12.0, textGap = 4.0, strip = 8.0
        /// The take's mark in the lake and in DynaGlance; a title and its Keep star; the notice's lines.
        static let takeMark = 20.0, glanceMark = 16.0, titleGap = 5.0, noticeGap = 3.0
    }

    // MARK: Words

    public static func kindName(_ kind: ShotboltStatus.Capture.Kind) -> String {
        switch kind {
        case .screenshot, .other: "Screenshot"
        case .video: "Video"
        case .gif: "GIF"
        }
    }

    /// Shotbolt's content categories, as History names them.
    static let categories: [String: (name: String, symbol: String)] = [
        "code": ("Code", "chevron.left.forwardslash.chevron.right"), "terminal": ("Terminal", "apple.terminal"),
        "chat": ("Chat", "bubble.left.and.bubble.right"), "email": ("Email", "envelope"), "document": ("Document", "doc.text"),
        "web": ("Web", "globe"), "table": ("Table", "tablecells"), "receipt": ("Receipt", "receipt"),
        "design": ("Design", "paintpalette"), "settings": ("Settings", "gearshape"), "photo": ("Photo", "photo"),
        "chart": ("Chart", "chart.bar.xaxis"), "map": ("Map", "map"),
    ]

    /// The title History shows (typed, or automatic when Shotbolt organises by content), else the app it came from, else the
    /// kind of content, else the kind. Never the file name.
    public static func title(of capture: ShotboltStatus.Capture) -> String {
        let candidates = [capture.title, capture.app, capture.category.flatMap { categories[$0]?.name }]
        let title = candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return oneLine(title ?? kindName(capture.kind), limit: 60)
    }

    /// The kind when the title is something else, the length of a video or GIF: "Video · 1:05".
    static func details(of capture: ShotboltStatus.Capture) -> [String] {
        var parts: [String] = []
        if title(of: capture) != kindName(capture.kind) { parts.append(kindName(capture.kind)) }
        if capture.kind == .video || capture.kind == .gif, let length = capture.duration, length >= 0.5 { parts.append(duration(length)) }
        return parts
    }

    /// "Video · 1:05 · 5 min ago", "Screenshot · Just now", or "5 min ago" when the title already says it all.
    public static func subtitle(of capture: ShotboltStatus.Capture, now: Date) -> String {
        oneLine((details(of: capture) + [relativeTime(capture.createdAt, now: now)]).joined(separator: " · "))
    }

    /// A tile's tooltip: what it is, without a time that would go stale.
    static func tooltip(of capture: ShotboltStatus.Capture) -> String {
        oneLine(([title(of: capture)] + details(of: capture)).joined(separator: " · "))
    }

    public static func relativeTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) hr ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// When the first of these `relativeTime`s reads differently, so the lake is refreshed then and not on a clock.
    public static func nextTimeChange(_ dates: [Date], now: Date, calendar: Calendar = .current) -> Date? {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return dates.compactMap { date -> Date? in
            let seconds = now.timeIntervalSince(date)
            if seconds < 0 { return date }
            if seconds < 3600 { return date.addingTimeInterval(60 * ((seconds / 60).rounded(.down) + 1)) }
            let nextHour = date.addingTimeInterval(3600 * ((seconds / 3600).rounded(.down) + 1))
            return calendar.isDate(date, inSameDayAs: now) ? min(nextHour, midnight ?? nextHour) : midnight
        }.min()
    }

    /// "1:05" or "1:02:05".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func oneLine(_ text: String, limit: Int = 80) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    // MARK: Components

    static func symbol(_ name: String, tint: String? = nil, size: Double? = nil, id: String? = nil) -> JSON {
        var image: JSON = ["type": "image", "source": "sfSymbol", "systemImage": name]
        if let tint { image["tint"] = tint }
        if let size { image["size"] = size }
        if let id { image["id"] = id }
        return image
    }

    static func text(_ value: String, style: String? = nil, tint: String? = nil, weight: String? = nil, id: String? = nil) -> JSON {
        var text: JSON = ["type": "text", "text": value]
        if let style { text["style"] = style }
        if let tint { text["tint"] = tint }
        if let weight { text["weight"] = weight }
        if let id { text["id"] = id }
        return text
    }

    static func button(_ action: PluginAction, symbol: String, title: String, tint: String? = nil, shape: String? = nil,
                       size: Double? = nil, role: String? = nil, id: String? = nil) -> JSON {
        var button: JSON = ["type": "button", "actionID": action.actionID, "systemImage": symbol, "title": title]
        if let tint { button["tint"] = tint }
        if let shape { button["shape"] = shape }
        if let size { button["size"] = size }
        if let role { button["role"] = role }
        if let id { button["id"] = id }
        return button
    }

    /// A labeled button in the lake.
    static func capsule(_ action: PluginAction, symbol: String, title: String, tint: String = "gray", role: String? = nil,
                        id: String) -> JSON {
        button(action, symbol: symbol, title: title, tint: tint, shape: "roundedRect", size: Metrics.capsule, role: role, id: id)
    }

    /// A count-up from the take's start; DynamicLake ticks it every second. Paused, it stops at the time recorded so far.
    static func recordingTimer(_ status: ShotboltStatus, now: Date, id: String? = nil) -> JSON {
        let elapsed = status.recording?.elapsed ?? 0
        var timer: JSON
        if status.recording?.state == .paused {
            timer = ["type": "timer", "countsDown": false, "tint": "white",
                     "startDate": iso(now.addingTimeInterval(-max(1, elapsed))), "endDate": iso(now)]
        } else {
            let start = status.recordingStart() ?? now
            timer = ["type": "timer", "countsDown": false, "tint": "white", "startDate": iso(start),
                     "endDate": iso(start.addingTimeInterval(24 * 3600))]
        }
        if let id { timer["id"] = id }
        return timer
    }

    /// The countdown before a take, while there is one.
    static func countdown(_ recording: ShotboltStatus.Recording, now: Date, id: String? = nil) -> JSON? {
        guard let end = recording.countdownEndsAt, end.timeIntervalSince(now) >= 1 else { return nil }
        var timer: JSON = ["type": "timer", "startDate": iso(now), "endDate": iso(end)]
        if let id { timer["id"] = id }
        return timer
    }

    static func placeholderSymbol(_ capture: ShotboltStatus.Capture) -> String {
        if let symbol = capture.category.flatMap({ categories[$0]?.symbol }) { return symbol }
        return capture.kind == .video ? "film" : capture.kind == .gif ? "photo.stack" : "photo"
    }

    /// The capture's picture, `size` points square, or (no thumbnail yet) its symbol on a dark square of the same size (`blank`,
    /// an asset) so nothing moves when the picture arrives. Without `size` (live activity slots) the slot sizes it.
    static func thumbnail(_ capture: ShotboltStatus.Capture, assetID: String?, size: Double?, radius: Double = 0,
                          blank: () -> String? = { nil }, id: String) -> JSON {
        guard let assetID else {
            guard let size else { return symbol(placeholderSymbol(capture), tint: "gray", id: id) }
            let glyph = max(12, (size * 0.42).rounded())
            guard let blank = blank() else {
                var image = symbol(placeholderSymbol(capture), tint: "gray", size: glyph, id: id)
                image["padding"] = ((size - glyph) / 2).rounded(.down)
                return image
            }
            return ["type": "zstack", "id": id, "children": [
                ["type": "image", "id": "\(id)-blank", "source": "asset", "assetID": blank, "size": size, "contentMode": "fill",
                 "cornerRadius": radius],
                symbol(placeholderSymbol(capture), tint: "gray", size: glyph, id: "\(id)-glyph"),
            ]]
        }
        var image: JSON = ["type": "image", "id": id, "source": "asset", "assetID": assetID]
        if let size {
            image["size"] = size
            image["contentMode"] = "fill"
            if radius > 0 { image["cornerRadius"] = radius }
        }
        return image
    }

    // MARK: Live activities

    /// The live activity of a take, from the countdown to "saving". Nil for a state this version does not know.
    public static func recordingActivity(_ status: ShotboltStatus, now: Date, create: Bool, features: HostFeatures) -> JSON? {
        guard let recording = status.recording else { return nil }
        let gif = recording.kind == .gif
        let compact: JSON
        let peek: JSON
        switch recording.state {
        case .starting:
            let timer = countdown(recording, now: now)
            compact = ["leftSlot": symbol("record.circle", tint: "red"), "rightSlot": timer ?? ["type": "progress"]]
            var starting: JSON = [
                "leftSlot": button(.stopRecording, symbol: "xmark", title: "Cancel", tint: "white", id: "cancel"),
                "center": text(timer == nil ? (gif ? "GIF starts" : "Recording starts") : "Recording in", style: "compact"),
            ]
            if let timer { starting["rightSlot"] = timer }
            peek = starting
        case .recording, .paused:
            let paused = recording.state == .paused
            compact = ["leftSlot": takeMark(recording, size: nil, id: nil), "rightSlot": recordingTimer(status, now: now)]
            peek = [
                "leftSlot": paused
                    ? button(.pauseRecording, symbol: "play.fill", title: "Resume", tint: "white", id: "pause")
                    : button(.pauseRecording, symbol: "pause.fill", title: "Pause", tint: "white", id: "pause"),
                "center": text(paused ? "Paused" : gif ? "Recording GIF" : "Recording", style: "compact"),
                "rightSlot": button(.stopRecording, symbol: "stop.fill", title: "Stop", tint: "red", role: "destructive", id: "stop"),
            ]
        case .saving, .converting:
            compact = ["leftSlot": ["type": "status", "status": "inProgress", "tint": "gray"], "rightSlot": ["type": "progress"]]
            peek = ["leftSlot": ["type": "status", "status": "inProgress", "tint": "gray"],
                    "center": text(recording.state == .converting ? "Making GIF" : "Saving video", style: "compact")]
        case .other:
            return nil
        }
        var surfaces: JSON = ["compactLiveActivity": compact, "sneakPeek": peek]
        // The side capsule, when another live activity has the notch: just the dot.
        surfaces["extraLiveActivity"] = ["leftSlot": compact["leftSlot"] as Any]
        // Large: DynamicLake's timer reads 00:00:00, which a normal compact slot cuts off.
        return activityCommand(create: create, id: recordingActivityID, title: "Shotbolt", priority: "normal", size: "large",
                               surfaces: surfaces, presentSneakPeek: nil, features: features)
    }

    /// What opens a saved take: the video editor, or the GIF.
    static func openAction(_ capture: ShotboltStatus.Capture) -> (symbol: String, title: String) {
        switch capture.kind {
        case .video: ("slider.horizontal.below.rectangle", "Edit Video")
        case .gif: ("arrow.up.forward.app", "Open")
        case .screenshot, .other: ("pencil.tip.crop.circle", "Annotate")
        }
    }

    /// A take was saved: the same activity turns green for a moment, with its length and Copy.
    public static func savedActivity(_ capture: ShotboltStatus.Capture, assetID: String?, create: Bool, features: HostFeatures) -> JSON {
        // No clickable picture here: a host that does not know image actions would reject the whole update.
        let picture = thumbnail(capture, assetID: assetID, size: nil, id: "saved-thumb")
        let label = [capture.kind == .gif ? "GIF saved" : "Video saved"] + (capture.duration.map { [duration($0)] } ?? [])
        let surfaces: JSON = [
            "compactLiveActivity": ["leftSlot": ["type": "status", "status": "success", "tint": "green"], "rightSlot": picture],
            // The check under the compact's check, as DynamicLake's sneak peek rules ask; Edit Video is in the lake.
            "sneakPeek": ["leftSlot": ["type": "status", "status": "success", "tint": "green", "id": "saved-mark"],
                          "center": text(label.joined(separator: " · "), style: "compact", id: "saved-label"),
                          "rightSlot": button(.copy(capture.id), symbol: "doc.on.doc", title: "Copy", tint: "blue", id: "saved-copy")],
            "extraLiveActivity": ["leftSlot": ["type": "status", "status": "success", "tint": "green"]],
        ]
        return activityCommand(create: create, id: recordingActivityID, title: "Shotbolt", priority: "normal", size: "large",
                               surfaces: surfaces, presentSneakPeek: 3, features: features)
    }

    /// Copy ran from the saved take's sneak peek: it says so.
    public static func copiedUpdate(_ capture: ShotboltStatus.Capture, features: HostFeatures) -> JSON {
        let surfaces: JSON = [
            "sneakPeek": ["leftSlot": ["type": "status", "status": "success", "tint": "green", "id": "saved-mark"],
                          "center": text("Copied", style: "compact", id: "saved-label"),
                          "rightSlot": button(.copy(capture.id), symbol: "checkmark", title: "Copied", tint: "green", id: "saved-copy")],
        ]
        return activityCommand(create: false, id: recordingActivityID, title: "Shotbolt", priority: "normal", size: "large",
                               surfaces: surfaces, presentSneakPeek: 2, features: features)
    }

    /// A new capture for a few seconds ("Show New Screenshots").
    public static func captureActivity(_ capture: ShotboltStatus.Capture, assetID: String?, features: HostFeatures) -> JSON {
        let surfaces: JSON = [
            "compactLiveActivity": ["leftSlot": ["type": "image", "source": "appIcon"],
                                    "rightSlot": thumbnail(capture, assetID: assetID, size: nil, id: "capture-thumb")],
            "sneakPeek": ["leftSlot": thumbnail(capture, assetID: assetID, size: nil, id: "capture-peek-thumb"),
                          "center": text(title(of: capture), style: "marquee"),
                          "rightSlot": button(.copy(capture.id), symbol: "doc.on.doc", title: "Copy", tint: "blue", id: "capture-copy")],
        ]
        return activityCommand(create: true, id: captureActivityID, title: "Shotbolt", priority: "low", size: "normal",
                               surfaces: surfaces, presentSneakPeek: 2, features: features)
    }

    public static func dismiss(_ activityID: String) -> JSON {
        ["schemaVersion": pluginSchemaVersion, "type": "dismiss", "activityID": activityID]
    }

    static func activityCommand(create: Bool, id: String, title: String, priority: String, size: String, surfaces: JSON,
                                presentSneakPeek: Int?, features: HostFeatures) -> JSON {
        var command: JSON = ["schemaVersion": pluginSchemaVersion, "type": create ? "create" : "update", "activityID": id,
                             "surfaces": surfaces]
        if create { command["title"] = title; command["priority"] = priority; command["size"] = size }
        if let presentSneakPeek, features.presentSneakPeek { command["presentSneakPeek"] = presentSneakPeek }
        return command
    }

    // MARK: Lake

    /// What the lake needs besides the state: thumbnails registered as assets, which file can be dragged, which Copy just ran,
    /// which capture shows large, and whether the More row is open.
    public struct LakeContext {
        public var assetID: (ShotboltStatus.Capture) -> String?
        /// A plain dark square asset for pictures not written yet (`ThumbnailAssets.blankID`); nil draws just the symbol.
        public var blank: () -> String? = { nil }
        public var canDrag: (ShotboltStatus.Capture) -> Bool
        public var copiedID: UUID?
        /// The capture the person picked in the filmstrip; the newest when nil or gone.
        public var focusedID: UUID?
        public var moreOpen: Bool
        /// The host takes clickable images (`HostFeatures.imageActions`).
        public var imageActions: Bool
        public var now: Date

        public init(assetID: @escaping (ShotboltStatus.Capture) -> String? = { _ in nil },
                    canDrag: @escaping (ShotboltStatus.Capture) -> Bool = { _ in true }, copiedID: UUID? = nil,
                    focusedID: UUID? = nil, moreOpen: Bool = false, imageActions: Bool = true, now: Date) {
            self.assetID = assetID; self.canDrag = canDrag; self.copiedID = copiedID; self.focusedID = focusedID
            self.moreOpen = moreOpen; self.imageActions = imageActions; self.now = now
        }
    }

    public static func lakeCommand(_ lake: JSON) -> JSON {
        ["schemaVersion": pluginSchemaVersion, "type": "lake", "lake": lake]
    }

    public static func closeLake() -> JSON { ["schemaVersion": pluginSchemaVersion, "type": "closeLake"] }

    /// The captures the lake shows, newest first.
    public static func lakeCaptures(_ status: ShotboltStatus) -> [ShotboltStatus.Capture] {
        Array(status.captures.filter { $0.kind != .other }.prefix(maxLakeRows))
    }

    /// The whole lake for `state`: the toolbar (or the take while one runs), the focused capture large with its actions, and the
    /// filmstrip of the rest. Hosts without `lakeLayout` only show a header row. Ids are unique across the lake and its glance,
    /// so `lakePatch` can replace any of them.
    public static func lake(_ state: ShotboltState, context: LakeContext, features: HostFeatures) -> JSON {
        guard features.lakeLayout else { return basicLake(state, context: context) }
        guard let status = state.status else {
            // Centered in the lake: spacers above and below take the free height (the lake keeps its size in every state).
            let message = message(for: state)
            return ["hideHeader": true, "content": [spacer()] + notice(message, prefix: "") + [spacer()],
                    "glance": ["hideHeader": true, "content": [spacer()] + notice(message, prefix: "glance-") + [spacer()]]]
        }
        let captures = lakeCaptures(status)
        var content: [JSON] = [status.recording == nil ? toolbar(moreOpen: context.moreOpen) : recordingRow(status, now: context.now, id: "toolbar")]
        if let focused = captures.first(where: { $0.id == context.focusedID }) ?? captures.first {
            content.append(band(focused, status: status, context: context))
            // The rest: the one shown large is not repeated, so the strip says which one it is.
            let rest = captures.filter { $0.id != focused.id }
            if !rest.isEmpty { content.append(strip(rest, status: status, context: context)) }
        } else {
            content += [spacer(), empty(prefix: ""), spacer()]
        }
        return ["hideHeader": true, "content": content, "glance": glance(captures, status: status, context: context)]
    }

    /// The captures, the take and History. More swaps the four tools for the rarer ones in the same row: an open lake does not
    /// grow (Playground clips it) and its bottom section is always 200 pt tall, so a second row has no good place. The swap is
    /// one patch of this row.
    static func toolbar(moreOpen: Bool) -> JSON {
        func tool(_ action: PluginAction, _ symbol: String, _ title: String) -> JSON {
            capsule(action, symbol: symbol, title: title, id: "tool-\(action.actionID)")
        }
        // Short nouns: four 26 pt capsules and the two symbols must fit the lake's width.
        let tools = moreOpen
            ? [tool(.captureText, "text.viewfinder", "Text"), tool(.scrollingCapture, "arrow.up.and.down.text.horizontal", "Scrolling"),
               tool(.recordGIF, "photo.stack", "GIF"), tool(.selfTimer, "timer", "Self-Timer")]
            : [tool(.captureArea, "viewfinder", "Area"), tool(.captureWindow, "macwindow", "Window"),
               tool(.captureFullscreen, "display", "Fullscreen"), tool(.recordScreen, "record.circle", "Record")]
        return ["type": "hstack", "id": "toolbar", "spacing": Metrics.row, "children": tools + [
            ["type": "spacer"],
            button(.toggleMore, symbol: moreOpen ? "ellipsis.circle.fill" : "ellipsis.circle", title: moreOpen ? "Main Tools" : "More Tools",
                   tint: moreOpen ? "white" : "gray", shape: "plain", size: Metrics.toolbarSymbol, id: "tool-more"),
            button(.openHistory, symbol: "clock.arrow.circlepath", title: "Open History", tint: "gray", shape: "plain",
                   size: Metrics.toolbarSymbol, id: "tool-open-history"),
        ]]
    }

    /// The take, from its countdown to its file: what it is, its time, and Pause/Resume and Stop (Cancel during the countdown).
    static func recordingRow(_ status: ShotboltStatus, now: Date, id: String) -> JSON {
        guard let recording = status.recording else { return toolbar(moreOpen: false) }
        let gif = recording.kind == .gif
        var children: [JSON]
        switch recording.state {
        case .starting:
            let timer = countdown(recording, now: now, id: "\(id)-time")
            children = [takeMark(recording, size: Metrics.takeMark, id: "\(id)-mark"),
                        text(timer == nil ? (gif ? "GIF starts" : "Recording starts") : "Recording in", weight: "semibold", id: "\(id)-label")]
            if let timer { children.append(timer) }
            children += [["type": "spacer"],
                         capsule(.stopRecording, symbol: "xmark", title: "Cancel", id: "\(id)-cancel")]
        case .recording, .paused:
            let paused = recording.state == .paused
            children = [takeMark(recording, size: Metrics.takeMark, id: "\(id)-mark"),
                        text(paused ? "Paused" : gif ? "Recording GIF" : "Recording", weight: "semibold", id: "\(id)-label"),
                        recordingTimer(status, now: now, id: "\(id)-time"),
                        ["type": "spacer"],
                        paused ? capsule(.pauseRecording, symbol: "play.fill", title: "Resume", tint: "white", id: "\(id)-pause")
                               : capsule(.pauseRecording, symbol: "pause.fill", title: "Pause", tint: "white", id: "\(id)-pause"),
                        capsule(.stopRecording, symbol: "stop.fill", title: "Stop", tint: "red", role: "destructive", id: "\(id)-stop")]
        case .saving, .converting, .other:
            children = [takeMark(recording, size: Metrics.takeMark, id: "\(id)-mark"),
                        text(recording.state == .converting ? "Making GIF" : "Saving video", weight: "semibold", id: "\(id)-label"),
                        ["type": "spacer"]]
            // No capsule here: the padding keeps the row as tall as one, so the capture under it does not move up.
            let inset = (Metrics.capsule - Metrics.takeMark) / 2
            return ["type": "hstack", "id": id, "spacing": Metrics.take, "padding": ["top": inset, "bottom": inset], "children": children]
        }
        return ["type": "hstack", "id": id, "spacing": Metrics.take, "children": children]
    }

    /// DynaGlance's narrow side: the mark, the time and symbol-only Pause/Resume and Stop.
    static func glanceTake(_ status: ShotboltStatus, now: Date) -> JSON {
        guard let recording = status.recording else { return spacer() }
        var children: [JSON] = [takeMark(recording, size: Metrics.glanceMark, id: "glance-take-mark")]
        switch recording.state {
        case .starting:
            if let timer = countdown(recording, now: now, id: "glance-take-time") { children.append(timer) }
            children += [spacer(), button(.stopRecording, symbol: "xmark", title: "Cancel", tint: "gray", shape: "plain",
                                          size: Metrics.glanceSymbol, id: "glance-take-stop")]
        case .recording, .paused:
            let paused = recording.state == .paused
            children += [recordingTimer(status, now: now, id: "glance-take-time"), spacer(),
                         button(.pauseRecording, symbol: paused ? "play.fill" : "pause.fill", title: paused ? "Resume" : "Pause",
                                tint: "white", shape: "plain", size: Metrics.glanceSymbol, id: "glance-take-pause"),
                         button(.stopRecording, symbol: "stop.fill", title: "Stop", tint: "red", shape: "plain", size: Metrics.glanceSymbol,
                                role: "destructive", id: "glance-take-stop")]
        case .saving, .converting, .other:
            children += [text(recording.state == .converting ? "Making GIF" : "Saving video", style: "compact", id: "glance-take-label"), spacer()]
        }
        return ["type": "hstack", "id": "glance-take", "spacing": Metrics.take, "children": children]
    }

    /// What a take is doing, as one mark: red while it records, DynamicLake's own paused and in-progress marks otherwise.
    static func takeMark(_ recording: ShotboltStatus.Recording, size: Double?, id: String?) -> JSON {
        var mark: JSON
        switch recording.state {
        case .recording: mark = symbol("record.circle.fill", tint: "red")
        case .paused: mark = ["type": "status", "status": "paused", "tint": "gray"]
        case .starting: mark = symbol("record.circle", tint: "red")
        case .saving, .converting, .other: mark = ["type": "status", "status": "inProgress", "tint": "gray"]
        }
        if let size {
            if mark["type"] as? String == "status" {
                // A status fills its frame; the record glyph sits inside its own. Same frame, same visual size.
                let inner = max(12, size - 8)
                mark["size"] = inner
                mark["padding"] = (size - inner) / 2
            } else {
                mark["size"] = size
            }
        }
        if let id { mark["id"] = id }
        return mark
    }

    /// The capture's right-click menu, in History's order. Pro-only items show only with Pro: the notch never sells.
    static func contextMenu(_ capture: ShotboltStatus.Capture, pro: Bool) -> [JSON] {
        func item(_ title: String, _ symbol: String, _ action: PluginAction) -> JSON {
            ["title": title, "systemImage": symbol, "actionID": action.actionID]
        }
        let id = capture.id
        let open = openAction(capture)
        var menu = [item(open.title, open.symbol, .open(id)), item("Copy", "doc.on.doc", .copy(id))]
        if capture.kind == .screenshot || capture.kind == .other {
            menu.append(item("Copy Text", "text.viewfinder", .copyText(id)))
            if pro { menu.append(item("AI-safe Copy", "eye.slash", .aiCopy(id))) }
            menu.append(item("Pin to Screen", "pin", .pin(id)))
        }
        menu.append(capture.kept ? item("Stop Keeping", "star.slash", .keep(id, false)) : item("Keep", "star", .keep(id, true)))
        menu.append(item("Reveal in Finder", "folder", .reveal(id)))
        return menu
    }

    static func copyCapsule(_ capture: ShotboltStatus.Capture, copied: Bool) -> JSON {
        // The same title either way, so the buttons beside it do not move: the check says it.
        capsule(.copy(capture.id), symbol: copied ? "checkmark" : "doc.on.doc", title: "Copy", tint: copied ? "green" : "blue", id: "band-copy")
    }

    /// The capture shown large: its picture (click to open it), title, details and the actions it is most used for.
    static func band(_ capture: ShotboltStatus.Capture, status: ShotboltStatus, context: LakeContext) -> JSON {
        let id = capture.id
        let open = openAction(capture)
        var picture = thumbnail(capture, assetID: context.assetID(capture), size: Metrics.band, radius: Metrics.bandRadius,
                                blank: context.blank, id: "band-image")
        if context.imageActions, picture["type"] as? String == "image" {
            picture["actionID"] = PluginAction.open(id).actionID
            picture["title"] = open.title
        }
        var titleRow: [JSON] = [text(title(of: capture), weight: "semibold", id: "band-title")]
        if capture.kept { titleRow.append(symbol("star.fill", tint: "yellow", size: 12, id: "band-star")) }
        var actions = [copyCapsule(capture, copied: context.copiedID == id)]
        switch capture.kind {
        case .screenshot, .other:
            actions.append(capsule(.open(id), symbol: open.symbol, title: open.title, id: "band-open"))
            actions.append(capsule(.copyText(id), symbol: "text.viewfinder", title: "Copy Text", id: "band-third"))
        case .video, .gif:
            actions.append(capsule(.open(id), symbol: open.symbol, title: open.title, id: "band-open"))
            actions.append(capsule(.reveal(id), symbol: "folder", title: "Reveal", id: "band-third"))
        }
        var band: JSON = [
            "type": "hstack", "id": "band", "spacing": Metrics.bandGap, "padding": ["top": Metrics.section],
            "contextMenu": contextMenu(capture, pro: status.pro), "children": [
                picture,
                ["type": "vstack", "id": "band-text", "spacing": Metrics.textGap, "children": [
                    ["type": "hstack", "id": "band-title-row", "spacing": Metrics.titleGap, "children": titleRow],
                    text(subtitle(of: capture, now: context.now), style: "compact", tint: "gray", weight: "regular", id: "band-subtitle"),
                    ["type": "hstack", "id": "band-actions", "spacing": Metrics.row, "padding": ["top": 2], "children": actions],
                ]],
                ["type": "spacer"],
            ],
        ]
        if context.canDrag(capture) { band["drag"] = ["filePath": capture.file] }
        return band
    }

    /// The other captures as small pictures, newest first: click one to show it large, right-click it, or drag it out.
    static func strip(_ captures: [ShotboltStatus.Capture], status: ShotboltStatus, context: LakeContext) -> JSON {
        let tiles = captures.map { capture -> JSON in
            var tile = thumbnail(capture, assetID: context.assetID(capture), size: Metrics.tile, radius: Metrics.tileRadius,
                                 blank: context.blank, id: "tile-\(capture.id.uuidString)")
            if context.imageActions, tile["type"] as? String == "image" {
                tile["actionID"] = PluginAction.focus(capture.id).actionID
                tile["title"] = tooltip(of: capture)
            }
            tile["contextMenu"] = contextMenu(capture, pro: status.pro)
            if context.canDrag(capture) { tile["drag"] = ["filePath": capture.file] }
            return tile
        }
        return ["type": "scroll", "id": "strip", "axis": "horizontal", "spacing": Metrics.strip, "children": tiles]
    }

    /// DynaGlance's narrow right side: the take while one runs, then the newest few with Copy. 5 components a row.
    static func glance(_ captures: [ShotboltStatus.Capture], status: ShotboltStatus, context: LakeContext) -> JSON {
        var content: [JSON] = []
        if status.recording != nil { content.append(glanceTake(status, now: context.now)) }
        guard !captures.isEmpty else { return ["hideHeader": true, "content": content + [spacer(), empty(prefix: "glance-"), spacer()]] }
        let rows = captures.prefix(maxGlanceRows).map { capture -> JSON in
            let key = capture.id.uuidString
            let copied = context.copiedID == capture.id
            var row: JSON = ["type": "hstack", "id": "glance-row-\(key)", "spacing": Metrics.take, "contextMenu": contextMenu(capture, pro: status.pro), "children": [
                thumbnail(capture, assetID: context.assetID(capture), size: Metrics.glanceThumb, radius: Metrics.glanceRadius,
                          blank: context.blank, id: "glance-thumb-\(key)"),
                text(title(of: capture), style: "compact", id: "glance-title-\(key)"),
                ["type": "spacer"],
                button(.copy(capture.id), symbol: copied ? "checkmark" : "doc.on.doc", title: copied ? "Copied" : "Copy",
                       tint: copied ? "green" : "gray", shape: "plain", size: Metrics.glanceSymbol, id: "glance-copy-\(key)"),
            ]]
            if context.canDrag(capture) { row["drag"] = ["filePath": capture.file] }
            return row
        }
        content.append(["type": "scroll", "id": "glance-captures", "spacing": Metrics.row, "softFade": "both", "children": rows])
        return ["hideHeader": true, "content": content]
    }

    static func spacer() -> JSON { ["type": "spacer"] }

    static func empty(prefix: String) -> JSON {
        ["type": "hstack", "id": "\(prefix)empty", "children": [
            ["type": "spacer"],
            ["type": "vstack", "id": "\(prefix)empty-text", "alignment": "center", "spacing": Metrics.textGap, "children": [
                symbol("camera.viewfinder", tint: "gray", size: 28, id: "\(prefix)empty-symbol"),
                text("No captures yet", weight: "semibold", id: "\(prefix)empty-title"),
                text("Screenshots and recordings show up here", style: "compact", tint: "gray", weight: "regular", id: "\(prefix)empty-detail"),
            ]],
            ["type": "spacer"],
        ]]
    }

    /// A line of why there is nothing to show, and the one thing that fixes it.
    public struct Message: Equatable {
        public var title: String
        public var detail: String
        public var action: PluginAction?
        public var actionTitle: String?
    }

    public static func message(for state: ShotboltState) -> Message {
        switch state {
        case .notInstalled:
            Message(title: "Shotbolt isn't installed", detail: "Screenshots and screen recordings for your Mac", action: .getShotbolt,
                    actionTitle: "Get Shotbolt")
        case .notRunning:
            Message(title: "Shotbolt isn't running", detail: "Open it to see your captures here", action: .launchShotbolt,
                    actionTitle: "Open Shotbolt")
        case .needsUpdate:
            Message(title: "Update Shotbolt", detail: "This plugin needs a newer Shotbolt", action: .getShotbolt,
                    actionTitle: "Get Update")
        case .pluginOutdated:
            Message(title: "Update this plugin", detail: "Shotbolt is newer than this plugin", action: nil, actionTitle: nil)
        case .disabled:
            Message(title: "Other apps can't control Shotbolt", detail: "Turn this on in Shotbolt Settings, under Advanced",
                    action: .openSettings, actionTitle: "Open Settings")
        case .ready:
            Message(title: "No captures yet", detail: "", action: nil, actionTitle: nil)
        }
    }

    static func notice(_ message: Message, prefix: String) -> [JSON] {
        var column: [JSON] = [
            ["type": "image", "source": "appIcon", "size": 36, "id": "\(prefix)notice-icon", "padding": ["bottom": 4]],
            text(message.title, weight: "semibold", id: "\(prefix)notice-title"),
            text(message.detail, style: "compact", tint: "gray", weight: "regular", id: "\(prefix)notice-detail"),
        ]
        if let action = message.action, let title = message.actionTitle {
            var cta = button(action, symbol: "arrow.up.forward", title: title, tint: "blue", shape: "roundedRect", size: Metrics.capsule,
                             id: "\(prefix)notice-action")
            cta["padding"] = ["top": 6]
            column.append(cta)
        }
        return [["type": "hstack", "id": "\(prefix)notice", "children": [
            ["type": "spacer"],
            ["type": "vstack", "id": "\(prefix)notice-text", "alignment": "center", "spacing": Metrics.noticeGap, "children": column],
            ["type": "spacer"],
        ]]]
    }

    /// Without `lakeLayout`: one header row, the newest capture and Copy.
    static func basicLake(_ state: ShotboltState, context: LakeContext) -> JSON {
        guard let status = state.status, let newest = status.captures.first(where: { $0.kind != .other }) else {
            let message = message(for: state)
            return ["leftSlot": ["type": "image", "source": "appIcon"], "title": text(message.title),
                    "subtitle": text(message.detail.isEmpty ? "Shotbolt" : message.detail)]
        }
        return ["leftSlot": ["type": "image", "source": "appIcon"],
                "title": text(title(of: newest)), "subtitle": text(subtitle(of: newest, now: context.now)),
                "rightSlot": button(.copy(newest.id), symbol: "doc.on.doc", title: "Copy", tint: "blue", id: "basic-copy")]
    }
}
