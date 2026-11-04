import Foundation
import Network

struct ProxyCredentials: Equatable, Sendable {
    var username: String
    var password: String

    var basicToken: String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// Authenticated HTTP/HTTPS forward proxy. Everything runs on one serial queue.
final class ProxyServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    struct Stats: Equatable, Sendable {
        var activeConnections = 0
        var bytesTransferred: UInt64 = 0
    }

    struct Configuration: Sendable {
        var port: UInt16 = 8080
        var credentials: ProxyCredentials
        /// Outbound traffic must leave through Wi-Fi, never cellular.
        var requireWiFiUpstream = true
        /// Keeps other devices from using the proxy to reach this phone or the local network.
        var blockPrivateDestinations = true
    }

    private static let maxSessions = 128
    private static let idleLimit: TimeInterval = 600

    private let queue = DispatchQueue(label: "PuenteWiFi.proxy")
    private let configuration: Configuration
    private let onStateChange: @Sendable (State) -> Void
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private var reaper: DispatchSourceTimer?
    private var bytesTransferred: UInt64 = 0

    init(configuration: Configuration, onStateChange: @escaping @Sendable (State) -> Void) {
        self.configuration = configuration
        self.onStateChange = onStateChange
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
                onStateChange(.failed("Puerto no válido."))
                return
            }
            let parameters = NWParameters.tcp
            parameters.prohibitedInterfaceTypes = [.cellular]
            do {
                let listener = try NWListener(using: parameters, on: port)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
                startReaper()
            } catch {
                onStateChange(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            shutDown()
            onStateChange(.stopped)
        }
    }

    func readStats(_ completion: @escaping @Sendable (Stats) -> Void) {
        queue.async { [self] in
            completion(Stats(activeConnections: sessions.count, bytesTransferred: bytesTransferred))
        }
    }

    private func shutDown() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        reaper?.cancel()
        reaper = nil
        let active = Array(sessions.values)
        sessions.removeAll()
        active.forEach { $0.finish() }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            onStateChange(.running(port: listener?.port?.rawValue ?? configuration.port))
        case .failed(let error):
            shutDown()
            onStateChange(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < Self.maxSessions else {
            connection.cancel()
            return
        }
        let session = ProxySession(client: connection, configuration: configuration, queue: queue) { [weak self] session in
            self?.sessions[ObjectIdentifier(session)] = nil
        } onBytes: { [weak self] count in
            self?.bytesTransferred += UInt64(count)
        }
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-Self.idleLimit)
            self.sessions.values.filter { $0.lastActivity < cutoff }.forEach { $0.finish() }
        }
        timer.resume()
        reaper = timer
    }
}

private final class ProxySession {
    private static let maxHeadSize = 64 * 1024
    private static let setupTimeout: TimeInterval = 20

    private let client: NWConnection
    private let configuration: ProxyServer.Configuration
    private let queue: DispatchQueue
    private let onFinish: (ProxySession) -> Void
    private let onBytes: (Int) -> Void
    private var upstream: NWConnection?
    private var buffer = Data()
    private var setupTimer: DispatchWorkItem?
    private var finishedStreams = 0
    private var finished = false
    private(set) var lastActivity = Date()

    init(
        client: NWConnection,
        configuration: ProxyServer.Configuration,
        queue: DispatchQueue,
        onFinish: @escaping (ProxySession) -> Void,
        onBytes: @escaping (Int) -> Void
    ) {
        self.client = client
        self.configuration = configuration
        self.queue = queue
        self.onFinish = onFinish
        self.onBytes = onBytes
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        client.start(queue: queue)
        armSetupTimer { [weak self] in self?.finish() }
        readHead()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        setupTimer?.cancel()
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        onFinish(self)
    }

    private func armSetupTimer(_ action: @escaping () -> Void) {
        setupTimer?.cancel()
        let timer = DispatchWorkItem(block: action)
        setupTimer = timer
        queue.asyncAfter(deadline: .now() + Self.setupTimeout, execute: timer)
    }

