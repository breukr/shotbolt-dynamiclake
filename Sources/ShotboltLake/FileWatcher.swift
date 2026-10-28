import Foundation

/// Calls `changed` when a file is written or replaced, without polling: a kernel event source (kqueue) on the file. DynamicLake
/// rewrites the plugin's settings file when they change, possibly by replacing it, so a replaced file is watched again.
final class FileWatcher {
    private let path: String
    private let changed: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(path: String, changed: @escaping () -> Void) {
        self.path = path
        self.changed = changed
        arm()
    }

    /// Starts watching if the file exists and is not watched yet; cheap to call again.
    func arm() {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // Replaced: this descriptor follows the old file. Watch the new one at the same path.
                source.cancel()
                self.source = nil
                self.arm()
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.activate()
        self.source = source
    }
}
