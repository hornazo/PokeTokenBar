import Foundation

/// The trainer page's local API, minus the sockets: parsing, the guards and response framing. Pure, so
/// every guard is tested without a listener (`LocalTrainerServer` only moves bytes).
///
/// Guards, in order:
/// 1. `Host` must name this port on loopback, so a page on a rebinding domain can't reach us by name.
/// 2. A browser's `Origin` must be one the user allowed in the app; others get 403 and no CORS headers,
///    so their scripts can't read anything, and the app asks the user once.
/// 3. Read-only: GET, plus OPTIONS for preflights.
enum LocalHTTP {
    static let maxRequestSize = 8 * 1024

    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        /// Lowercased names.
        let headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum ParseResult: Equatable, Sendable {
        case incomplete
        case request(Request)
        case invalid(Response)
    }

    struct Response: Equatable, Sendable {
        let status: Int
        var headers: [(String, String)]
        let body: Data

        static func == (a: Response, b: Response) -> Bool {
            a.status == b.status && a.body == b.body && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
        }

        func header(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }

        func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(LocalHTTP.reason(status))\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        static func json(_ status: Int, _ body: Data) -> Response {
            Response(status: status, headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")],
                     body: body)
        }

        static func error(_ status: Int, _ code: String, _ message: String) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: ["error": code, "message": message], options: [.sortedKeys])) ?? Data()
            return json(status, body)
        }
    }

    enum Endpoint: String, CaseIterable, Sendable {
        case trainer = "/v1/trainer"
        case battle = "/v1/battle"
        case boards = "/v1/boards"
        case history = "/v1/history"
        case trainers = "/v1/trainers"
    }

    /// What to do with a request.
    enum Decision: Equatable, Sendable {
        case respond(Response)
        /// Serve this endpoint's current JSON, with these extra (CORS) headers.
        case serve(Endpoint, headers: [String: String])
        /// Open a Server-Sent Events stream.
        case stream(headers: [String: String])
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxRequestSize ? .invalid(.error(431, "request_too_large", "headers too large")) : .incomplete
        }
        guard end.lowerBound <= maxRequestSize, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .invalid(.error(431, "request_too_large", "headers too large"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .invalid(.error(400, "bad_request", "malformed request line"))
        }
        let target = parts[1]
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .invalid(.error(400, "bad_request", "malformed header"))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated Host or Origin is ambiguous; refuse it rather than guess which one a proxy saw.
            if headers[name] != nil, name == "host" || name == "origin" {
                return .invalid(.error(400, "bad_request", "duplicate \(name) header"))
            }
            headers[name] = value
        }
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        return .request(Request(method: String(parts[0]), path: path, headers: headers))
    }

    // MARK: Routing

    /// `onUnpairedOrigin` fires for a browser origin the user hasn't allowed yet, so the app can ask.
    static func route(_ request: Request, port: Int, pairedOrigins: Set<String>,
                      onUnpairedOrigin: (String) -> Void = { _ in }) -> Decision {
        guard let host = request.header("host"), host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .respond(.error(421, "misdirected_request", "this API only answers on 127.0.0.1:\(port)"))
        }
        var cors: [String: String] = [:]
        if let origin = request.header("origin") {
            guard isPairable(origin) else {
                return .respond(.error(403, "origin_not_allowed", "pages without a web origin can't read this API"))
            }
            guard pairedOrigins.contains(origin) else {
                onUnpairedOrigin(origin)
                return .respond(.error(403, "origin_not_paired", "approve this page in the PokeTokenBar prompt on your Mac"))
            }
            cors = ["Access-Control-Allow-Origin": origin, "Vary": "Origin"]
        }
        switch request.method {
        case "OPTIONS":
            var headers = cors
            headers["Access-Control-Allow-Methods"] = "GET"
            headers["Access-Control-Max-Age"] = "600"
            if let requested = request.header("access-control-request-headers") {
                headers["Access-Control-Allow-Headers"] = requested
            }
            // Chromium asks before a public page may reach a local address.
            if request.header("access-control-request-private-network") == "true" {
                headers["Access-Control-Allow-Private-Network"] = "true"
            }
            return .respond(Response(status: 204, headers: headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, body: Data()))
        case "GET":
            if request.path == "/v1/events" { return .stream(headers: cors) }
            if let endpoint = Endpoint(rawValue: request.path) { return .serve(endpoint, headers: cors) }
            return .respond(withHeaders(.error(404, "not_found", "no such endpoint"), cors))
        default:
            return .respond(withHeaders(.error(405, "method_not_allowed", "this API is read-only"), cors))
        }
    }

    /// `http(s)://host[:port]` only: `null` (files, sandboxed frames) and anything odd can't be paired.
    static func isPairable(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme, scheme == "https" || scheme == "http",
              url.host?.isEmpty == false, url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        return origin.count <= 200
    }

    static func withHeaders(_ response: Response, _ extra: [String: String]) -> Response {
        var response = response
        response.headers += extra.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return response
    }

    // MARK: Server-Sent Events

    static func streamHead(_ extra: [String: String]) -> Data {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n"
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    /// One event. JSON from `JSONEncoder` has no raw newlines, but split anyway so a stray one can't end
    /// the event early.
    static func event(_ name: String, _ data: Data) -> Data {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return Data(("event: \(name)\n" + lines.map { "data: \($0)\n" }.joined() + "\n").utf8)
    }

    static let heartbeat = Data(": ping\n\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 421: return "Misdirected Request"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }
}
