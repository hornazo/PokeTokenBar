import Foundation
import Network

/// The trainer page's local API on 127.0.0.1 only: nothing on the LAN can connect, and macOS shows no
/// firewall prompt. Moves bytes; every decision is `LocalHTTP`'s, made on the main actor.
@MainActor @Observable
final class LocalTrainerServer {
    enum State: Equatable {
        case stopped
        case running(port: Int)
        case failed(port: Int, reason: String)
    }

    static let maxStreams = 8
    nonisolated static let idleTimeout: TimeInterval = 10

    private(set) var state: State = .stopped
    /// The current JSON for an endpoint.
    var payload: (LocalHTTP.Endpoint) -> Data = { _ in Data("{}".utf8) }
    var pairedOrigins: () -> Set<String> = { [] }
    /// A browser origin the user hasn't allowed yet asked for data.
    var onUnpairedOrigin: (String) -> Void = { _ in }

    private var listener: NWListener?
    private var port = 0
    private var streams: [(id: ObjectIdentifier, connection: NWConnection)] = []
    private var heartbeat: Task<Void, Never>?
    private nonisolated let queue = DispatchQueue(label: "io.github.chattymin.poketokenbar.local-api")

    func start(port: Int) {
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            state = .failed(port: port, reason: "invalid port")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] update in
                let state: State?
                switch update {
                case .ready: state = .running(port: port)
                case .failed(let error): state = .failed(port: port, reason: "\(error)")
                default: state = nil
                }
                guard let state else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.port == port, self.listener != nil else { return }
                    self.state = state
                    if case .failed = state { self.stop(keepState: true) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    self?.sendToStreams(LocalHTTP.heartbeat)
                }
            }
        } catch {
            state = .failed(port: port, reason: "\(error)")
        }
    }

    func stop() { stop(keepState: false) }

    private func stop(keepState: Bool) {
        heartbeat?.cancel()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        for stream in streams { stream.connection.cancel() }
        streams = []
        if !keepState { state = .stopped }
    }

    /// Pushes one event to every open stream.
    func broadcast(_ name: String, _ data: Data) {
        sendToStreams(LocalHTTP.event(name, data))
    }

    var streamCount: Int { streams.count }

    private func sendToStreams(_ data: Data) {
        for stream in streams {
            stream.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                let id = stream.id
                Task { @MainActor [weak self] in self?.dropStream(id) }
            })
        }
    }

    private func dropStream(_ id: ObjectIdentifier) {
        streams.removeAll { entry in
            guard entry.id == id else { return false }
            entry.connection.cancel()
            return true
        }
    }

    // MARK: Connections (listener queue)

    private final class Pending: @unchecked Sendable {
        var handled = false
    }

    private nonisolated func accept(_ connection: NWConnection) {
        let pending = Pending()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) {
            if !pending.handled { connection.cancel() }
        }
        receive(connection, buffer: Data(), pending: pending)
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data, pending: Pending) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LocalHTTP.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalHTTP.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer, pending: pending)
            case .invalid(let response):
                pending.handled = true
                Self.send(response, on: connection)
            case .request(let request):
                pending.handled = true
                Task { @MainActor [weak self] in self?.handle(request, on: connection) }
            }
        }
    }

    private nonisolated static func send(_ response: LocalHTTP.Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Requests (main actor)

    private func handle(_ request: LocalHTTP.Request, on connection: NWConnection) {
        let decision = LocalHTTP.route(request, port: port, pairedOrigins: pairedOrigins(), onUnpairedOrigin: onUnpairedOrigin)
        switch decision {
        case .respond(let response):
            Self.send(response, on: connection)
        case .serve(let endpoint, let headers):
            Self.send(LocalHTTP.withHeaders(.json(200, payload(endpoint)), headers), on: connection)
        case .stream(let headers):
            if streams.count >= Self.maxStreams, let oldest = streams.first { dropStream(oldest.id) }
            var opening = LocalHTTP.streamHead(headers)
            for endpoint in LocalHTTP.Endpoint.allCases {
                opening += LocalHTTP.event(Self.eventName(endpoint), payload(endpoint))
            }
            let id = ObjectIdentifier(connection)
            streams.append((id, connection))
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor [weak self] in self?.dropStream(id) }
                default: break
                }
            }
            connection.send(content: opening, completion: .contentProcessed { _ in })
        }
    }

    static func eventName(_ endpoint: LocalHTTP.Endpoint) -> String {
        switch endpoint {
        case .trainer: return "trainer"
        case .battle: return "battle"
        case .boards: return "boards"
        }
    }
}
