import UIKit
import WebKit

/// Long-pressing a message, natively (2026/11/22). Second version after 宝宝 showed ChatGPT's
/// ("我们抄chatgpt…从我手指按下去的地方浮起？"): the chat dims a shade, the pressed bubble stays where it
/// is and stays bright (a hole in the dimming, no picture of it), and a glass card grows out of the
/// finger: the message's day and time on top, then icon + title rows. It sits beside the bubble when
/// there is room (below, else above), and over it only when the bubble is taller than the screen.
/// Each row presses the same button in the web's own menu (index.html openMsgSheet), so what Copy,
/// Favorite, Trace, Delete... do is not rewritten here.
final class MessageMenu: UIView {
    struct Item { let id: String; let title: String; let on: Bool; let danger: Bool }

    private let dim = CAShapeLayer()
    private let glass = NativeChatBar.glass(interactive: false)
    private let stack = UIStackView()
    private let bubble: CGRect
    private let holes: [CGRect]
    private let radius: CGFloat
    private let finger: CGPoint
    private let onPick: (String) -> Void
    private var picked = false

    private static let rowHeight: CGFloat = 44
    private static let headHeight: CGFloat = 34
    private static let width: CGFloat = 238

    /// `rect` and `finger` are in the web view's coordinates (CSS pixels are points there).
    /// `holes` are the message's bubbles (one message can be several); each stays bright.
    static func show(over web: WKWebView, rect: CGRect, holes: [CGRect], radius: CGFloat, finger: CGPoint, stamp: String,
                     items: [Item], onPick: @escaping (String) -> Void) {
        guard let window = web.window, !items.isEmpty else { return }
        let menu = MessageMenu(bubble: web.convert(rect, to: window),
                               holes: (holes.isEmpty ? [rect] : holes).map { web.convert($0, to: window) }, radius: radius,
                               finger: web.convert(finger, to: window), stamp: stamp, items: items, onPick: onPick)
        menu.frame = window.bounds
        window.addSubview(menu)
        menu.appear()
    }

    private init(bubble: CGRect, holes: [CGRect], radius: CGFloat, finger: CGPoint, stamp: String, items: [Item],
                 onPick: @escaping (String) -> Void) {
        self.bubble = bubble
        self.holes = holes
        self.radius = radius
        self.finger = finger
        self.onPick = onPick
        super.init(frame: .zero)
        dim.fillColor = UIColor.black.withAlphaComponent(0.2).cgColor
        dim.fillRule = .evenOdd
        layer.addSublayer(dim)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(outside)))

        glass.layer.cornerRadius = 26
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        stack.axis = .vertical
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        if !stamp.isEmpty {
            let head = UILabel()
            head.text = stamp
            head.font = .systemFont(ofSize: 14, weight: .medium)
            head.textColor = .secondaryLabel
            let box = UIView()
            box.addSubview(head)
            head.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                head.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 22),
                head.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                box.heightAnchor.constraint(equalToConstant: Self.headHeight),
            ])
            stack.addArrangedSubview(box)
        }
        items.forEach { stack.addArrangedSubview(row($0)) }
        glass.contentView.addSubview(stack)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Icon in a fixed column, centred; the titles all start on the same line (宝宝 11/22: smaller icons,
    /// and Trace's eye was pushed right because it is the widest).
    private func row(_ item: Item) -> UIView {
        let button = MenuRow()
        button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        let tint: UIColor = item.danger ? .systemRed : .label
        let icon = UIImageView(image: UIImage(systemName: Self.symbol(item),
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)))
        icon.tintColor = tint
        icon.contentMode = .center
        let title = UILabel()
        title.text = item.title
        title.font = .systemFont(ofSize: 17)
        title.textColor = tint
        [icon, title].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; button.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 54),
            title.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.addAction(UIAction { [weak self] _ in self?.pick(item.id) }, for: .touchUpInside)
        return button
    }

    private static func symbol(_ item: Item) -> String {
        switch item.id {
        case "msCopy": return "doc.on.doc"
        case "msEdit": return "pencil"
        case "msFav": return item.on ? "heart.slash" : "heart"
        case "msGal": return "photo.on.rectangle"
        case "msStory": return item.on ? "bookmark.slash" : "book"
        case "msTrace": return "eye"
        case "msReroll": return "arrow.clockwise"
        case "msDel": return "trash"
        default: return "circle"
        }
    }

    // MARK: placing

    private var menuHeight: CGFloat {
        let rows = stack.arrangedSubviews.filter { $0 is MenuRow }.count
        let head = stack.arrangedSubviews.count > rows ? Self.headHeight : 0
        return CGFloat(rows) * Self.rowHeight + head + 16
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(rect: bounds)
        for hole in holes { path.append(UIBezierPath(roundedRect: hole, cornerRadius: radius)) }
        dim.path = path.cgPath
        dim.frame = bounds

        let safe = safeAreaInsets
        let margin: CGFloat = 12, gap: CGFloat = 10
        let top = safe.top + margin, bottom = bounds.height - safe.bottom - margin
        let h = menuHeight, w = Self.width
        // Across: it grows from the finger. In the right half it hangs to the left of it, in the left half to the right.
        var x = finger.x > bounds.midX ? finger.x - w + 24 : finger.x - 24
        x = max(margin, min(x, bounds.width - w - margin))
        // Down: beside the bubble if there is room (below first, like ChatGPT), else at the finger.
        var y: CGFloat
        if bubble.maxY + gap + h <= bottom { y = bubble.maxY + gap }
        else if bubble.minY - gap - h >= top { y = bubble.minY - gap - h }
        else { y = finger.y + 8 + h <= bottom ? finger.y + 8 : finger.y - 8 - h }
        y = max(top, min(y, bottom - h))
        glass.frame = CGRect(x: x, y: y, width: w, height: h)
        stack.frame = glass.bounds
    }

    // MARK: in and out

    /// The card's scale animation is anchored on the finger, so it grows out of where the press was.
    private func setAnchorAtFinger() {
        let f = glass.frame
        let ax = min(1, max(0, (finger.x - f.minX) / f.width))
        let ay = min(1, max(0, (finger.y - f.minY) / f.height))
        glass.layer.anchorPoint = CGPoint(x: ax, y: ay)
        glass.layer.position = CGPoint(x: f.minX + ax * f.width, y: f.minY + ay * f.height)
    }

    private func appear() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        layoutIfNeeded()
        setAnchorAtFinger()
        dim.opacity = 0
        glass.alpha = 0
        glass.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
        dim.add(fade, forKey: "in")
        dim.opacity = 1
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0) {
            self.glass.alpha = 1
            self.glass.transform = .identity
        }
    }

    private func disappear(then: (() -> Void)? = nil) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.18
        dim.add(fade, forKey: "out")
        dim.opacity = 0
        UIView.animate(withDuration: 0.18, animations: {
            self.glass.alpha = 0
            self.glass.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            self.removeFromSuperview()
            then?()
        })
    }

    @objc private func outside(_ tap: UITapGestureRecognizer) {
        if glass.frame.contains(tap.location(in: self)) { return }
        disappear()
    }

    private func pick(_ id: String) {
        guard !picked else { return }
        picked = true
        disappear { self.onPick(id) }
    }
}

/// One row of the menu: a plain control that shades while pressed.
private final class MenuRow: UIControl {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.07) : .clear }
    }
}
