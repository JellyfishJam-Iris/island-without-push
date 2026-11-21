import SwiftUI
import UIKit
import WebKit

/// The lake itself, in a WKWebView (2026/11/22: the PWA becomes an App, step 1 of ~/lelac/docs/app-roadmap.md).
///
/// The web front-end stays the one source of truth: change the lake, refresh, done; this shell only
/// changes when it needs a native hand. What it adds: full screen under the safe areas (the page's own
/// env(safe-area-inset-*) does the padding), links to other sites open in Safari, camera and microphone
/// granted to the lake's own pages, a page that died in the background comes back by itself, and a
/// small bridge: `window.webkit.messageHandlers.lelac.postMessage({cmd: ...})`.
struct LakeView: UIViewRepresentable {
    let url: URL
    /// Bumped by the Clawd sheet's "reload" button.
    let reloadToken: Int
    let onCommand: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(home: url, token: reloadToken, onCommand: onCommand) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // localStorage and cookies survive a restart
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // The lake can tell it is inside the App by this (and by window.webkit.messageHandlers.lelac).
        config.applicationNameForUserAgent = "Mobile/15E148 LeLacApp/1"
        config.userContentController.add(context.coordinator, name: "lelac")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false   // the lake has its own edge swipe (swipe.js)
        web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false                    // no whole-page rubber band; inner lists still scroll
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        context.coordinator.web = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onCommand = onCommand
        if c.home != url {
            c.home = url
            web.load(URLRequest(url: url))
        } else if c.token != reloadToken {
            c.token = reloadToken
            web.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var home: URL
        var token: Int
        var onCommand: (String) -> Void

        init(home: URL, token: Int, onCommand: @escaping (String) -> Void) {
            self.home = home
            self.token = token
            self.onCommand = onCommand
        }

        private func isLake(_ url: URL) -> Bool { url.host == home.host && url.port == home.port }

        // MARK: links

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url, let scheme = target.scheme?.lowercased() else {
                decisionHandler(.allow); return
            }
            if ["about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
            if !["http", "https"].contains(scheme) {          // tel:, mailto:, maps: ...
                UIApplication.shared.open(target)
                decisionHandler(.cancel); return
            }
            // A tapped link to another site, in the main page (not inside an iframe such as Roadbook): Safari.
            if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true, !isLake(target) {
                UIApplication.shared.open(target)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        /// The lake answered with an error page (a wrong address gives FastAPI's {"detail":"Not Found"}).
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                DispatchQueue.main.async { self.onCommand("unreachable") }
            }
            decisionHandler(.allow)
        }

        /// No answer at all (offline, wrong host). Cancelled loads (-999) and our own hand-offs to
        /// Safari (WebKit 102) are not failures.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let e = error as NSError
            if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
            onCommand("unreachable")
        }

        /// window.open / target=_blank: never replace the lake, hand it to Safari (it also takes downloads).
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url { UIApplication.shared.open(target) }
            return nil
        }

        /// iOS reclaimed the page's process while the App sat in the background: the view is blank now,
        /// so loading it again is the only way back (not an auto-reload of a live page).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: home))
        }

        // MARK: camera, microphone

        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == home.host ? .grant : .prompt)
        }

        // MARK: alert / confirm / prompt (WKWebView shows nothing for these unless the App draws them)

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(alert, or: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "算了", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            present(alert, or: { completionHandler(false) })
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "算了", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in
                completionHandler(alert?.textFields?.first?.text)
            })
            present(alert, or: { completionHandler(nil) })
        }

        private func present(_ alert: UIAlertController, or fallback: @escaping () -> Void) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let top else { fallback(); return }
            top.present(alert, animated: true)
        }

        // MARK: the bridge

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any]
            let cmd = (body?["cmd"] as? String) ?? (message.body as? String) ?? ""
            switch cmd {
            case "haptic":
                Self.haptic(body?["style"] as? String ?? "light")
            default:
                onCommand(cmd)
            }
        }

        private static func haptic(_ style: String) {
            switch style {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "select": UISelectionFeedbackGenerator().selectionChanged()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