    // MARK: Request head

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                let remainder = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                self.handle(head: head, remainder: remainder)
            } else if isComplete || error != nil {
                self.finish()
            } else if self.buffer.count > Self.maxHeadSize {
                self.respond(status: "431 Request Header Fields Too Large", body: "Cabeceras demasiado grandes.\n")
            } else {
                self.readHead()
            }
        }
    }

    private func handle(head: String, remainder: Data) {
        guard let request = ProxyRequest(head: head) else {
            respond(status: "400 Bad Request", body: "Solicitud no válida.\n")
            return
        }
        if request.target.hasPrefix("/") {
            serveLocalPage(request)
            return
        }
        guard request.hasCredentials(configuration.credentials) else {
            respond(
                status: "407 Proxy Authentication Required",
                extraHeaders: ["Proxy-Authenticate: Basic realm=\"PuenteWiFi\""],
                body: "Falta el usuario o la contraseña del proxy.\n"
            )
            return
        }
        if request.method == "CONNECT" {
            guard let target = HostPort(authority: request.target, defaultPort: nil) else {
                respond(status: "400 Bad Request", body: "Destino no válido.\n")
                return
            }
            openUpstream(to: target) { [weak self] upstream in
                guard let self else { return }
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                self.client.send(content: established, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished else { return }
                    if error != nil {
                        self.finish()
                        return
                    }
                    self.startRelay(upstream: upstream, initialUpstreamData: remainder)
                })
            }
        } else {
            guard let forwarded = request.forwardedHTTPRequest() else {
                respond(status: "400 Bad Request", body: "Solo se admiten direcciones http:// o CONNECT.\n")
                return
            }
            openUpstream(to: forwarded.target) { [weak self] upstream in
                self?.startRelay(upstream: upstream, initialUpstreamData: forwarded.head + remainder)
            }
        }
    }

    // MARK: Upstream

    private func openUpstream(to target: HostPort, onReady: @escaping (NWConnection) -> Void) {
        if configuration.blockPrivateDestinations && DestinationPolicy.isBlocked(host: target.host) {
            respond(status: "403 Forbidden", body: "Destino local bloqueado.\n")
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if configuration.requireWiFiUpstream {
            parameters.requiredInterfaceType = .wifi
        }
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            respond(status: "400 Bad Request", body: "Puerto no válido.\n")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: parameters)
        upstream = connection
        armSetupTimer { [weak self] in self?.failUpstream() }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                if self.configuration.blockPrivateDestinations,
                   case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint,
                   DestinationPolicy.isBlocked(endpointHost: host) {
                    self.setupTimer?.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    self.upstream = nil
                    self.respond(status: "403 Forbidden", body: "Destino local bloqueado.\n")
                    return
                }
                self.setupTimer?.cancel()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.finish()
                    default: break
                    }
                }
                onReady(connection)
            // .waiting covers refused connections and no Wi-Fi route; retrying would just hang the client.
            case .failed, .waiting:
                self.failUpstream()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func failUpstream() {
        upstream?.stateUpdateHandler = nil
        upstream?.cancel()
        upstream = nil
        respond(status: "502 Bad Gateway", body: "No se pudo conectar por Wi-Fi con el destino.\n")
    }

    // MARK: Relay

    private func startRelay(upstream: NWConnection, initialUpstreamData: Data) {
        guard !finished else { return }
        if initialUpstreamData.isEmpty {
            pump(from: client, to: upstream)
        } else {
            onBytes(initialUpstreamData.count)
            upstream.send(content: initialUpstreamData, completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                if error != nil {
                    self.finish()
                    return
                }
                self.pump(from: self.client, to: upstream)
            })
        }
        pump(from: upstream, to: client)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            let continueAfterSend = {
                if isComplete {
                    self.streamEnded(sendingFinTo: destination)
                } else if error != nil {
                    self.finish()
                } else {
                    self.pump(from: source, to: destination)
                }
            }
            guard let data, !data.isEmpty else {
                continueAfterSend()
                return
            }
            self.lastActivity = Date()
            self.onBytes(data.count)
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.finished else { return }
                if sendError != nil {
                    self.finish()
                } else {
                    continueAfterSend()
                }
            })
        }
    }

    private func streamEnded(sendingFinTo destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        finishedStreams += 1
        if finishedStreams == 2 { finish() }
    }

    // MARK: Local responses

    private func serveLocalPage(_ request: ProxyRequest) {
        guard request.method == "GET" || request.method == "HEAD" else {
            respond(status: "405 Method Not Allowed", body: "Método no permitido.\n")
            return
        }
        let address = request.safeHostHeader ?? "IP-DEL-IPHONE:\(configuration.port)"
        let path = request.target.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init)
        switch path {
        case "/":
            respond(status: "200 OK", contentType: "text/html; charset=utf-8", body: LocalPages.landing(address: address), omitBody: request.method == "HEAD")
        case "/proxy.pac":
            respond(status: "200 OK", contentType: "application/x-ns-proxy-autoconfig", body: LocalPages.pac(address: address), omitBody: request.method == "HEAD")
        default:
            respond(status: "404 Not Found", body: "No encontrado.\n")
        }
    }

    private func respond(
        status: String,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String] = [],
        body: String,
        omitBody: Bool = false
    ) {
        setupTimer?.cancel()
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n"
        extraHeaders.forEach { head += "\($0)\r\n" }
        head += "\r\n"
        let payload = omitBody ? Data(head.utf8) : Data(head.utf8) + bodyData
        client.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }
}

// MARK: - Parsing

struct HostPort: Equatable, Sendable {
    var host: String
    var port: UInt16

