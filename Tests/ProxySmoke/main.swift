import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func expect(_ condition: Bool, _ name: String) {
    print(condition ? "ok    \(name)" : "FALLA \(name)")
    if !condition { exit(1) }
}

let probe = PortalDetector.probeURL

expect(PortalDetector.classify(statusCode: 200, location: nil, body: "<HTML><BODY>Success</BODY></HTML>", probeURL: probe) == .online, "online")
expect(PortalDetector.classify(statusCode: 302, location: "http://portal.test/login?a=1", body: "", probeURL: probe) == .portal(URL(string: "http://portal.test/login?a=1")!), "redirect")
expect(PortalDetector.classify(statusCode: 302, location: "/login", body: "", probeURL: probe) == .portal(URL(string: "http://captive.apple.com/login")!), "relative redirect")
expect(PortalDetector.classify(statusCode: 302, location: "javascript:alert(1)", body: "", probeURL: probe) == .portal(probe), "rejects non-web scheme")
expect(PortalDetector.classify(statusCode: 200, location: nil, body: "<meta http-equiv=\"refresh\" content=\"0; url=http://portal.test/a?x=1&amp;y=2\">", probeURL: probe) == .portal(URL(string: "http://portal.test/a?x=1&y=2")!), "meta refresh")
expect(PortalDetector.classify(statusCode: 200, location: nil, body: "<script>window.location.href = 'https://portal.test/js';</script>", probeURL: probe) == .portal(URL(string: "https://portal.test/js")!), "js redirect")
expect(PortalDetector.classify(statusCode: 200, location: nil, body: "<html>acepta</html>", probeURL: probe) == .portal(probe), "unknown injected page")

let roku = "AA:BB:CC:11:22:33"
func rewritten(_ url: String) -> String? {
    PortalMACRewriter.rewrite(portalURL: URL(string: url)!, deviceMAC: roku)?.absoluteString
}
expect(rewritten("http://p.test/?client_mac=de:ad:be:ef:00:01&x=1") == "http://p.test/?client_mac=aa:bb:cc:11:22:33&x=1", "mac with colons, lowercase")
expect(rewritten("http://p.test/?id=DE-AD-BE-EF-00-01") == "http://p.test/?id=AA-BB-CC-11-22-33", "mac with dashes, uppercase")
expect(rewritten("http://p.test/?mac=deadbeef0001") == "http://p.test/?mac=aabbcc112233", "bare mac in mac parameter")
expect(rewritten("http://p.test/?token=deadbeef0001") == nil, "bare hex token untouched")
expect(rewritten("http://p.test/login") == nil, "no query")
expect(PortalMACRewriter.normalizedMAC("nope") == nil, "invalid mac")

for (host, blocked) in [
    ("localhost", true), ("LOCALHOST.", true), ("foo.local", true), ("127.0.0.1", true),
    ("10.1.2.3", true), ("172.20.10.1", true), ("192.168.0.1", true), ("169.254.1.1", true),
    ("::1", true), ("fe80::1", true), ("fd00::1", true), ("::ffff:192.168.0.1", true),
    ("8.8.8.8", false), ("172.32.0.1", false), ("example.com", false), ("2606:4700::1", false),
] {
    expect(DestinationPolicy.isBlocked(host: host) == blocked, "policy \(host)")
}

expect(HostPort(authority: "example.com:443", defaultPort: nil)?.port == 443, "authority")
expect(HostPort(authority: "[::1]:8443", defaultPort: nil)?.host == "::1", "v6 authority")
expect(HostPort(authority: "example.com", defaultPort: nil) == nil, "missing port")
expect(HostPort(authority: "example.com:99999", defaultPort: nil) == nil, "bad port")

let credentials = ProxyCredentials(username: "wifi", password: "secreto")
let open = ProxyServer(configuration: .init(port: 18080, credentials: credentials, requireWiFiUpstream: false, blockPrivateDestinations: false)) { print("open: \($0)") }
let guarded = ProxyServer(configuration: .init(port: 18082, credentials: credentials, requireWiFiUpstream: false, blockPrivateDestinations: true)) { print("guarded: \($0)") }
open.start()
guarded.start()
dispatchMain()
