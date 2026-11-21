import UIKit
import WebKit

/// Native edge swipes over the lake (2026/11/22, 宝宝 wanted Telegram's feel: "我想要tg那种交互").
///
/// In the web, every finger move waited for JavaScript before the page moved. Here the finger drives
/// native layers instead: when an edge pan begins, the web view's current picture is snapshotted, the
/// page underneath switches instantly to where the swipe goes (swipe.js `NativeNav.begin`), and what
/// follows the finger is the snapshot (going left) or the live web view (going right), with the iOS
/// parallax, dimming and shadow, settled by a spring that keeps the finger's speed.
///
/// The places are a folding screen (她 11/22: "逻辑上是一扇屏风一样，左/右滑就是相邻的页面"):
/// [rooms drawer] Chat · Memory · To-do · Others. Left edge goes one leaf left, right edge one leaf right;
/// a page opened on top goes back with the left edge. The page tells us what each edge can do right now
/// (`{cmd: "nav", left, right, tab}`); an edge with nothing to do does not begin, so the rooms drawer
/// (left of the chat) is still dragged by the web itself.
///
/// The native tab bar (NativeTabs) rides along: between the chat and the tabs it moves with the page,
/// between two tabs it stays put, under a closing page it waits underneath.
final class EdgeNav: NSObject, UIGestureRecognizerDelegate {
    weak var host: LakeHost?
    weak var tabs: NativeTabs?
    weak var chatBar: NativeChatBar?
    weak var composer: NativeComposer?
    /// The chat's own native pieces (top bar, composer): they come and go, and travel, together.
    private var chatChrome: [UIView] { [chatBar, composer].compactMap { $0 } }
    /// What the page last said: the leaf (or "page") each edge leads to, "" for nothing; the tab on screen.
    var left = ""
    var right = ""
    var tab = "" { didSet { if !busy { tabs?.show(tab) } } }
    /// The chat is showing (no page, no drawer, no tabs): only then the chat's top bar is out.
    var top = false { didSet { if !busy && top != oldValue { showTop(top) } } }
    private enum Follow { case none, snap, web }
    private var topFollows = Follow.none

    private var snap: UIView?
    private var dim: UIView?
    private var push = false
    private var mode = ""            // "pop" / "push" once the page answered; "" while waiting
    private var moveBar = false      // the bar travels with the moving layer (chat <-> tabs)
    private var landing = ""         // the tab the swipe lands on ("" = the chat)
    private var fromTab = ""         // the tab under the finger when the swipe began
    private var progress: CGFloat = 0
    private var busy = false         // from the first touch until everything is put back
    private var endedEarly: (go: Bool, velocity: CGFloat)?

    private var web: WKWebView? { host?.web }

    func install(on host: LakeHost) {
        self.host = host
        for edge in [UIRectEdge.left, .right] {
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.edges = edge
            pan.delegate = self
            host.addGestureRecognizer(pan)
        }
    }

    /// The same slide without a finger: tapping Chat on the bar slides the tabs away to the chat.
    func run(left: Bool, to target: String) {
        guard !busy, let host, let web else { return }
        progress = 0
        begin(push: !left, target: target, host: host, web: web)
        endedEarly = (true, 0)
    }

