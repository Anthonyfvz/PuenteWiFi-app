import SwiftUI
import WebKit

struct PortalSheet: View {
    let url: URL
    let onPageLoaded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            PortalWebView(url: url, reloadToken: reloadToken, onPageLoaded: onPageLoaded)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Portal del Wi-Fi")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Recargar") { reloadToken += 1 }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") { dismiss() }
                    }
                }
        }
    }
}

private struct PortalWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onPageLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageLoaded: onPageLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastReloadToken = reloadToken
        webView.load(Self.wifiOnlyRequest(url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPageLoaded = onPageLoaded
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        webView.load(Self.wifiOnlyRequest(webView.url ?? url))
    }

    private static func wifiOnlyRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = false
        return request
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onPageLoaded: () -> Void
        var lastReloadToken = 0

        init(onPageLoaded: @escaping () -> Void) {
            self.onPageLoaded = onPageLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageLoaded()
        }

        // Portals often open their accept button with target="_blank".
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // Without this, a portal's alert() would silently do nothing and can block its flow.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            present(on: webView, message: message, actions: [
                UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler() },
            ], otherwise: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            present(on: webView, message: message, actions: [
                UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(true) },
            ], otherwise: { completionHandler(false) })
        }

        private func present(on webView: WKWebView, message: String, actions: [UIAlertAction], otherwise: @escaping () -> Void) {
            var presenter = webView.window?.rootViewController
            while let next = presenter?.presentedViewController { presenter = next }
            guard let presenter else {
                otherwise()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            actions.forEach(alert.addAction)
            presenter.present(alert, animated: true)
        }
    }
}
