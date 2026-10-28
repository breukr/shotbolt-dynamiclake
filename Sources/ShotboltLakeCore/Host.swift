import Foundation

public typealias JSON = [String: Any]

/// DynamicLake's JSON plugin protocol version.
public let pluginSchemaVersion = 1

/// What the DynamicLake that started us supports (`DYNAMICLAKE_PLUGIN_FEATURES`). An older host rejects any message with a
/// field it does not know, so every newer field is sent only when its feature is listed.
public struct HostFeatures: Equatable, Sendable {
    public var lake: Bool
    public var lakeLayout: Bool
    public var imageAssets: Bool
    public var presentSneakPeek: Bool
    public var numericText: Bool
    /// Images with an `actionID` (and a `title` tooltip) in the lake. No host announces it, and DynamicLake Playground 1.2
    /// rejects it, so it is assumed and turned off the first time the host says it does not know the field.
    public var imageActions: Bool

    public init(lake: Bool = true, lakeLayout: Bool = true, imageAssets: Bool = true, presentSneakPeek: Bool = true,
                numericText: Bool = true, imageActions: Bool = true) {
        self.lake = lake; self.lakeLayout = lakeLayout; self.imageAssets = imageAssets
        self.presentSneakPeek = presentSneakPeek; self.numericText = numericText; self.imageActions = imageActions
    }

    public init(environmentValue: String?) {
        let features = Set((environmentValue ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        self.init(lake: features.contains("lake"), lakeLayout: features.contains("lakeLayout"),
                  imageAssets: features.contains("imageAssets"), presentSneakPeek: features.contains("presentSneakPeek"),
                  numericText: features.contains("numericText"), imageActions: features.contains("lakeLayout"))
    }

    /// The biggest message the host accepts.
    public var maxFrameSize: Int { imageAssets ? 256 * 1024 : 64 * 1024 }
}

/// The settings declared in `plugin.json`, as DynamicLake hands them over (`DYNAMICLAKE_PLUGIN_SETTINGS_PATH`).
public struct PluginSettings: Equatable, Sendable {
    /// "Show Recordings": a live activity while Shotbolt records, and a moment after it saved.
    public var showRecordings = true
    /// "Show New Screenshots": each new capture for a few seconds. Off by default: Shotbolt's Quick Access already shows it.
    public var showNewCaptures = false

    public init(showRecordings: Bool = true, showNewCaptures: Bool = false) {
        self.showRecordings = showRecordings; self.showNewCaptures = showNewCaptures
    }

    /// From the settings file (`{"values": {...}}`), else the defaults.
    public init(settingsFile: Data?) {
        self.init()
        guard let settingsFile, let object = try? JSONSerialization.jsonObject(with: settingsFile) as? JSON,
              let values = object["values"] as? JSON else { return }
        if let value = values["showRecordings"] as? Bool { showRecordings = value }
        if let value = values["showNewCaptures"] as? Bool { showNewCaptures = value }
    }
}

/// Messages on the socket: a 4-byte big-endian length, then that many bytes of UTF-8 JSON.
public enum Frames {
    public enum Failure: Error, Equatable { case tooLarge(Int) }

    public static func encode(_ payload: JSON, maxSize: Int) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard body.count <= maxSize else { throw Failure.tooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Takes every whole frame off the front of `buffer`; a partial frame stays for the next read. Throws for a frame that
    /// claims more than `maxSize`: the rest of the stream can no longer be trusted to line up, so the connection must end.
    public static func decode(_ buffer: inout Data, maxSize: Int) throws -> [JSON] {
        var messages: [JSON] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxSize else { throw Failure.tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer[start + 4..<start + 4 + length]
            buffer.removeSubrange(start..<start + 4 + length)
            if let object = try? JSONSerialization.jsonObject(with: Data(body)) as? JSON { messages.append(object) }
        }
        return messages
    }
}
