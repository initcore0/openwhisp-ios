import Foundation
import Network

/// A newline-delimited-JSON frame reader/writer over an `NWConnection`. Mirrors
/// the exact framing upstream `BridgeClient` uses on its UNIX socket: each frame
/// is a JSON object followed by a single `0x0A`, and a response is one such line.
/// This is the transport substrate the synchronous ``TCPBridgeSession`` blocks
/// on, so the upstream `BridgeSession` contract (sync `call`) is honored over an
/// async `NWConnection`.
final class NDJSONConnection {
    enum ConnError: Error, Equatable {
        case timeout
        case closed
        case failed(String)
        case frameTooLarge
    }

    /// Max accepted frame, matching `BridgeWire.maxFrameBytes` (1 MiB). Kept as a
    /// local constant so this file has no BridgeKit dependency.
    static let maxFrameBytes = 1 << 20

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.openwhisp.sync.ndjson")
    private var readBuffer = Data()
    private let stateLock = NSLock()
    private var started = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, parameters: NWParameters) {
        self.connection = NWConnection(host: host, port: port, using: parameters)
    }

    init(endpoint: NWEndpoint, parameters: NWParameters) {
        self.connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Bring the connection up (including the TLS-PSK handshake) or throw. Blocks
    /// the caller until `.ready`, `.failed`, or `timeout`.
    func start(timeout: TimeInterval) throws {
        stateLock.lock(); let already = started; started = true; stateLock.unlock()
        guard !already else { return }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, ConnError> = .failure(.timeout)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result = .success(()); sem.signal()
            case .failed(let err):
                result = .failure(.failed("\(err)")); sem.signal()
            case .waiting(let err):
                // A TLS-PSK handshake failure (e.g. a wrong key) surfaces as
                // `.waiting`, after which NWConnection would retry until our
                // deadline. For a paired LAN sync there's nothing to wait for —
                // the key is either right or wrong — so treat `.waiting` as a hard
                // failure and fail fast rather than hang to the timeout.
                result = .failure(.failed("\(err)")); sem.signal()
            case .cancelled:
                result = .failure(.closed); sem.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw ConnError.timeout
        }
        try result.get()
    }

    /// Write one JSON object as a `\n`-terminated frame. Blocks until sent.
    func writeFrame(_ json: Data) throws {
        var frame = json
        frame.append(0x0A)
        let sem = DispatchSemaphore(value: 0)
        var sendError: ConnError?
        connection.send(content: frame, completion: .contentProcessed { err in
            if let err { sendError = .failed("\(err)") }
            sem.signal()
        })
        sem.wait()
        if let sendError { throw sendError }
    }

    /// Read one `\n`-terminated frame (buffering any surplus), or throw on
    /// timeout/close. Empty lines are skipped, matching `BridgeClient`.
    func readFrame(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ConnError.timeout }
            let chunk = try receiveChunk(timeout: remaining)
            readBuffer.append(chunk)
            if readBuffer.count > Self.maxFrameBytes { throw ConnError.frameTooLarge }
        }
    }

    private func receiveChunk(timeout: TimeInterval) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, ConnError> = .failure(.timeout)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
            if let err {
                out = .failure(.failed("\(err)"))
            } else if let data, !data.isEmpty {
                out = .success(data)
            } else if isComplete {
                out = .failure(.closed)
            } else {
                out = .success(Data())
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw ConnError.timeout }
        return try out.get()
    }

    func cancel() {
        connection.cancel()
    }
}
