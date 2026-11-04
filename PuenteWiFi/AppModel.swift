import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Connectivity: Equatable {
        case unknown
        case checking
        case online
        case portal(URL)
        case failed(String)
    }

    @Published private(set) var connectivity: Connectivity = .unknown
    @Published private(set) var proxyState: ProxyServer.State = .stopped
    @Published private(set) var stats = ProxyServer.Stats()
    @Published private(set) var addresses: [LocalAddress] = []
    @Published private(set) var credentials: ProxyCredentials
    /// Stays available after this iPhone accepts, when the probe no longer sees the portal.
    @Published private(set) var lastPortalURL: URL?
    @Published var proxyWanted = false {
        didSet {
            guard proxyWanted != oldValue else { return }
            proxyWanted ? startProxy() : stopProxy()
        }
    }

    private static let passwordKey = "proxyPassword"
    private var server: ProxyServer?
    private var refreshTimer: Timer?

    var portalURL: URL? {
        if case .portal(let url) = connectivity { return url }
        return nil
    }

    var proxyPort: UInt16? {
        if case .running(let port) = proxyState { return port }
        return nil
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.passwordKey)
        let password = stored ?? Self.makePassword()
        UserDefaults.standard.set(password, forKey: Self.passwordKey)
        credentials = ProxyCredentials(username: "wifi", password: password)
        refreshAddresses()
    }

    func checkConnectivity() async {
        connectivity = .checking
        switch await PortalDetector.check() {
        case .online: connectivity = .online
        case .portal(let url):
            connectivity = .portal(url)
            lastPortalURL = url
        case .failed(let message): connectivity = .failed(message)
        }
        refreshAddresses()
    }

    func appBecameActive() {
        refreshAddresses()
        Task { await checkConnectivity() }
        // iOS suspends the listener in the background, so bring it back if it died.
        if proxyWanted, proxyPort == nil { restartProxy() }
    }

    func regeneratePassword() {
        let password = Self.makePassword()
        UserDefaults.standard.set(password, forKey: Self.passwordKey)
        credentials.password = password
        if proxyWanted { restartProxy() }
    }

    private func restartProxy() {
        stopProxy()
        startProxy()
    }

    private func startProxy() {
        let server = ProxyServer(
            configuration: .init(credentials: credentials)
        ) { [weak self] state in
            Task { @MainActor [weak self] in self?.proxyState = state }
        }
        self.server = server
        server.start()
        UIApplication.shared.isIdleTimerDisabled = true

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRunningInfo() }
        }
    }

    private func stopProxy() {
        server?.stop()
        server = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        stats = .init()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func refreshRunningInfo() {
        refreshAddresses()
        server?.readStats { [weak self] stats in
            Task { @MainActor [weak self] in self?.stats = stats }
        }
    }

    private func refreshAddresses() {
        let current = NetworkInfo.localAddresses()
        if current != addresses { addresses = current }
    }

    private static func makePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }
}
