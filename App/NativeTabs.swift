import UIKit

/// The lake's bottom bar as a real UITabBar (2026/11/22, 宝宝 showed the App Store's bar: "想要appstore同款，
/// 手指在上面滑动的时候有这种效果"). Built with the iOS 26 SDK the system draws it in Liquid Glass, and the
/// lens that follows the finger across the tabs comes with it; nothing here imitates it.
///
/// The web still owns the four panes (index.html TabShell). The page's own bar stays in the layout but
/// hidden (html.native-bar, tabs.css), so the panes keep their bottom room. The bar shows only while a
/// tab is on screen; a page opened over the tabs covers it, as it covered the web bar.
final class NativeTabs: NSObject, UITabBarDelegate {
    static let keys = ["chat", "memory", "todo", "others"]
    let bar = UITabBar()
    /// A tab was tapped (key from `keys`).
    var onPick: ((String) -> Void)?

    override init() {
        super.init()
        let titles = ["Chat", "Memory", "To-do", "Others"]
        let symbols = ["bubble.left", "book", "checklist", "ellipsis"]
        bar.items = titles.indices.map { i in
            UITabBarItem(title: titles[i], image: UIImage(systemName: symbols[i]), tag: i)
        }
        bar.delegate = self
        bar.isHidden = true
        // The selected tab's pill, lighter than the system's (宝宝 11/22: "选中颜色再浅一点")
        let look = UITabBarAppearance()
        look.selectionIndicatorTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.045)
        }
        bar.standardAppearance = look
        bar.scrollEdgeAppearance = look
    }

    /// Shows the bar on `tab`, or hides it when tab is "" (the chat, or a page over everything).
    func show(_ tab: String) {
        guard let index = Self.keys.firstIndex(of: tab), tab != "chat" else { bar.isHidden = true; return }
        bar.selectedItem = bar.items?[index]
        bar.isHidden = false
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        onPick?(Self.keys[item.tag])
    }

    /// Bottom of the host, full width; the bar adds the home-indicator room itself.
    func layout(in bounds: CGRect) {
        let height = bar.sizeThatFits(bounds.size).height
        let transform = bar.transform
        bar.transform = .identity
        bar.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        bar.transform = transform
    }
}