    /// Accepts `host:port`, `[v6]:port`, and, when a default port is given, a bare host.
    init?(authority: String, defaultPort: UInt16?) {
        var hostPart = Substring(authority)
        var portPart: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            hostPart = authority[authority.index(after: authority.startIndex)..<close]
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") {
                portPart = rest.dropFirst()
            } else if !rest.isEmpty {
                return nil
            }
        } else if let colon = authority.lastIndex(of: ":") {
            hostPart = authority[..<colon]
            portPart = authority[authority.index(after: colon)...]
        }
        guard !hostPart.isEmpty, !hostPart.contains(where: { $0.isWhitespace }) else { return nil }
        if let portPart {
            guard let port = UInt16(portPart), port > 0 else { return nil }
            self.port = port
        } else if let defaultPort {
            self.port = defaultPort
        } else {
            return nil
        }
        host = String(hostPart)
    }
}

struct ProxyRequest {
    var method: String
    var target: String
    var version: String
    var headers: [(name: String, value: String)]

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, !requestLine[1].isEmpty,
              requestLine[2].hasPrefix("HTTP/1.")
        else { return nil }
        method = String(requestLine[0])
        target = String(requestLine[1])
        version = String(requestLine[2])
        headers = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func hasCredentials(_ credentials: ProxyCredentials) -> Bool {
        guard let value = header("Proxy-Authorization") else { return false }
        let parts = value.split(separator: " ", maxSplits: 1)
        return parts.count == 2
            && parts[0].caseInsensitiveCompare("Basic") == .orderedSame
            && parts[1].trimmingCharacters(in: .whitespaces) == credentials.basicToken
    }

    /// The Host header, only if it is safe to echo into a page or PAC file.
    var safeHostHeader: String? {
        guard let host = header("Host"), !host.isEmpty, host.count <= 255 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]"))
        return host.unicodeScalars.allSatisfy(allowed.contains) ? host : nil
    }

    /// Rewrites an absolute-form request so it can be sent straight to the origin server.
    func forwardedHTTPRequest() -> (target: HostPort, head: Data)? {
        guard let url = URLComponents(string: target),
              url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty,
              let port = UInt16(exactly: url.port ?? 80), port > 0
        else { return nil }
        let bareHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let destination = HostPort(authority: bareHost.contains(":") ? "[\(bareHost)]:\(port)" : "\(bareHost):\(port)", defaultPort: nil) else {
            return nil
        }
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { path += "?\(query)" }

        let dropped: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        var head = "\(method) \(path) \(version)\r\n"
        var hasHost = false
        for (name, value) in headers where !dropped.contains(name.lowercased()) {
            if name.lowercased() == "host" { hasHost = true }
            head += "\(name): \(value)\r\n"
        }
        if !hasHost {
            let authority = port == 80 ? host : "\(host):\(port)"
            head += "Host: \(authority)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return (destination, Data(head.utf8))
    }
}

enum DestinationPolicy {
    static func isBlocked(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if let address = IPv4Address(host) { return isBlocked(ipv4: [UInt8](address.rawValue)) }
        if let address = IPv6Address(host) { return isBlocked(ipv6: [UInt8](address.rawValue)) }
        return false
    }

    static func isBlocked(endpointHost host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return isBlocked(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return isBlocked(ipv6: [UInt8](address.rawValue))
        case .name(let name, _): return isBlocked(host: name)
        @unknown default: return true
        }
    }

    private static func isBlocked(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _): return true
        case (100, 64...127): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return bytes[0] >= 224
        }
    }

    private static func isBlocked(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] <= 1 { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isBlocked(ipv4: Array(bytes[12...]))
        }
        if bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        return bytes[0] == 0xff
    }
}

enum LocalPages {
    static func pac(address: String) -> String {
        "function FindProxyForURL(url, host) { return \"PROXY \(address)\"; }\n"
    }

    /// `address` has already been restricted to host characters by `safeHostHeader`.
    static func landing(address: String) -> String {
        """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>PuenteWiFi</title>
        <style>body{font:17px -apple-system,system-ui,sans-serif;max-width:34em;margin:2em auto;padding:0 1em;line-height:1.5}
        code{background:#8882;padding:.1em .35em;border-radius:4px}</style></head><body>
        <h1>PuenteWiFi</h1>
        <p><strong>Opción 1: aceptar el portal en este dispositivo.</strong>
        Abre <a href="http://neverssl.com">http://neverssl.com</a> y acepta los términos si aparecen.</p>
        <p><strong>Opción 2: usar el proxy del iPhone.</strong>
        En los ajustes de red de este dispositivo elige proxy manual con servidor y puerto
        <code>\(address)</code>, o la configuración automática
        <code>http://\(address)/proxy.pac</code>. El usuario y la contraseña aparecen en la app.</p>
        </body></html>
        """
    }
}
