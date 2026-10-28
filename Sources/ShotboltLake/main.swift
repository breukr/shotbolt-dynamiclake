import AppKit
import notify
import ShotboltLakeCore

// shotbolt-lake: Shotbolt in DynamicLake. DynamicLake starts it with the socket and settings in the environment.
//
//   shotbolt-lake                 run as DynamicLake's plugin
//   shotbolt-lake --check         print what the plugin sees of Shotbolt
//   shotbolt-lake --demo-json     debug builds: print sample commands, one per line, to check against DynamicLake's validator

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let target = ShotboltTarget.installed()

/// `~/Library/Logs/Shotbolt/DynamicLake.log`, started over when it passes 256 KB.
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Shotbolt/DynamicLake.log")
func log(_ message: String) {
    let line = "\(Date().formatted(Date.ISO8601FormatStyle())) \(message)\n"
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let size = ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    if size > 256 * 1024 { try? FileManager.default.removeItem(at: logURL) }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

func printJSON(_ object: JSON) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
}

let link = MacLink(target: target, log: log)

#if DEBUG
if arguments.contains("--demo-json") {
    for command in DemoPayloads.all(now: Date()) { printJSON(command) }
    exit(0)
}
#endif

if arguments.contains("--check") {
    print("Shotbolt: \(target.bundleID)")
    print("feed: \(target.statusFile.path)")
    switch link.currentState(now: Date()) {
    case .notInstalled: print("state: not installed")
    case .notRunning: print("state: not running")
    case .needsUpdate: print("state: running, no feed (needs a Shotbolt with the status feed)")
    case .pluginOutdated: print("state: the feed is newer than this plugin")
    case .disabled: print("state: links and scripts are off in Shotbolt")
    case .ready(let status):
        print("state: ready, Shotbolt \(status.app.version) (\(status.app.build)), \(status.captures.count) captures")
        if let recording = status.recording { print("recording: \(recording.state.rawValue) \(recording.kind.rawValue), \(Int(recording.elapsed)) s") }
    }
    exit(0)
}

guard let socketPath = environment["DYNAMICLAKE_JSON_SOCKET"], !socketPath.isEmpty else {
    FileHandle.standardError.write(Data("shotbolt-lake: DYNAMICLAKE_JSON_SOCKET is missing; DynamicLake starts this plugin\n".utf8))
    exit(64)
}

let features = HostFeatures(environmentValue: environment["DYNAMICLAKE_PLUGIN_FEATURES"])
let client = SocketClient(path: socketPath, maxFrameSize: features.maxFrameSize)
do { try client.connect() } catch {
    log("could not connect: \(error)")
    exit(65)
}

/// Read again only when DynamicLake rewrote the file.
let settingsPath = environment["DYNAMICLAKE_PLUGIN_SETTINGS_PATH"]
var settingsCache: (modified: Date?, value: PluginSettings)?
func loadSettings() -> PluginSettings {
    guard let settingsPath else { return PluginSettings() }
    let modified = (try? FileManager.default.attributesOfItem(atPath: settingsPath))?[.modificationDate] as? Date
    if let settingsCache, settingsCache.modified == modified { return settingsCache.value }
    let value = PluginSettings(settingsFile: FileManager.default.contents(atPath: settingsPath))
    settingsCache = (modified, value)
    return value
}

let plugin = Plugin(link: link, features: features, loadSettings: loadSettings, log: log) { command in
    do {
        try client.send(command)
    } catch Frames.Failure.tooLarge(let size) {
        log("not sent, \(size) bytes is over the limit: \(command["type"] ?? "?")")
    }
}
log("started for \(target.bundleID), features: \(environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "none")")

// Event-driven: the plugin runs when something happens and at its next deadline, and otherwise sleeps.

func stop(_ error: Error) -> Never {
    log("stopping: \(error)")
    exit(65)
}

client.onWriteFailure = { stop($0) }

/// One timer for the plugin's next deadline, moved after every event.
let wakeTimer = DispatchSource.makeTimerSource(queue: .main)
/// Set below, once the settings file is watched.
var settingsWatcher: FileWatcher?
/// Shotbolt quitting or crashing, heard from the kernel. A menu bar app like Shotbolt gets no workspace launch or quit
/// notifications; its launch is announced by its feed.
var exitWatch: (pid: Int32, source: DispatchSourceProcess)?

/// Does what is due, then sleeps until the next deadline.
func pump() {
    let now = Date()
    settingsWatcher?.arm()
    do { try plugin.tick(now: now) } catch { stop(error) }
    if exitWatch?.pid != plugin.shotboltPID {
        exitWatch?.source.cancel()
        exitWatch = plugin.shotboltPID.map { pid in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler {
                plugin.markStatusChanged()
                pump()
            }
            source.activate()
            return (pid, source)
        }
    }
    let delay = max(0, plugin.nextWake(now: now).timeIntervalSince(Date()))
    // Copy feedback and closing the lake want the moment; the safety poll can drift.
    wakeTimer.schedule(deadline: .now() + delay, leeway: delay > 5 ? .seconds(2) : .milliseconds(20))
}
wakeTimer.setEventHandler(handler: pump)
wakeTimer.activate()

let reader = DispatchSource.makeReadSource(fileDescriptor: client.fileDescriptor, queue: .main)
reader.setEventHandler {
    guard let messages = client.receive() else {
        log("DynamicLake closed the connection")
        exit(0)
    }
    let now = Date()
    do { for message in messages { try plugin.handle(message, now: now) } } catch { stop(error) }
    pump()
}
reader.activate()

var notifyToken: Int32 = 0
notify_register_dispatch(target.changedNotification, &notifyToken, DispatchQueue.main) { _ in
    plugin.markStatusChanged()
    pump()
}

if let settingsPath { settingsWatcher = FileWatcher(path: settingsPath, changed: pump) }

pump()
RunLoop.main.run()
