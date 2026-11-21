import PhotosUI
import UIKit

/// The chat's input bar in Telegram's shape (2026/11/22, 宝宝: "TG的同款键盘和镂空按钮！！！馋了几个月了"):
/// a glass circle with a paperclip, a glass capsule with the text and a little face that opens the kaomoji
/// drawer, and a glass circle that is the microphone (hold to talk), the send arrow or the stop square.
///
/// It rides on the keyboard while the lake stays full height underneath, so the chat shows through the
/// keyboard's glass ("镂空"). The web's hidden #input stays the real one (index.html NativeComposer): every
/// change here is copied there, and every change there (cleared after sending, a room's draft, a kaomoji
/// put in) comes back here. Sending, stopping, recording and the drawer are the web's own functions.
final class NativeComposer: UIView, UITextViewDelegate, PHPickerViewControllerDelegate {
    /// Runs JavaScript in the lake: (body, arguments, completion with the returned value).
    var js: ((String, [String: Any], ((Any?) -> Void)?) -> Void)?
    /// The text view grew or shrank: the host lays the bar out again.
    var onResize: (() -> Void)?
    /// The text view got or lost the keyboard: the host decides who moves for the keyboard.
    var onEditing: ((Bool) -> Void)?
    var uploadURL: URL?

    let textView = UITextView()
    private let attachGlass = NativeChatBar.glass(interactive: true)
    private let capsuleGlass = NativeChatBar.glass(interactive: false)
    private let actionGlass = NativeChatBar.glass(interactive: true)
    private let attachButton = UIButton(type: .system)
    private let actionButton = UIButton(type: .system)
    private let faceButton = UIButton(type: .system)
    private let placeholder = UILabel()
    private let recordView = UIView()
    private let recordDot = UIView()
    private let recordTime = UILabel()
    private let recordHint = UILabel()

    private var mode = "mic"
    private var tone = UIColor(red: 0.62, green: 0.52, blue: 0.86, alpha: 1)
    private(set) var drawerOpen = false
    private var recording = false
    private var recordStart = Date()
    private var recordTimer: Timer?
    private var pressX: CGFloat = 0
    private var uploading = 0

    static let circle: CGFloat = 46
    private static let font = UIFont.systemFont(ofSize: 17)

    init() {
        super.init(frame: .zero)
        for glass in [attachGlass, capsuleGlass, actionGlass] {
            if #available(iOS 26.0, *) { glass.cornerConfiguration = .capsule() } else { glass.clipsToBounds = true }
            addSubview(glass)
        }
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        attachButton.setImage(UIImage(systemName: "paperclip", withConfiguration: symbol), for: .normal)
        attachButton.tintColor = .label
        attachButton.addAction(UIAction { [weak self] _ in self?.pickImages() }, for: .touchUpInside)
        attachGlass.contentView.addSubview(attachButton)

        textView.font = Self.font
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 4)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.returnKeyType = .default
        capsuleGlass.contentView.addSubview(textView)
        placeholder.text = "说点什么…"
        placeholder.font = Self.font
        placeholder.textColor = .placeholderText
        capsuleGlass.contentView.addSubview(placeholder)
        faceButton.setImage(UIImage(systemName: "face.smiling", withConfiguration: symbol), for: .normal)
        faceButton.tintColor = .secondaryLabel
        faceButton.addAction(UIAction { [weak self] _ in self?.toggleKaomoji() }, for: .touchUpInside)
        capsuleGlass.contentView.addSubview(faceButton)

        recordView.isHidden = true
        recordView.isUserInteractionEnabled = false
        recordDot.backgroundColor = .systemRed
        recordDot.layer.cornerRadius = 4.5
        recordTime.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        recordTime.textColor = .label
        recordHint.font = .systemFont(ofSize: 15)
        recordHint.textColor = .secondaryLabel
        recordHint.textAlignment = .right
        [recordDot, recordTime, recordHint].forEach(recordView.addSubview)
        capsuleGlass.contentView.addSubview(recordView)

        actionButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.18
        actionButton.addGestureRecognizer(hold)
        actionGlass.contentView.addSubview(actionButton)
        paintAction()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: size

    /// The bar's height for the current text: one line is a circle tall, it grows up to about six lines.
    var barHeight: CGFloat {
        let width = max(80, capsuleWidth - 40)
        let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return min(max(Self.circle, fit), 150)
    }

    private var capsuleWidth: CGFloat { bounds.width - 2 * (Self.circle + 8) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let c = Self.circle
        let h = bounds.height
        attachGlass.frame = CGRect(x: 0, y: h - c, width: c, height: c)
        actionGlass.frame = CGRect(x: bounds.width - c, y: h - c, width: c, height: c)
        capsuleGlass.frame = CGRect(x: c + 8, y: 0, width: capsuleWidth, height: h)
        if #unavailable(iOS 26.0) {
            attachGlass.layer.cornerRadius = c / 2
            actionGlass.layer.cornerRadius = c / 2
            capsuleGlass.layer.cornerRadius = min(c / 2, h / 2)
        }
        attachButton.frame = attachGlass.bounds
        actionButton.frame = actionGlass.bounds
        let w = capsuleGlass.bounds.width
        textView.frame = CGRect(x: 8, y: 0, width: w - 44, height: h)
        textView.isScrollEnabled = textView.sizeThatFits(CGSize(width: w - 44, height: .greatestFiniteMagnitude)).height > 150
        placeholder.frame = CGRect(x: 19, y: h - c, width: w - 60, height: c)
        faceButton.frame = CGRect(x: w - 42, y: h - c, width: 40, height: c)
        recordView.frame = CGRect(x: 0, y: h - c, width: w, height: c)
        recordDot.frame = CGRect(x: 18, y: c / 2 - 4.5, width: 9, height: 9)
        recordTime.frame = CGRect(x: 36, y: 0, width: 60, height: c)
        recordHint.frame = CGRect(x: 96, y: 0, width: w - 112, height: c)
    }

    // MARK: from the web

    func set(text: String) {
        guard text != textView.text else { return }
        textView.text = text
        textChanged(tellWeb: false)
    }

    func set(mode: String) {
        guard mode != self.mode else { return }
        self.mode = mode
        UIView.transition(with: actionButton, duration: 0.18, options: .transitionCrossDissolve) { self.paintAction() }
    }

    func set(tone: String) {
        if let color = Self.color(hex: tone) { self.tone = color; paintAction() }
    }

    func set(drawerOpen: Bool) {
        self.drawerOpen = drawerOpen
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        faceButton.setImage(UIImage(systemName: drawerOpen ? "keyboard" : "face.smiling", withConfiguration: symbol), for: .normal)
    }

    private func paintAction() {
        let symbol = UIImage.SymbolConfiguration(pointSize: mode == "send" ? 18 : 20, weight: mode == "send" ? .bold : .regular)
        switch mode {
        case "send":
            actionButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: symbol), for: .normal)
            actionButton.tintColor = .white
            actionButton.backgroundColor = tone
        case "stop":
            actionButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: symbol), for: .normal)
            actionButton.tintColor = tone
            actionButton.backgroundColor = .clear
        default:
            actionButton.setImage(UIImage(systemName: "mic", withConfiguration: symbol), for: .normal)
            actionButton.tintColor = .label
            actionButton.backgroundColor = .clear
        }
        actionButton.layer.cornerRadius = (Self.circle - 6) / 2
        actionButton.frame = actionGlass.bounds
        if mode == "send" { actionButton.frame = actionGlass.bounds.insetBy(dx: 3, dy: 3) }
    }

    // MARK: typing

    func textViewDidChange(_ textView: UITextView) { textChanged(tellWeb: true) }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if drawerOpen { js?("window.NativeComposer && window.NativeComposer.closeKaomoji()", [:], nil) }
        onEditing?(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) { onEditing?(false) }

    private func textChanged(tellWeb: Bool) {
        placeholder.isHidden = !textView.text.isEmpty
        if tellWeb {
            let range = textView.selectedRange
            js?("window.NativeComposer && window.NativeComposer.set(t, s, e)",
                ["t": textView.text ?? "", "s": range.location, "e": range.location + range.length], nil)
        }
        onResize?()
    }

    private func toggleKaomoji() {
        if drawerOpen {
            textView.becomeFirstResponder()       // the face became a keyboard: back to typing
            return
        }
        let range = textView.selectedRange
        textView.resignFirstResponder()
        js?("window.NativeComposer && window.NativeComposer.kaomoji(s, e)",
            ["s": range.location, "e": range.location + range.length], nil)
    }

    private func actionTapped() {
        guard mode != "mic" else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        js?("window.NativeComposer && window.NativeComposer.tap()", [:], nil)
    }

    // MARK: hold to talk

    @objc private func hold(_ press: UILongPressGestureRecognizer) {
        guard mode == "mic" || recording else { return }
        let x = press.location(in: self).x
        switch press.state {
        case .began:
            pressX = x
            js?("return window.NativeComposer ? window.NativeComposer.recStart() : false", [:]) { [weak self] ok in
                guard let self, (ok as? Bool) == true, press.state == .began || press.state == .changed else { return }
                self.startRecordingLook()
            }
        case .changed:
            guard recording else { return }
            js?("return window.NativeComposer ? window.NativeComposer.recMove(dx) : false", ["dx": x - pressX]) { [weak self] armed in
                self?.armed((armed as? Bool) == true)
            }
        case .ended, .cancelled, .failed:
            let cancel = press.state != .ended
            js?("window.NativeComposer && window.NativeComposer.recEnd(c)", ["c": cancel], nil)
            stopRecordingLook()
        default:
            break
        }
    }

    private func startRecordingLook() {
        recording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recordStart = Date()
        recordTime.text = "0:00"
        armed(false)
        recordView.isHidden = false
        textView.isHidden = true
        placeholder.isHidden = true
        faceButton.isHidden = true
        recordDot.alpha = 1
        UIView.animate(withDuration: 0.6, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
            self.recordDot.alpha = 0.2
        }
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Int(Date().timeIntervalSince(self.recordStart))
            self.recordTime.text = String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    private func armed(_ on: Bool) {
        recordHint.text = on ? "松开取消" : "‹ 左滑取消"
        recordHint.textColor = on ? .systemRed : .secondaryLabel
    }

    private func stopRecordingLook() {
        guard recording else { return }
        recording = false
        recordTimer?.invalidate()
        recordTimer = nil
        recordDot.layer.removeAllAnimations()
        recordView.isHidden = true
        textView.isHidden = false
        faceButton.isHidden = false
        placeholder.isHidden = !textView.text.isEmpty
    }

    // MARK: pictures

    private func pickImages() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 9
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty, let uploadURL else { return }
        var names = [String?](repeating: nil, count: results.count)
        let group = DispatchGroup()
        uploading += 1
        attachButton.alpha = 0.3
        for (i, result) in results.enumerated() where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage, let data = Self.jpeg(image) else { group.leave(); return }
                Self.upload(data, to: uploadURL) { name in names[i] = name; group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.uploading -= 1
            if self.uploading == 0 { self.attachButton.alpha = 1 }
            let got = names.compactMap { $0 }
            if !got.isEmpty { self.js?("window.NativeComposer && window.NativeComposer.addImages(n)", ["n": got], nil) }
        }
    }

    /// Longest side at most 2560 px, JPEG: the lake takes up to 10 MB and HEIC is not on its list.
    private static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 2560 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return drawn.jpegData(compressionQuality: 0.88)
    }

    private static func upload(_ data: Data, to url: URL, done: @escaping (String?) -> Void) {
        let boundary = "lelac-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done((json?["ok"] as? Bool) == true ? json?["filename"] as? String : nil)
        }.resume()
    }

    private static func color(hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
