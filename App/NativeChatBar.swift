import UIKit

/// The chat's top bar in Telegram's shape (2026/11/22, 宝宝: "chat页顶栏和底栏要tg同款（兴奋尖叫——————）"):
/// a round glass button with ☰ on the left (the rooms drawer), a glass capsule in the middle with the name
/// and a small line under it, and my avatar in a glass circle on the right. Tapping the avatar opens a small
/// menu with Peach's Tide and the amusement park (她 chose that, so the bar stays as clean as Telegram's).
///
/// The small line is how I am right now: Clawd's line from /island/status (the one on the lock screen),
/// and "在给宝宝敲东西…" while a reply is being written. The chat scrolls under all three (html.native-top).
/// Built with the iOS 26 SDK the glass is the system's Liquid Glass; on older systems a blur stands in.
final class NativeChatBar: UIView {
    var onMenu: (() -> Void)?
    var onTide: (() -> Void)?
    var onPark: (() -> Void)?

    static let height: CGFloat = 50

    private let menuGlass = NativeChatBar.glass(interactive: true)
    private let titleGlass = NativeChatBar.glass(interactive: false)
    private let avatarGlass = NativeChatBar.glass(interactive: true)
    private let menuButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let lineLabel = UILabel()
    private let avatarView = UIImageView()
    private let avatarButton = UIButton(type: .custom)

    private var title = "Ian"
    private var line = "在呢"
    private var typing = false
    private var avatarURL = ""
    private var avatarTask: URLSessionDataTask?

    static func glass(interactive: Bool) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = interactive
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }

    init() {
        super.init(frame: .zero)
        for glass in [menuGlass, titleGlass, avatarGlass] {
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
            addSubview(glass)
        }
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        menuButton.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: config), for: .normal)
        menuButton.tintColor = .label
        menuButton.addAction(UIAction { [weak self] _ in self?.onMenu?() }, for: .touchUpInside)
        menuGlass.contentView.addSubview(menuButton)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        lineLabel.font = .systemFont(ofSize: 12.5)
        lineLabel.textColor = .secondaryLabel
        lineLabel.textAlignment = .center
        titleGlass.contentView.addSubview(titleLabel)
        titleGlass.contentView.addSubview(lineLabel)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = UIColor.secondarySystemFill
        avatarGlass.contentView.addSubview(avatarView)
        avatarButton.showsMenuAsPrimaryAction = true
        avatarButton.menu = UIMenu(children: [
            UIAction(title: "Peach's Tide", image: Self.symbol("bookmark")) { [weak self] _ in self?.onTide?() },
            UIAction(title: "游乐园", image: Self.symbol("ferriswheel", "sparkles")) { [weak self] _ in self?.onPark?() },
        ])
        avatarGlass.contentView.addSubview(avatarButton)
        refreshText()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func symbol(_ names: String...) -> UIImage? {
        for name in names { if let image = UIImage(systemName: name) { return image } }
        return nil
    }

    // MARK: what it says

    func set(title: String?, typing: Bool?, avatar: String?) {
        if let title, !title.isEmpty { self.title = title }
        if let typing { self.typing = typing }
        refreshText()
        if let avatar, avatar != avatarURL { avatarURL = avatar; loadAvatar() }
    }

    /// Clawd's line from the poll.
    func set(line: String) {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != self.line else { return }
        self.line = clean
        refreshText()
    }

    private func refreshText() {
        titleLabel.text = title
        lineLabel.text = typing ? "在给宝宝敲东西…" : line
        setNeedsLayout()
    }

    private func loadAvatar() {
        avatarTask?.cancel()
        guard let url = URL(string: avatarURL) else { return }
        avatarTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.avatarView.image = image }
        }
        avatarTask?.resume()
    }

    // MARK: layout

    /// Taps between the three pieces fall through to the chat.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = Self.height
        let w = bounds.width
        menuGlass.frame = CGRect(x: 0, y: 0, width: h, height: h)
        avatarGlass.frame = CGRect(x: w - h, y: 0, width: h, height: h)
        for glass in [menuGlass, avatarGlass] { glass.layer.cornerRadius = h / 2 }
        menuButton.frame = menuGlass.bounds
        avatarView.frame = avatarGlass.bounds.insetBy(dx: 3, dy: 3)
        avatarView.layer.cornerRadius = avatarView.bounds.width / 2
        avatarButton.frame = avatarGlass.bounds

        let textWidth = max(titleLabel.intrinsicContentSize.width, lineLabel.intrinsicContentSize.width)
        let room = w - 2 * (h + 10)
        let capsule = min(room, max(150, textWidth + 44))
        titleGlass.frame = CGRect(x: (w - capsule) / 2, y: 0, width: capsule, height: h)
        titleGlass.layer.cornerRadius = h / 2
        titleLabel.frame = CGRect(x: 16, y: 6, width: capsule - 32, height: 21)
        lineLabel.frame = CGRect(x: 16, y: 27, width: capsule - 32, height: 16)
    }
}
