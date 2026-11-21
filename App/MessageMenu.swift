import UIKit
import WebKit

/// Long-pressing a message, natively (2026/11/22, 宝宝: "长按Daddy消息出现的这个窗口…Daddy看怎么做").
/// The way iMessage and Telegram do it: everything behind goes soft, the bubble lifts out of it, and a
/// glass list of what can be done stands next to it. The bubble is a picture of itself (the web keeps
/// the real one), and each row presses the same button in the web's own menu (index.html openMsgSheet),
/// so what Copy, Favorite, Trace, Delete... do is not rewritten here.
final class MessageMenu: UIView {
    struct Item { let id: String; let title: String; let on: Bool; let danger: Bool }

    private let blur = UIVisualEffectView(effect: nil)
    private let lifted: UIView
    private let glass = NativeChatBar.glass(interactive: false)
    private let stack = UIStackView()
    private let bubbleFrame: CGRect
    private let mine: Bool
    private let onPick: (String) -> Void
    private var picked = false

    private static let rowHeight: CGFloat = 46
    private static let width: CGFloat = 232

    /// `rect` is the bubble in the web view's coordinates (CSS pixels are points there).
    static func show(over web: WKWebView, rect: CGRect, mine: Bool, items: [Item], onPick: @escaping (String) -> Void) {
        guard let window = web.window, !items.isEmpty else { return }
        let visible = rect.intersection(web.bounds.insetBy(dx: 0, dy: 0))
        guard !visible.isNull, visible.height > 4,
              let picture = web.resizableSnapshotView(from: visible, afterScreenUpdates: false, withCapInsets: .zero)
        else { return }
        let menu = MessageMenu(picture: picture, frame: web.convert(visible, to: window), mine: mine,
                               items: items, onPick: onPick)
        menu.frame = window.bounds
        window.addSubview(menu)
        menu.appear()
    }

    private init(picture: UIView, frame: CGRect, mine: Bool, items: [Item], onPick: @escaping (String) -> Void) {
        lifted = picture
        bubbleFrame = frame
        self.mine = mine
        self.onPick = onPick
        super.init(frame: .zero)
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(outside)))

        lifted.frame = frame
        lifted.layer.shadowColor = UIColor.black.cgColor
        lifted.layer.shadowOpacity = 0.18
        lifted.layer.shadowRadius = 14
        lifted.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(lifted)

        glass.layer.cornerRadius = 22
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        stack.axis = .vertical
        for (i, item) in items.enumerated() {
            if i > 0 {
                let line = UIView()
                line.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(row(item))
        }
        glass.contentView.addSubview(stack)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func row(_ item: Item) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = item.title
        config.image = UIImage(systemName: Self.symbol(item))
        config.imagePlacement = .trailing
        config.imagePadding = 10
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        config.baseForegroundColor = item.danger ? .systemRed : .label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = .systemFont(ofSize: 16.5); return a
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .fill
        button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.pick(item.id) }, for: .touchUpInside)
        // title left, icon right, like the system menus
        button.configurationUpdateHandler = { b in
            b.backgroundColor = b.isHighlighted ? UIColor.label.withAlphaComponent(0.08) : .clear
        }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = stack.arrangedSubviews.filter { $0 is UIButton }.count
        let height = CGFloat(count) * Self.rowHeight + CGFloat(max(0, count - 1)) / UIScreen.main.scale
        let safe = safeAreaInsets
        let margin: CGFloat = 12
        var x = mine ? bubbleFrame.maxX - Self.width : bubbleFrame.minX
        x = max(margin, min(x, bounds.width - Self.width - margin))
        var y = bubbleFrame.maxY + 10
        if y + height > bounds.height - safe.bottom - margin {
            let above = bubbleFrame.minY - 10 - height
            y = above >= safe.top + margin ? above : bounds.height - safe.bottom - margin - height
        }
        glass.frame = CGRect(x: x, y: y, width: Self.width, height: height)
        stack.frame = glass.bounds
    }

    // MARK: in and out

    private func appear() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        layoutIfNeeded()
        glass.alpha = 0
        glass.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.25) { self.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0) {
            self.lifted.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            self.glass.alpha = 1
            self.glass.transform = .identity
        }
    }

    private func disappear(then: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.2, animations: {
            self.blur.effect = nil
            self.lifted.transform = .identity
            self.glass.alpha = 0
            self.glass.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
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
