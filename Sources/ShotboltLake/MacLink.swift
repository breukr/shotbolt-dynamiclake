import AppKit
import notify
import ShotboltLakeCore

/// Which Shotbolt the plugin works with: its feed file, the notifications it posts and listens for, and its bundle id.
struct ShotboltTarget {
    var bundleID: String
    var statusFile: URL
    var changedNotification: String
    /// Posted to ask Shotbolt for its feed: it writes the file only while a companion asked in the last few minutes.
    var subscribeNotification: String

    static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ShotboltTarget {
        ShotboltTarget(bundleID: "nl.breukr.shotbolt",
                       statusFile: home.appendingPathComponent("Library/Application Support/Shotbolt/Integrations/status.json"),
                       changedNotification: "nl.breukr.shotbolt.status-changed",
                       subscribeNotification: "nl.breukr.shotbolt.status-subscribe")
    }
}

/// The real Mac: Shotbolt's feed file, its running processes, and `shotbolt://` links opened without bringing anything forward.
final class MacLink: ShotboltLink {
    let target: ShotboltTarget
    private let log: (String) -> Void
    private var cachedStatus: (modified: Date, status: ShotboltStatus?)?

    init(target: ShotboltTarget, log: @escaping (String) -> Void) {
        self.target = target
        self.log = log
    }

    /// Also checked with the kernel: Launch Services can list a process for a moment after it exited.
    private var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).filter {
            !$0.isTerminated && (kill($0.processIdentifier, 0) == 0 || errno == EPERM)
        }
    }

    func currentState(now: Date) -> ShotboltState {
        let running = running
        let installed = !running.isEmpty || installedCopy() != nil
        let launchedAt = running.compactMap(\.launchDate).min()
        return ShotboltState.resolve(installed: installed, runningPIDs: running.map(\.processIdentifier), launchedAt: launchedAt,
                                     status: readStatus(), now: now)
    }

    /// Shotbolt's feed is a few KB; a bigger file is not one it wrote and is not read at all.
    static let maxFeedSize = 1024 * 1024

    /// Read again only when the file changed, so a refused file is logged once.
    private func readStatus() -> ShotboltStatus? {
        let path = target.statusFile.path
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let cachedStatus, cachedStatus.modified == modified { return cachedStatus.status }
        var status: ShotboltStatus?
        do {
            // Never more than the cap plus one byte in memory, whatever the file's size says by the time it is read.
            let handle = try FileHandle(forReadingFrom: target.statusFile)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maxFeedSize + 1) ?? Data()
            if data.count > Self.maxFeedSize {
                log("ignored \(path): over \(Self.maxFeedSize / 1024) KB")
            } else {
                // Thumbnails only from the folder that holds the feed: `Shotbolt/Integrations/status.json` → `Shotbolt`.
                let support = target.statusFile.deletingLastPathComponent().deletingLastPathComponent()
                status = try ShotboltStatus.decode(data).keepingThumbnails(inside: support)
            }
        } catch {
            log("could not read \(path): \(error)")
        }
        cachedStatus = (modified, status)
        return status
    }

    func send(_ command: String) {
        guard let url = URL(string: "shotbolt://" + command) else { return log("not a command: \(command)") }
        // To the Shotbolt that runs and wrote the feed, not whichever copy Launch Services picks (an old one in Downloads or a
        // mounted disk image would not know the command).
        guard let app = running.first?.bundleURL ?? installedCopy() else { return log("no Shotbolt for shotbolt://\(command)") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false // Shotbolt brings itself forward when what it opens needs the keyboard
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [log] _, error in
            if let error { log("shotbolt://\(command): \(error.localizedDescription)") }
        }
    }

    func subscribe() { notify_post(target.subscribeNotification) }

    /// The copy to launch: in an Applications folder before anywhere else, never one in the Trash, on a mounted disk image or
    /// translocated, and the newest build among equals.
    func installedCopy() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func rank(_ url: URL) -> Int? {
            let path = url.path
            if path.hasPrefix("/Volumes/") || path.contains("/.Trash/") || path.contains("/AppTranslocation/") { return nil }
            if path.hasPrefix("/Applications/") { return 0 }
            if path.hasPrefix(home + "/Applications/") { return 1 }
            return 2
        }
        func build(_ url: URL) -> Int { Int(Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: target.bundleID)
            .compactMap { url in rank(url).map { (url, $0, build(url)) } }
            .min { ($0.1, -$0.2) < ($1.1, -$1.2) }?.0
    }

    func launchShotbolt() {
        guard let app = installedCopy() else { return openWebsite() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [log] _, error in
            if let error { log("could not open Shotbolt: \(error.localizedDescription)") }
        }
    }

    func openWebsite() { NSWorkspace.shared.open(shotboltWebsite) }

    func fileReady(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0 > 0
    }
}
