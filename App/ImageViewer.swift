import UIKit

/// Looking at a picture, natively (2026/11/22, after 宝宝 asked what else is worth writing in Swift).
/// The web's lightbox did its own pinch and drag; here it is the system's: pinch and double-tap to zoom,
/// swipe sideways through an album, flick down (or tap) to close, long-press to save or share.
/// index.html's openLightbox hands the pictures over with `{cmd: "image", urls, index}`.
final class ImageViewer: UIViewController, UIScrollViewDelegate {
    private let urls: [URL]
    private var index: Int
    private let pager = UIScrollView()
    private var pages: [ZoomPage] = []
    private let counter = UILabel()
    private let backdrop = UIView()

    init(urls: [URL], index: Int) {
        self.urls = urls
        self.index = max(0, min(index, urls.count - 1))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        view.addSubview(backdrop)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)
        pages = urls.map { url in
            let page = ZoomPage(url: url)
            pager.addSubview(page)
            return page
        }

        counter.textColor = .white
        counter.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        counter.textAlignment = .center
        counter.isHidden = urls.count < 2
        view.addSubview(counter)

        let single = UITapGestureRecognizer(target: self, action: #selector(close))
        let double = UITapGestureRecognizer(target: self, action: #selector(zoomToggle(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        let pull = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pull.delegate = self
        view.addGestureRecognizer(pull)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        view.addGestureRecognizer(hold)
        updateCounter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        pager.frame = view.bounds
        let w = view.bounds.width
        for (i, page) in pages.enumerated() {
            page.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: view.bounds.height)
        }
        pager.contentSize = CGSize(width: w * CGFloat(pages.count), height: view.bounds.height)
        pager.contentOffset = CGPoint(x: CGFloat(index) * w, y: 0)
        counter.frame = CGRect(x: 0, y: view.safeAreaInsets.top + 8, width: view.bounds.width, height: 22)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let w = max(1, scrollView.bounds.width)
        let now = Int(round(scrollView.contentOffset.x / w))
        if now != index {
            pages[safe: index]?.resetZoom()
            index = now
            updateCounter()
        }
    }

    private func updateCounter() { counter.text = "\(index + 1) / \(urls.count)" }

    private var current: ZoomPage? { pages[safe: index] }

    @objc private func close() { dismiss(animated: true) }

    @objc private func zoomToggle(_ tap: UITapGestureRecognizer) {
        guard let page = current else { return }
        page.toggleZoom(at: tap.location(in: page.imageView))
    }

    // MARK: flick down to close

    @objc private func pulled(_ pan: UIPanGestureRecognizer) {
        guard let page = current else { return }
        let t = pan.translation(in: view)
        switch pan.state {
        case .changed:
            page.imageView.transform = CGAffineTransform(translationX: t.x, y: t.y)
                .scaledBy(x: max(0.7, 1 - abs(t.y) / 1600), y: max(0.7, 1 - abs(t.y) / 1600))
            backdrop.alpha = max(0, 1 - abs(t.y) / 400)
            counter.alpha = backdrop.alpha
        case .ended, .cancelled:
            let v = pan.velocity(in: view).y
            if abs(t.y) > 120 || abs(v) > 900 {
                UIView.animate(withDuration: 0.22, animations: {
                    page.imageView.transform = CGAffineTransform(translationX: t.x, y: t.y + (t.y >= 0 ? 1 : -1) * 500)
                    self.backdrop.alpha = 0
                    self.counter.alpha = 0
                }, completion: { _ in self.dismiss(animated: false) })
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    page.imageView.transform = .identity
                    self.backdrop.alpha = 1
                    self.counter.alpha = 1
                }
            }
        default:
            break
        }
    }

    // MARK: save or share

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, let image = current?.imageView.image else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        present(share, animated: true)
    }
}

extension ImageViewer: UIGestureRecognizerDelegate {
    /// The flick only starts when it is mostly vertical and the picture is not zoomed in.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, pan.view === view else { return true }
        guard let page = current, page.zoomScale <= page.minimumZoomScale + 0.01 else { return false }
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x) * 1.2
    }
}

/// One picture that zooms.
final class ZoomPage: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(url: URL) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        spinner.color = .white
        spinner.startAnimating()
        addSubview(spinner)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(UIImage.init(data:))
            DispatchQueue.main.async {
                self?.spinner.stopAnimating()
                self?.imageView.image = image
                self?.setNeedsLayout()
            }
        }.resume()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard zoomScale <= minimumZoomScale + 0.001 else { return }
        // At rest the picture is its fitted size, centred by the insets; zooming scales it from there.
        let fitted = fittedSize
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centre()
    }

    private var fittedSize: CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return bounds.size }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * fit, height: image.size.height * fit)
    }

    private func centre() {
        let x = max(0, (bounds.width - imageView.frame.width) / 2)
        let y = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func toggleZoom(at point: CGPoint) {
        if zoomScale > minimumZoomScale + 0.01 { resetZoom(); return }
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: true)
    }

    func resetZoom() { setZoomScale(minimumZoomScale, animated: true) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
