import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit

/// A minimal in-process NDJSON JSON-RPC server on 127.0.0.1, used to round-trip
/// the ``TCPBridgeSession`` framing/handshake/call against a REAL `NWConnection`
/// without TLS or a Mac. It answers `bridge.hello` (advertising the `sync`
/// capability) and delegates every other method to a supplied handler that
/// returns a raw JSON `result` object.
///
/// Optional `tlsParameters` lets the loopback integration test arm the SAME
/// TLS-PSK the phone uses, so the harness path is exercised end to end.
final class InProcessNDJSONServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.ndjson.server")
    private let handler: (String, Data) -> Data   // (method, paramsJSON) -> resultJSON
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    /// - Parameter handler: maps (method, params-json) → a JSON `result` object.
    ///   `bridge.hello` is handled internally; the handler sees the rest.
    init(parameters: NWParameters = .tcp, handler: @escaping (String, Data) -> Data) throws {
        self.handler = handler
        self.listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    }

    /// Start listening and return the bound port.
    func start() throws -> NWEndpoint.Port {
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        guard let port = listener.port else { throw NSError(domain: "ndjson", code: 1) }
        return port
    }

    func stop() {
        listener.cancel()
        lock.lock(); let conns = connections.values; connections.removeAll(); lock.unlock()
        conns.forEach { $0.cancel() }
    }

    private func accept(_ conn: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(conn)] = conn; lock.unlock()
        conn.start(queue: queue)
        receiveLoop(conn, buffer: Data())
    }

    private func receiveLoop(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty { self.respond(conn, to: line) }
            }
            if isComplete { conn.cancel() } else { self.receiveLoop(conn, buffer: buf) }
        }
    }

    private func respond(_ conn: NWConnection, to line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = obj["method"] as? String else { return }
        let id = obj["id"]
        let paramsData = (obj["params"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)

        let resultJSON: Data
        if method == BridgeWire.Method.hello.rawValue {
            let hello = BridgeWire.HelloResult(
                protocolVersion: BridgeWire.protocolVersion, appVersion: "test",
                capabilities: [BridgeWire.Capability.sync], clientId: "test-client",
                consent: .granted, consentScopes: [BridgeWire.Capability.sync: .granted])
            resultJSON = (try? JSONEncoder().encode(hello)) ?? Data("{}".utf8)
        } else {
            resultJSON = handler(method, paramsData)
        }

        var envelope: [String: Any] = ["jsonrpc": "2.0", "result": (try? JSONSerialization.jsonObject(with: resultJSON)) ?? [:]]
        if let id { envelope["id"] = id }
        guard var out = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        out.append(0x0A)
        conn.send(content: out, completion: .contentProcessed { _ in })
    }
}
