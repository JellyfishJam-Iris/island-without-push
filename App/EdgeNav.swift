import UIKit
import WebKit

/// Native edge swipes over the lake (2026/11/22, 宝宝 wanted Telegram's feel: "我想要tg那种交互").
///
/// In the web, every finger move waited for JavaScript before the page moved. Here the finger drives
/// native layers instead: when an edge pan begins, the web view's current picture is snapshotted, the
/// page underneath switches instantly to where the swipe goes (swipe.js `NativeNav.begin`), and what
/// follows the finger is the snapshot (going back) or the live web view (tabs sliding in), with the
/// iOS parallax, dimming and shadow, settled by a spring that keeps the finger's speed.
///
/// The page tells us what each edge can do right now (`{cmd: "nav", left, right}` through the lelac
/// bridge); an edge with nothing to do does not begin, so the rooms drawer (left edge on the chat) is
/// still dragged by the web itself.
final class EdgeNav: NSObject, UIGestureRecognizerDelegate {
    weak var host: LakeHost?
    /// "page" / "tabs" / "" for the left edge, "tabs" / "" for the right, as the page last said.
    var left = ""
    var right = ""

    private var snap: UIView?
    private var dim: UIView?
    private var push = false
    private var mode = ""            // "pop" / "push" once the page answered; "" while waiting
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
            begin(push: recognizer.edges == .right, host: host, web: web)
        case .changed:
            if !mode.isEmpty { apply(progress) }
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: host).x * dir
            let go = recognizer.state == .ended && (progress > 0.5 || (velocity > 450 && progress > 0.04))
            if mode.isEmpty { endedEarly = (go, velocity) } else { finish(go: go, velocity: velocity) }
        default:
            break
        }
    }

    private func begin(push: Bool, host: LakeHost, web: WKWebView) {
        guard let picture = web.snapshotView(afterScreenUpdates: false) else { return }
        busy = true
        self.push = push
        mode = ""
        endedEarly = nil
        picture.frame = web.frame
        picture.isUserInteractionEnabled = false
        let shade = UIView(frame: host.bounds)
        shade.backgroundColor = .black
        shade.alpha = 0
        shade.isUserInteractionEnabled = false
        if push {
            // The old picture stays behind; the live page (with the tabs already open) slides in from the right.
            host.insertSubview(picture, belowSubview: web)
            host.insertSubview(shade, belowSubview: web)
            web.transform = CGAffineTransform(translationX: host.bounds.width, y: 0)
            Self.shadow(web, on: true)
        } else {
            // The old picture goes on top and is what slides away; the page underneath is already there.
            host.addSubview(shade)
            host.addSubview(picture)
            Self.shadow(picture, on: true)
        }
        snap = picture
        dim = shade
        web.callAsyncJavaScript("return window.NativeNav ? await window.NativeNav.begin(edge) : ''",
                                arguments: ["edge": push ? "right" : "left"], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            let answer = (try? result.get()) as? String ?? ""
            guard !answer.isEmpty else { self.cleanUp(); return }
            self.mode = answer
            self.apply(self.progress)
            if let early = self.endedEarly { self.finish(go: early.go, velocity: early.velocity) }
        }
    }

    /// p = how far along: 0 where the finger started, 1 at the destination.
    private func apply(_ p: CGFloat) {
        guard let host, let web, let snap, let dim else { return }
        let w = host.bounds.width
        if push {
            web.transform = CGAffineTransform(translationX: w * (1 - p), y: 0)
            snap.transform = CGAffineTransform(translationX: -0.3 * w * p, y: 0)
            dim.alpha = 0.12 * p
        } else {
            snap.transform = CGAffineTransform(translationX: w * p, y: 0)
            web.transform = CGAffineTransform(translationX: -0.3 * w * (1 - p), y: 0)
            dim.alpha = 0.12 * (1 - p)
        }
    }

    private func finish(go: Bool, velocity: CGFloat) {
        guard let host else { cleanUp(); return }
        let target: CGFloat = go ? 1 : 0
        let distance = (target - progress) * host.bounds.width
        // The finger's speed carries into the spring (as a share of the distance left per second).
        let initial = abs(distance) > 1 ? max(-20, min(20, (go ? velocity : -velocity) / abs(distance))) : 0
        let spring = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: initial, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.36, timingParameters: spring)
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
        mode = ""
        endedEarly = nil
        busy = false
    }

    private static func shadow(_ view: UIView, on: Bool) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = on ? 0.16 : 0
        view.layer.shadowRadius = on ? 10 : 0
        view.layer.shadowOffset = CGSize(width: -3, height: 0)
        view.layer.shadowPath = on ? UIBezierPath(rect: view.bounds).cgPath : nil
    }
}
