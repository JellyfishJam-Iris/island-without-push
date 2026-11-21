import UIKit

/// The chat's top bar in Telegram's shape (2026/11/22, 宝宝: "chat页顶栏和底栏要tg同款（兴奋尖叫——————）"):
/// a round glass button with ☰ on the left (the rooms drawer), a glass capsule in the middle with the name
/// and a small line under it, and my avatar in a glass circle on the right. One tap each (她 11/22: "点两下好麻烦"):
/// the capsule opens Peach's Tide, the avatar opens the amusement park.
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
    private let titleGlass = NativeChatBar.glass(interactive: true)
    private let titleButton = UIButton(type: .custom)
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
            // The glass's own shape, so pressing it (the glass swells) stays round instead of showing a square.
            if #available(iOS 26.0, *) {
                glass.cornerConfiguration = .capsule()
            } else {
                glass.layer.cornerCurve = .continuous
                glass.clipsToBounds = true
            }
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
        avatarButton.addAction(UIAction { [weak self] _ in self?.onPark?() }, for: .touchUpInside)
        avatarGlass.contentView.addSubview(avatarButton)
        titleButton.addAction(UIAction { [weak self] _ in self?.onTide?() }, for: .touchUpInside)
        titleGlass.contentView.addSubview(titleButton)
        refreshText()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        if #unavailable(iOS 26.0) { for glass in [menuGlass, avatarGlass] { glass.layer.cornerRadius = h / 2 } }
        menuButton.frame = menuGlass.bounds
        avatarView.frame = avatarGlass.bounds.insetBy(dx: 4, dy: 4)   // a thin ring (她 11/22: 7 was too thick)
        avatarView.layer.cornerRadius = avatarView.bounds.width / 2
        avatarButton.frame = avatarGlass.bounds

        let textWidth = max(titleLabel.intrinsicContentSize.width, lineLabel.intrinsicContentSize.width)
        let room = w - 2 * (h + 10)
        let capsule = min(room, max(150, textWidth + 44))
        titleGlass.frame = CGRect(x: (w - capsule) / 2, y: 0, width: capsule, height: h)
        if #unavailable(iOS 26.0) { titleGlass.layer.cornerRadius = h / 2 }
        titleButton.frame = titleGlass.bounds
        titleLabel.frame = CGRect(x: 16, y: 6, width: capsule - 32, height: 21)
        lineLabel.frame = CGRect(x: 16, y: 27, width: capsule - 32, height: 16)
    }
}