    // MARK: gesture delegate

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard !busy, let pan = recognizer as? UIScreenEdgePanGestureRecognizer else { return false }
        return pan.edges == .left ? !left.isEmpty : !right.isEmpty
    }

    /// The web's own scrolling near an edge waits for us to fail (we fail at once away from the edge).
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let web, let view = other.view else { return false }
        return other is UIPanGestureRecognizer && view.isDescendant(of: web)
    }

    // MARK: the swipe

    @objc private func pan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard let host, let web else { return }
        let width = max(1, host.bounds.width)
        let dir: CGFloat = recognizer.edges == .left ? 1 : -1
        progress = max(0, min(1, recognizer.translation(in: host).x * dir / width))
        switch recognizer.state {
        case .began:
            begin(push: recognizer.edges == .right, target: "", host: host, web: web)
        case .changed:
            if !mode.isEmpty { apply(progress); followSelection() }
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: host).x * dir
            let go = recognizer.state == .ended && (progress > 0.5 || (velocity > 450 && progress > 0.04))
            if mode.isEmpty { endedEarly = (go, velocity) } else { finish(go: go, velocity: velocity) }
        default:
            break
        }
    }

    private func begin(push: Bool, target: String, host: LakeHost, web: WKWebView) {
        guard let picture = web.snapshotView(afterScreenUpdates: false) else { return }
        busy = true
        self.push = push
        mode = ""
        moveBar = false
        endedEarly = nil
        fromTab = tab
        picture.frame = web.frame
        picture.isUserInteractionEnabled = false
        let shade = UIView(frame: host.bounds)
        shade.backgroundColor = .black
        shade.alpha = 0
        shade.isUserInteractionEnabled = false
        if push {
            // The old picture stays behind; the live page (already on the next leaf) slides in from the right.
            host.insertSubview(picture, belowSubview: web)
            host.insertSubview(shade, belowSubview: web)
            web.transform = CGAffineTransform(translationX: host.bounds.width, y: 0)
            Self.shadow(web, on: true)
        } else {
            // The old picture goes on top and is what slides away; the leaf underneath is already there.
            host.insertSubview(shade, aboveSubview: web)
            host.insertSubview(picture, aboveSubview: shade)
            Self.shadow(picture, on: true)
        }
        snap = picture
        dim = shade
        web.callAsyncJavaScript("return window.NativeNav ? await window.NativeNav.begin(edge, to) : ''",
                                arguments: ["edge": push ? "right" : "left", "to": target],
                                in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            let parts = ((try? result.get()) as? String ?? "").split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty else { self.cleanUp(); return }
            self.mode = String(parts[0])
            self.moveBar = parts[1] == "1"
            self.landing = String(parts[2])
            self.placeBar()
            self.apply(self.progress)
            if let early = self.endedEarly { self.finish(go: early.go, velocity: early.velocity) }
        }
    }

    private func showTop(_ on: Bool) {
        for view in chatChrome {
            if on { view.alpha = 0; view.isHidden = false }
            UIView.animate(withDuration: 0.16, animations: { view.alpha = on ? 1 : 0 },
                           completion: { _ in if !self.top { view.isHidden = true }; view.alpha = 1 })
        }
    }

    /// Where the bars sit during the slide, in z-order and visibility.
    private func placeBar() {
        guard let host, let bar = tabs?.bar, let web, let snap else { return }
        topFollows = .none
        composer?.textView.resignFirstResponder()
        for view in chatChrome {
            if push && moveBar {
                // Leaving the chat: its bars go with the old picture, under the incoming tabs.
                host.insertSubview(view, aboveSubview: snap)
                topFollows = .snap
            } else if mode == "pop" && landing.isEmpty {
                // Coming back to the chat: the bars are there underneath, moving with the chat.
                view.alpha = 1
                view.isHidden = false
                host.insertSubview(view, aboveSubview: web)
                topFollows = .web
            } else {
                view.isHidden = true
            }
        }
        if moveBar {
            // Chat <-> tabs: the bar belongs to the tabs leaf, whichever layer that is.
            if push { tabs?.show(landing); host.insertSubview(bar, aboveSubview: web) }
            else { host.insertSubview(bar, aboveSubview: snap) }
        } else if mode == "pop" && tab.isEmpty && !landing.isEmpty {
            // A page closing over the tabs: the bar waits underneath, under the shade and the picture.
            tabs?.show(landing)
            host.insertSubview(bar, aboveSubview: web)
        } else {
            host.bringSubviewToFront(bar)      // tab <-> tab: the bar stays put on top
        }
    }

    /// Tab <-> tab: the bar's selection jumps once the finger is past half way, not after letting go
    /// (宝宝: "滑动切换页面的时候深色这个选区变得稍微有点慢").
    private func followSelection() {
        guard !moveBar, mode != "", !landing.isEmpty, !fromTab.isEmpty, landing != fromTab else { return }
        let want = progress > 0.5 ? landing : fromTab
        if tabs?.bar.selectedItem?.tag != NativeTabs.keys.firstIndex(of: want) { tabs?.show(want) }
    }

    /// p = how far along: 0 where the finger started, 1 at the destination.
    private func apply(_ p: CGFloat) {
        guard let host, let web, let snap, let dim else { return }
        let w = host.bounds.width
        if push {
            web.transform = CGAffineTransform(translationX: w * (1 - p), y: 0)
            snap.transform = CGAffineTransform(translationX: -0.3 * w * p, y: 0)
            dim.alpha = 0.12 * p
            if moveBar { tabs?.bar.transform = web.transform }
            if topFollows == .snap { chatChrome.forEach { $0.transform = snap.transform } }
        } else {
            snap.transform = CGAffineTransform(translationX: w * p, y: 0)
            web.transform = CGAffineTransform(translationX: -0.3 * w * (1 - p), y: 0)
            dim.alpha = 0.12 * (1 - p)
            if moveBar { tabs?.bar.transform = snap.transform }
            if topFollows == .web { chatChrome.forEach { $0.transform = web.transform } }
        }
    }

    private func finish(go: Bool, velocity: CGFloat) {
        guard let host else { cleanUp(); return }
        endedEarly = nil
        let target: CGFloat = go ? 1 : 0
        let distance = (target - progress) * host.bounds.width
        // The finger's speed carries into the spring (as a share of the distance left per second).
        let initial = abs(distance) > 1 ? max(-20, min(20, (go ? velocity : -velocity) / abs(distance))) : 0
        let spring = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: initial, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.36, timingParameters: spring)
        if !moveBar && !landing.isEmpty && !fromTab.isEmpty {   // tab <-> tab: the selection goes first
            tabs?.show(go ? landing : fromTab)
        }
        animator.addAnimations { self.apply(target) }
        animator.addCompletion { _ in self.settle(go: go) }
        animator.startAnimation()
    }

    private func settle(go: Bool) {
        guard let host, let web else { cleanUp(); return }
        if !go, let snap {
            // Back where it started: the picture covers everything while the page puts itself back.
            host.bringSubviewToFront(snap)
            snap.transform = .identity
            web.transform = .identity
            tabs?.bar.transform = .identity
            chatChrome.forEach { $0.transform = .identity }
        }
        web.callAsyncJavaScript("return window.NativeNav ? await window.NativeNav.end(go) : true",
                                arguments: ["go": go], in: nil, in: .page) { [weak self] _ in
            self?.cleanUp()
        }
    }

    private func cleanUp() {
        snap?.removeFromSuperview()
        dim?.removeFromSuperview()
        snap = nil
        dim = nil
        if let web {
            web.transform = .identity
            Self.shadow(web, on: false)
        }
        if let host, let bar = tabs?.bar {
            bar.transform = .identity
            host.bringSubviewToFront(bar)
        }
        if let host {
            for view in chatChrome {
                view.transform = .identity
                view.alpha = 1
                view.isHidden = !top
                host.bringSubviewToFront(view)
            }
            if let bar = tabs?.bar { host.bringSubviewToFront(bar) }
        }
        topFollows = .none
        mode = ""
        moveBar = false
        endedEarly = nil
        busy = false
        tabs?.show(tab)          // whatever the page said last
    }

    private static func shadow(_ view: UIView, on: Bool) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = on ? 0.16 : 0
        view.layer.shadowRadius = on ? 10 : 0
        view.layer.shadowOffset = CGSize(width: -3, height: 0)
        view.layer.shadowPath = on ? UIBezierPath(rect: view.bounds).cgPath : nil
    }
}
