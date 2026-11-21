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
/// Holds the web view and makes it shorter while the keyboard is up (like Android's adjustResize):
/// the lake's own layout then puts the input bar right above the keyboard and the messages move up
/// with it, instead of iOS pushing the whole page (background and all) up. The page pins its
/// wallpaper to the full height (html.in-app in index.html), so the background stays still.
final class LakeHost: UIView {
    let web: WKWebView
    var tabs: NativeTabs?
    var chatBar: NativeChatBar?
    var composer: NativeComposer?
    /// The keyboard's overlap while the composer has it: the composer rides on it, the lake stays full height.
    var composerKeyboard: CGFloat = 0
    /// The web's kaomoji drawer at the bottom: the composer sits on top of it.
    var drawerHeight: CGFloat = 0
    /// How much of the bottom the composer (and whatever is under it) covers, for the chat's padding.
    var onComposerCover: ((CGFloat) -> Void)?
    var keyboardOverlap: CGFloat = 0 {
        didSet { if keyboardOverlap != oldValue { setNeedsLayout(); layoutIfNeeded() } }
    }

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds + center, not frame: EdgeNav moves the web view with a transform while a swipe is on.
        let height = max(0, bounds.height - keyboardOverlap)
        web.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        web.center = CGPoint(x: bounds.width / 2, y: height / 2)
        tabs?.layout(in: bounds)
        if let chatBar {
            let transform = chatBar.transform
            chatBar.transform = .identity
            chatBar.frame = CGRect(x: 12, y: safeAreaInsets.top + 4, width: bounds.width - 24, height: NativeChatBar.height)
            chatBar.transform = transform
        }
        if let composer {
            let h = composer.barHeight
            let bottom = max(safeAreaInsets.bottom, 8)
            let lift = composerKeyboard > 0 ? composerKeyboard + 6 : drawerHeight > 0 ? drawerHeight + 6 : bottom + 2
            let transform = composer.transform
            composer.transform = .identity
            composer.frame = CGRect(x: 10, y: bounds.height - lift - h, width: bounds.width - 20, height: h)
            composer.transform = transform
            onComposerCover?(lift + h)
        }
    }
}

