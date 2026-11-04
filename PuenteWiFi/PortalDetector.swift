import Foundation

enum PortalCheckResult: Equatable, Sendable {
    case online
    case portal(URL)
    case failed(String)
}

/// Detects captive portals using the same plain-HTTP probe iOS itself uses.
enum PortalDetector {
    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    /// Never served over HTTPS, so any browser on any device gets redirected to the portal.
    static let universalTriggerURL = URL(string: "http://neverssl.com")!

    static func check() async -> PortalCheckResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: probeURL)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Respuesta inesperada de la red.")
            }
            return classify(
                statusCode: http.statusCode,
                location: http.value(forHTTPHeaderField: "Location"),
                body: String(decoding: data, as: UTF8.self),
                probeURL: probeURL
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func classify(statusCode: Int, location: String?, body: String, probeURL: URL) -> PortalCheckResult {
        if (300...399).contains(statusCode) {
            if let location, let url = webURL(location, relativeTo: probeURL) {
                return .portal(url)
            }
            return .portal(probeURL)
        }
        if statusCode == 200, body.range(of: "<BODY>Success</BODY>", options: .caseInsensitive) != nil {
            return .online
        }
        // Anything else was injected by the network, so the portal is intercepting the probe.
        return .portal(portalURL(inHTML: body, relativeTo: probeURL) ?? probeURL)
    }

    static func portalURL(inHTML html: String, relativeTo base: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+http-equiv=["']?refresh["']?[^>]*content=["']?\s*\d+\s*;\s*url=([^"'>\s]+)"#,
            #"(?:window\.|document\.|top\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
        ]
        let range = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: html, range: range),
                let captured = Range(match.range(at: 1), in: html)
            else { continue }
            let candidate = html[captured].replacingOccurrences(of: "&amp;", with: "&")
            if let url = webURL(candidate, relativeTo: base) {
                return url
            }
        }
        return nil
    }

    private static func webURL(_ string: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

/// Builds a portal link for a device without a browser, such as a Roku or a Switch.
/// Works only on portals that carry the client's MAC address in their URL.
enum PortalMACRewriter {
    /// Returns the MAC as 12 lowercase hex digits, or nil if the input isn't a MAC.
    static func normalizedMAC(_ input: String) -> String? {
        let hex = input.lowercased().filter { $0 != ":" && $0 != "-" && !$0.isWhitespace }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Replaces every MAC-valued query parameter, or returns nil if the URL has none.
    static func rewrite(portalURL: URL, deviceMAC: String) -> URL? {
        guard let mac = normalizedMAC(deviceMAC),
              var components = URLComponents(url: portalURL, resolvingAgainstBaseURL: true),
              let items = components.queryItems
        else { return nil }

        var replaced = false
        components.queryItems = items.map { item in
            guard let value = item.value, let formatted = reformat(mac, like: value, parameter: item.name) else {
                return item
            }
            replaced = true
            return URLQueryItem(name: item.name, value: formatted)
        }
        return replaced ? components.url : nil
    }

    /// Portals also send the MAC of the access point, which must stay as it is.
    private static func isInfrastructureParameter(_ name: String) -> Bool {
        let name = name.lowercased()
        if name == "ap" { return true }
        return ["ap_mac", "apmac", "ap-mac", "bssid", "gw", "gateway", "router", "switch", "node", "called", "nas", "wlan", "radio"]
            .contains { name.contains($0) }
    }

    private static func reformat(_ mac: String, like value: String, parameter: String) -> String? {
        guard !isInfrastructureParameter(parameter), normalizedMAC(value) != nil else { return nil }
        let separator = value.first { $0 == ":" || $0 == "-" }
        // Twelve bare hex digits could be any token, so the parameter name must say it's a MAC.
        if separator == nil && !parameter.lowercased().contains("mac") { return nil }
        if separator != nil && value.count != 17 { return nil }

        let isUppercase = value.contains { $0.isLetter && $0.isUppercase }
        let digits = isUppercase ? mac.uppercased() : mac
        guard let separator else { return digits }
        return stride(from: 0, to: 12, by: 2).map { offset -> String in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return String(digits[start..<digits.index(start, offsetBy: 2)])
        }.joined(separator: String(separator))
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
