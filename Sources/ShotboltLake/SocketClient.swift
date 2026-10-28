import Darwin
import Foundation
import ShotboltLakeCore

/// The connection to DynamicLake: a Unix domain socket (`DYNAMICLAKE_JSON_SOCKET`) carrying length-prefixed JSON frames.
/// Nothing ever blocks: reads take what arrived, and writes the socket cannot take yet wait in a queue that a write source
/// empties. DynamicLake takes its time with a burst (a dozen thumbnails, then the lake) and may be answering at the same time;
/// blocking on a full socket would stop us reading those answers and could stall both sides. DynamicLake does not restart a
/// plugin that quits, so only a closed connection or a queue that stopped moving ends it.
final class SocketClient {
    enum Failure: Error, CustomStringConvertible {
        case socket(String)
        var description: String { if case .socket(let message) = self { return message }; return "" }
    }

    private let path: String
    private let maxFrameSize: Int
    private var fd: Int32 = -1
    private var buffer = Data()
    private var outgoing = Data()
    private var writer: DispatchSourceWrite?
    /// What a queued write that fails later (the connection broke meanwhile) reports to.
    var onWriteFailure: (Error) -> Void = { _ in }
    /// Far more than a lake and its 16 thumbnails: past it, DynamicLake stopped reading.
    static let maxQueued = 8 * 1024 * 1024
    /// For a read source that wakes the plugin when DynamicLake sends something.
    var fileDescriptor: Int32 { fd }

    init(path: String, maxFrameSize: Int) {
        self.path = path
        self.maxFrameSize = maxFrameSize
    }

    deinit { if fd >= 0 { close(fd) } }

    func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.socket("socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw Failure.socket("connect: \(String(cString: strerror(errno)))") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    func send(_ payload: JSON) throws {
        let frame = try Frames.encode(payload, maxSize: maxFrameSize)
        guard outgoing.count + frame.count <= Self.maxQueued else { throw Failure.socket("DynamicLake stopped reading") }
        outgoing.append(frame)
        try flush()
    }

    /// Writes what the socket takes now; the rest waits for the write source.
    private func flush() throws {
        while !outgoing.isEmpty {
            let n = outgoing.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { outgoing.removeFirst(n); continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw Failure.socket("send: \(String(cString: strerror(errno)))")
        }
        if outgoing.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                do { try self.flush() } catch { self.onWriteFailure(error) }
            }
            source.activate()
            writer = source
        }
    }

    /// Every whole message that arrived; nil once the connection is over: closed by DynamicLake, failed, or out of step.
    func receive() -> [JSON]? {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break } // nothing more for now
            return nil // ECONNRESET and the like: a read source would fire for it forever
        }
        return try? Frames.decode(&buffer, maxSize: maxFrameSize)
    }
}