struct LakeView: UIViewRepresentable {
    let url: URL
    /// Clawd's line from the poll; the chat's top bar shows it under the name.
    let islandLine: String
    /// Bumped by the Clawd sheet's "reload" button.
    let reloadToken: Int
    let onCommand: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(home: url, token: reloadToken, onCommand: onCommand) }

    func makeUIView(context: Context) -> LakeHost {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // localStorage and cookies survive a restart
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // The lake can tell it is inside the App by this (and by window.webkit.messageHandlers.lelac).
        config.applicationNameForUserAgent = "Mobile/15E148 LeLacApp/1"
        config.userContentController.add(context.coordinator, name: "lelac")
        // Edge swipes are native here (EdgeNav.swift); swipe.js sees this and hands them over.
        config.userContentController.addUserScript(WKUserScript(source: "window.__nativeNav = 1; window.__nativeComposer = 1; window.__nativeImage = 1;",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false   // the lake has its own edge swipe (swipe.js)
        web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false                    // no whole-page rubber band; inner lists still scroll
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        let host = LakeHost(web: web)
        host.backgroundColor = .systemBackground
        context.coordinator.web = web
        context.coordinator.host = host
        context.coordinator.watchKeyboard()
        context.coordinator.watchLandings()
        context.coordinator.edges.install(on: host)
        let tabs = NativeTabs()
        host.tabs = tabs
        host.addSubview(tabs.bar)
        context.coordinator.edges.tabs = tabs
        tabs.onPick = { [weak coordinator = context.coordinator] key in coordinator?.picked(key) }
        let chatBar = NativeChatBar()
        chatBar.isHidden = true
        host.chatBar = chatBar
        host.addSubview(chatBar)
        context.coordinator.edges.chatBar = chatBar
        chatBar.set(line: islandLine)
        let c = context.coordinator
        chatBar.onMenu = { [weak c] in c?.edges.top = false; c?.click("roomsBtn") }
        chatBar.onTide = { [weak c] in c?.click("ptideBtn") }
        chatBar.onPark = { [weak c] in c?.click("parkBtn") }
        let composer = NativeComposer()
        composer.isHidden = true
        host.composer = composer
        host.addSubview(composer)
        context.coordinator.edges.composer = composer
        composer.uploadURL = url.appendingPathComponent("api/upload")
        composer.js = { [weak c] body, args, done in c?.run(body, args, done) }
        composer.onResize = { [weak host] in
            guard let host else { return }
            UIView.animate(withDuration: 0.15) { host.setNeedsLayout(); host.layoutIfNeeded() }
        }
        host.onComposerCover = { [weak c] cover in c?.cover(cover) }
        c.watchDismiss()
        // Launched by a tap on a notification: open the lake right there (index.html reads ?nroom= etc.).
        web.load(URLRequest(url: Coordinator.landingURL(url, Notices.shared.takeLanding())))
        return host
    }

    func updateUIView(_ host: LakeHost, context: Context) {
        let web = host.web
        let c = context.coordinator
        c.onCommand = onCommand
        host.chatBar?.set(line: islandLine)
        if c.home != url {
            c.home = url
            web.load(URLRequest(url: url))
        } else if c.token != reloadToken {
            c.token = reloadToken
            web.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        weak var web: WKWebView?
        weak var host: LakeHost?
        var home: URL
        private var offsetWatch: NSKeyValueObservation?
        let edges = EdgeNav()
        var token: Int
        var onCommand: (String) -> Void

        init(home: URL, token: Int, onCommand: @escaping (String) -> Void) {
            self.home = home
            self.token = token
            self.onCommand = onCommand
        }

        private func isLake(_ url: URL) -> Bool { url.host == home.host && url.port == home.port }
        /// Our other rooms on the same machine, behind another port (双弈 8448, Coread 8445 ...).
        private func isHome(_ url: URL) -> Bool { url.host == home.host }

        // MARK: notification taps

        private var loaded = false

        static func landingURL(_ home: URL, _ land: [String: Any]?) -> URL {
            guard let land, var parts = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return home }
            var items = parts.queryItems ?? []
            for key in ["room", "msg", "page"] { if let value = land[key] { items.append(.init(name: "n" + key, value: "\(value)")) } }
            parts.queryItems = items
            return parts.url ?? home
        }

        func watchLandings() {
            NotificationCenter.default.addObserver(self, selector: #selector(landingArrived),
                                                   name: Notices.landing, object: nil)
        }

        /// A tap while the App is already running: hand it to the page (it closes whatever is open and
        /// goes to that room). Before the page has finished loading it waits for didFinish.
        @objc private func landingArrived() {
            guard loaded else { return }
            deliverLanding()
        }

        private func deliverLanding() {
            guard let land = Notices.shared.takeLanding(), let web,
                  let data = try? JSONSerialization.data(withJSONObject: land),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.lakeOpenFromNotice && window.lakeOpenFromNotice(\(json))") { _, error in
                if error != nil { web.load(URLRequest(url: Self.landingURL(self.home, land))) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === web else { return }
            loaded = true
            lastCover = -1                 // a fresh page has not heard the composer's size yet
            host?.setNeedsLayout()
            deliverLanding()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if webView === web { loaded = false }
        }

        // MARK: the native bars

        /// The web's own (hidden) header buttons still do the work: ☰ also knows the "jump back" state.
        func click(_ id: String) {
            web?.callAsyncJavaScript("const b = document.getElementById(id); if (b) b.click();",
                                     arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
        }

        /// Chat slides the tabs away like the left-edge swipe; the other tabs switch at once (App Store does).
        func picked(_ key: String) {
            if key == "chat" { edges.run(left: true, to: "chat"); return }
            web?.callAsyncJavaScript("window.NativeNav && window.NativeNav.tap(t)", arguments: ["t": key],
                                     in: nil, in: .page, completionHandler: nil)
        }

        // MARK: keyboard

        func watchKeyboard() {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoved(_:)),
                                                   name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoved(_:)),
                                                   name: UIResponder.keyboardWillHideNotification, object: nil)
            // WebKit still tries to scroll the whole page to "reveal" the input; the page is already
            // above the keyboard, so any such scroll is the old push-up. Put it back.
            offsetWatch = web?.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                guard let self, (self.host?.keyboardOverlap ?? 0) > 0, scroll.contentOffset != .zero else { return }
                scroll.contentOffset = .zero
            }
        }

        @objc private func keyboardMoved(_ note: Notification) {
            guard let host, let window = host.window else { return }
            var overlap: CGFloat = 0
            if note.name != UIResponder.keyboardWillHideNotification,
               let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                let keyboard = window.convert(end, from: nil)
                let mine = host.convert(host.bounds, to: window)
                overlap = max(0, mine.maxY - keyboard.minY)
            }
            // The composer has the keyboard: it rides on it and the lake stays full height, so the chat shows
            // through the keyboard. A field inside the lake has it: the lake gets shorter, as before.
            let editing = host.composer?.textView.isFirstResponder == true
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
            UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
                host.composerKeyboard = editing ? overlap : 0
                host.keyboardOverlap = editing ? 0 : overlap
                host.setNeedsLayout()
                host.layoutIfNeeded()
            }
            if overlap == 0 || editing { web?.scrollView.contentOffset = .zero }
            if editing && overlap > 0 { hookDragToDismiss() }
        }

        // MARK: the composer

        private var lastCover: CGFloat = -1

        func run(_ body: String, _ args: [String: Any], _ done: ((Any?) -> Void)?) {
            web?.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                done?(try? result.get())
            }
        }

        /// The chat keeps this much room at the bottom (composer + keyboard or drawer).
        func cover(_ value: CGFloat) {
            guard abs(value - lastCover) > 0.5 else { return }
            lastCover = value
            run("window.NativeComposer && window.NativeComposer.inset(px)", ["px": value], nil)
        }

        private func composerSaid(_ body: [String: Any]) {
            guard let host, let composer = host.composer else { return }
            if let text = body["text"] as? String { composer.set(text: text) }
            if let mode = body["mode"] as? String { composer.set(mode: mode) }
            if let open = body["drawerOpen"] as? Bool {
                composer.set(drawerOpen: open)
                let height = open ? 272 + host.safeAreaInsets.bottom : 0
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                    host.drawerHeight = height
                    host.setNeedsLayout()
                    host.layoutIfNeeded()
                }
            }
            if let measured = body["drawer"] as? Double, composer.drawerOpen, measured > 0 {
                UIView.animate(withDuration: 0.12) {
                    host.drawerHeight = CGFloat(measured)
                    host.setNeedsLayout()
                    host.layoutIfNeeded()
                }
            }
        }

        // MARK: putting the keyboard away (tap the chat, or drag it down — like Telegram)

        private var hookedScrolls = Set<ObjectIdentifier>()

        func watchDismiss() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedLake))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            web?.addGestureRecognizer(tap)
        }

        @objc private func tappedLake() { host?.composer?.textView.resignFirstResponder() }

        /// The chat list is a scroll view inside the web view (WebKit makes one per scrolling element):
        /// a downward drag on it puts the keyboard away.
        private func hookDragToDismiss() {
            guard let web else { return }
            var stack: [UIView] = [web]
            while let view = stack.popLast() {
                if let scroll = view as? UIScrollView, !hookedScrolls.contains(ObjectIdentifier(scroll)) {
                    hookedScrolls.insert(ObjectIdentifier(scroll))
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(dragged(_:)))
                }
                stack.append(contentsOf: view.subviews)
            }
        }

        @objc private func dragged(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .changed, let composer = host?.composer, composer.textView.isFirstResponder else { return }
            let v = pan.velocity(in: pan.view)
            if v.y > 250 && abs(v.y) > abs(v.x) { composer.textView.resignFirstResponder() }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: our other rooms, in a sheet

        /// 双弈 and the other services on the same machine open over the lake, inside the App;
        /// swipe the sheet down to come back.
        @discardableResult
        private func openInside(_ url: URL?, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
            let config = configuration ?? WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            let view = WKWebView(frame: .zero, configuration: config)
            view.allowsLinkPreview = false
            view.uiDelegate = self
            let page = UIViewController()
            page.view = view
            page.modalPresentationStyle = .pageSheet
            if let url { view.load(URLRequest(url: url)) }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            while let next = top?.presentedViewController { top = next }
            top?.present(page, animated: true)
            return view
        }

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
            // A tapped link to another site, in the main page (not inside an iframe such as Roadbook):
            // our own rooms open in a sheet, everything else in Safari.
            if webView === web, action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
               !isLake(target) {
                if isHome(target) { openInside(target) } else { UIApplication.shared.open(target) }
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
            guard let target = action.request.url else { return nil }
            if isHome(target) && !isLake(target) { return openInside(nil, configuration: configuration) }
            UIApplication.shared.open(target)
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
            case "nav":
                edges.left = body?["left"] as? String ?? ""
                edges.right = body?["right"] as? String ?? ""
                edges.tab = body?["tab"] as? String ?? ""
                edges.top = body?["top"] as? Bool ?? false
                if !edges.top { host?.composer?.textView.resignFirstResponder() }
            case "chrome":
                host?.chatBar?.set(title: body?["title"] as? String, typing: body?["typing"] as? Bool,
                                   avatar: body?["avatar"] as? String)
                if let tone = body?["tone"] as? String { host?.composer?.set(tone: tone) }
            case "composer":
                composerSaid(body ?? [:])
            case "image":
                let urls = (body?["urls"] as? [String] ?? []).compactMap(URL.init(string:))
                guard !urls.isEmpty else { break }
                host?.composer?.textView.resignFirstResponder()
                let viewer = ImageViewer(urls: urls, index: body?["index"] as? Int ?? 0)
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                while let next = top?.presentedViewController { top = next }
                top?.present(viewer, animated: true)
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
