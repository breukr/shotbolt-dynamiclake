import Foundation

/// What a button, image or menu item in the notch asks for. The `actionID` is all DynamicLake sends back, so each one is a
/// short string: `capture-area`, `copy:<capture id>`.
public enum PluginAction: Equatable, Sendable {
    case captureArea, captureWindow, captureFullscreen, recordScreen, openHistory
    /// The tools under More: OCR capture, scrolling capture, a GIF take, the self-timer (Settings' delay).
    case captureText, scrollingCapture, recordGIF, selfTimer
    case pauseRecording, stopRecording
    case copy(UUID), open(UUID), pin(UUID), reveal(UUID)
    /// The capture's recognized text to the clipboard (Shotbolt reads it; it never passes through the plugin).
    case copyText(UUID)
    /// Shotbolt Pro's AI-safe Copy: the picture without personal data.
    case aiCopy(UUID)
    /// Keep (the star) on or off, said explicitly so a stale lake can never flip it the wrong way.
    case keep(UUID, Bool)
    /// The plugin's own: show this capture large in the lake.
    case focus(UUID)
    /// The plugin's own: the More tools row under the lake, open or closed.
    case toggleMore
    /// Shotbolt is installed but not running.
    case launchShotbolt
    /// Shotbolt is not installed, or too old for the feed.
    case getShotbolt
    /// "Allow shotbolt:// links and scripts" is off: Shotbolt's Settings, which open even then.
    case openSettings

    private static let simple: [String: PluginAction] = [
        "capture-area": .captureArea, "capture-window": .captureWindow, "capture-fullscreen": .captureFullscreen,
        "record-screen": .recordScreen, "open-history": .openHistory, "capture-text": .captureText,
        "scrolling-capture": .scrollingCapture, "record-gif": .recordGIF, "self-timer": .selfTimer,
        "pause-recording": .pauseRecording, "stop-recording": .stopRecording, "more-tools": .toggleMore,
        "launch-shotbolt": .launchShotbolt, "get-shotbolt": .getShotbolt, "open-settings": .openSettings,
    ]

    public init?(actionID: String) {
        let parts = actionID.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            switch parts[0] {
            case "copy": self = .copy(id)
            case "open": self = .open(id)
            case "pin": self = .pin(id)
            case "reveal": self = .reveal(id)
            case "copy-text": self = .copyText(id)
            case "ai-copy": self = .aiCopy(id)
            case "keep": self = .keep(id, true)
            case "unkeep": self = .keep(id, false)
            case "focus": self = .focus(id)
            default: return nil
            }
            return
        }
        guard let action = Self.simple[actionID] else { return nil }
        self = action
    }

    public var actionID: String {
        switch self {
        case .copy(let id): "copy:\(id.uuidString)"
        case .open(let id): "open:\(id.uuidString)"
        case .pin(let id): "pin:\(id.uuidString)"
        case .reveal(let id): "reveal:\(id.uuidString)"
        case .copyText(let id): "copy-text:\(id.uuidString)"
        case .aiCopy(let id): "ai-copy:\(id.uuidString)"
        case .keep(let id, let on): "\(on ? "keep" : "unkeep"):\(id.uuidString)"
        case .focus(let id): "focus:\(id.uuidString)"
        default: Self.simple.first { $0.value == self }!.key
        }
    }

    /// The `shotbolt://` command (without the scheme), or nil for what the plugin does itself.
    public var shotboltCommand: String? {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .recordScreen, .openHistory, .captureText, .scrollingCapture,
             .recordGIF, .pauseRecording, .stopRecording, .openSettings:
            actionID
        case .selfTimer: "capture-area-timer"
        case .copy(let id): "copy-capture?id=\(id.uuidString)"
        case .open(let id): "open-capture?id=\(id.uuidString)"
        case .pin(let id): "pin-capture?id=\(id.uuidString)"
        case .reveal(let id): "reveal-capture?id=\(id.uuidString)"
        case .copyText(let id): "copy-text-capture?id=\(id.uuidString)"
        case .aiCopy(let id): "ai-copy-capture?id=\(id.uuidString)"
        case .keep(let id, let on): "keep-capture?id=\(id.uuidString)&on=\(on ? 1 : 0)"
        case .focus, .toggleMore, .launchShotbolt, .getShotbolt: nil
        }
    }

    /// Starts something on screen (an overlay, a window, a toast under the notch): the lake closes first so it is not in the
    /// way or in the picture.
    public var closesLakeFirst: Bool {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .recordScreen, .openHistory, .captureText, .scrollingCapture,
             .recordGIF, .selfTimer, .open, .pin, .reveal, .copyText, .aiCopy, .launchShotbolt, .getShotbolt, .openSettings:
            true
        case .pauseRecording, .stopRecording, .copy, .keep, .focus, .toggleMore:
            false
        }
    }
}

/// Where Shotbolt's website sends people who do not have it yet.
public let shotboltWebsite = URL(string: "https://shotbolt.app")!
