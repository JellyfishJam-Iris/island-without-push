import AVFAudio
import SwiftUI

@main
struct IslandDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    init() {
        Notices.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear { Notices.shared.requestOnce() }
        }
        .onChange(of: scenePhase) { phase in model.scene(phase) }
    }
}

/// Ties the three pieces together: standby (silent audio) keeps the process alive, the poller brings
/// answers, and each answer feeds the island and the local notifications.
@MainActor
final class AppModel: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "server.url"); restartPoll() }
    }
    @Published var standbyEnabled: Bool {
        didSet { UserDefaults.standard.set(standbyEnabled, forKey: "standby.enabled"); updateReception() }
    }
    @Published private(set) var pollStatus = "未开始"
    @Published private(set) var standbyStatus = ""
    @Published private(set) var islandStatus = "none"
    @Published private(set) var lastLine = ""
    @Published private(set) var lastMessage = ""
    @Published private(set) var log: [String] = []

    private let standby = Standby()
    private let poller = Poller()
    private var island: IslandController!
    private var scenePhase: ScenePhase = .inactive
    private var interrupted = false

    init() {
        // Saved addresses get the same first-word cleaning as baseURL, so the field shows what is used.
        let saved = UserDefaults.standard.string(forKey: "server.url") ?? ""
        serverURL = saved.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        standbyEnabled = UserDefaults.standard.object(forKey: "standby.enabled") as? Bool ?? true
        island = IslandController(inputs: { [weak self] in
            guard let self else { return (false, false) }
            return (self.standbyEnabled, self.standby.isPlaying)
        }, log: { [weak self] line in self?.note(line) })
        islandStatus = island.status
        standby.onExpiration = { [weak self] in self?.updateReception() }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                           queue: .main) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                if type == .began {
                    self.interrupted = true
                    self.event("audio interrupted")
                    self.updateReception()
                    self.rescueAudio()
                } else {
                    // Resume whether or not iOS says "shouldResume": the silence is ours to restart.
                    self.interrupted = false
                    self.event("interruption ended")
                    self.updateReception()
                }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                           queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.standby.forget()
                self.event("media reset")
                self.updateReception()
                if !self.standby.isPlaying { self.rescueAudio() }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                           queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scenePhase != .active, self.standbyEnabled,
                      !self.interrupted, !self.standby.isPlaying else { return }
                self.event("route change")
                self.updateReception()
                if !self.standby.isPlaying { self.rescueAudio() }
            }
        }
    }

    // MARK: keeping the silence alive

    /// The last thing that happened to the standby audio, sent to the server as X-Note.
    private var lastEvent = ""
    private var rescueTask: Task<Void, Never>?

    private func event(_ what: String) {
        lastEvent = what + " " + Self.clock.string(from: Date())
        note(what)
    }

    /// iOS does not promise an "interruption ended". Without the silence the App is suspended within
    /// seconds and never hears it, so the island went grey after every call or Siri. Instead: take a
    /// short grace period and try the audio again every 3 s for about 24 s. A short cut (Siri, another
    /// app's sound) heals by itself; a long call still drops, and comes back the next time she opens the App.
    private func rescueAudio() {
        guard standbyEnabled, scenePhase != .active else { return }
        standby.holdForRescue()
        rescueTask?.cancel()
        rescueTask = Task { @MainActor [weak self] in
            for attempt in 1...8 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.standby.isPlaying { break }
                self.interrupted = false
                self.updateReception()
                if self.standby.isPlaying { self.event("audio back after \(attempt * 3)s"); break }
                self.interrupted = true
            }
            guard let self, !Task.isCancelled else { return }
            if !self.standby.isPlaying { self.event("audio still blocked") }
            self.standby.releaseRescue()
            self.updateReception()
        }
    }

    /// Run on every poll answer or error: if the silence stopped without telling us, start it again.
    private func heal() {
        guard scenePhase != .active, standbyEnabled, !interrupted, !standby.isPlaying else { return }
        event("audio was off, restarting")
        updateReception()
    }

    func scene(_ phase: ScenePhase) {
        scenePhase = phase
        note("scene \(phase)")
        if phase == .active {
            // Back in the App, an interruption that never "ended" is over as far as we are concerned;
            // otherwise the flag stays stuck and standby never starts again until the App is killed.
            rescueTask?.cancel()
            rescueTask = nil
            standby.releaseRescue()
            interrupted = false
        }
        standby.setScenePhase(phase)
        if phase == .active { Notices.shared.clearBadge() }
        updateReception()
        island.setScene(phase)
        islandStatus = island.status
    }

    func preview(_ state: SpriteState) {
        island.showPreview(state.rawValue)
        islandStatus = island.status
    }

    /// The lake's front page: the island address minus its trailing /island.
    var lakeURL: URL? {
        guard let base = baseURL else { return nil }
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/island") { text.removeLast("/island".count) }
        return URL(string: text + "/")
    }

    private var baseURL: URL? {
        // Only the first word: a pasted address once came with " has" stuck on the end, iOS quietly
        // encoded it as /island%20has, and every poll for a day was a 404 (the grey island of 11/21).
        let first = serverURL.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard let url = URL(string: first),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    private func restartPoll() {
        poller.stop()
        updateReception()
    }

    /// The one place that decides what runs: the silent audio, the poll, and the status words.
    private func updateReception() {
        if standby.state.shouldPlay(enabled: standbyEnabled, blocked: interrupted) {
            do { try standby.start() } catch { standbyStatus = "待机音频暂不可用，后台接收可能暂停" }
        } else {
            standby.stop()
        }
        let canPoll = standby.state.canPoll(lease: standby.hasLease || standby.hasRescue, audio: standby.isPlaying)
        if interrupted { standbyStatus = "声音被系统占用，待机已暂停" }
        else if standby.isPlaying { standbyStatus = "后台待机已开启" }
        else if scenePhase == .background { standbyStatus = canPoll ? "短时后台接收中" : "后台接收已暂停" }
        else if !standbyEnabled { standbyStatus = "待机已关闭，只在前台接收" }
        else { standbyStatus = "前台直接接收；离开 App 时自动开启待机" }

        guard canPoll, let base = baseURL else {
            poller.stop()
            pollStatus = baseURL == nil ? "服务器地址不对" : "已暂停"
            return
        }
        guard !poller.isRunning else { return }
        pollStatus = "连接中"
        poller.start(base: base, presence: { [weak self] in
            guard let self else { return (true, false, "") }
            return (self.scenePhase != .active, self.standby.isPlaying, self.lastEvent)
        }, onAnswer: { [weak self] response in
            self?.answered(response)
            self?.heal()
        }, onError: { [weak self] message in
            self?.pollStatus = "出错：\(message)"
            self?.heal()
        })
    }

    private func answered(_ response: PollResponse) {
        pollStatus = "已连接 " + Self.clock.string(from: Date())
        island.serverUpdate(response.island)
        islandStatus = island.status
        if let line = response.island?.line, !line.isEmpty { lastLine = line }
        let fresh = Notices.shared.handle(messages: response.messages, foreground: scenePhase == .active)
        if let last = fresh.last { lastMessage = last.text }
    }

    private func note(_ line: String) {
        log.append(Self.clock.string(from: Date()) + " " + line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// The lake fills the screen; Clawd's own page (server, standby, island, log) is a sheet the lake opens
/// with `postMessage({cmd: "clawd"})`. Until there is an address, Clawd's page is all there is.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var lakeOpen: Bool
    @State private var showClawd = false
    @State private var reloadToken = 0

    init(model: AppModel) {
        self.model = model
        // Decided once, so typing an address in the field below does not swap the screen mid-word.
        _lakeOpen = State(initialValue: model.lakeURL != nil)
    }

    var body: some View {
        Group {
            if lakeOpen, let lake = model.lakeURL {
                LakeView(url: lake, reloadToken: reloadToken) { command in
                    // "unreachable": the lake page itself did not load, so its menu row is out of reach too.
                    if command == "clawd" || command == "unreachable" { showClawd = true }
                }
                .ignoresSafeArea()
            } else {
                ContentView(model: model, openLake: model.lakeURL == nil ? nil : { lakeOpen = true })
            }
        }
        .sheet(isPresented: $showClawd) {
            ContentView(model: model, reloadLake: {
                reloadToken += 1
                showClawd = false
            })
        }
        // A tapped notification goes to the lake: Clawd's page steps aside, the lake opens if it was not.
        .onReceive(NotificationCenter.default.publisher(for: Notices.landing)) { _ in
            showClawd = false
            if model.lakeURL != nil { lakeOpen = true }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var openLake: (() -> Void)? = nil
    var reloadLake: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                if openLake != nil || reloadLake != nil {
                    Section("湖") {
                        if let openLake { Button("打开湖", action: openLake) }
                        if let reloadLake { Button("重新载入湖", action: reloadLake) }
                        Text("湖的地址就是下面服务器地址去掉结尾的 /island。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("服务器") {
                    TextField("https://湖的地址/island", text: $model.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("App 会一直对 /status?wait=20 发长轮询。server/demo_server.py 就是一个最小的例子。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("后台") {
                    Toggle("离开 App 后保持待机", isOn: $model.standbyEnabled)
                    LabeledContent("待机", value: model.standbyStatus)
                    LabeledContent("轮询", value: model.pollStatus)
                }
                Section("岛") {
                    LabeledContent("状态", value: model.islandStatus)
                    LabeledContent("这一句", value: model.lastLine)
                    HStack {
                        ForEach(SpriteState.allCases, id: \.self) { state in
                            Button(state.rawValue) { model.preview(state) }.buttonStyle(.bordered)
                        }
                    }
                    Text("点一个预览，然后上滑回桌面：岛只在 App 外面显示，10 秒后恢复服务器给的状态。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("通知") {
                    LabeledContent("最近一条", value: model.lastMessage)
                    Text("App 在后台时，服务器 /say 的新消息会变成本地通知；App 打开时不弹。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("记录") {
                    ForEach(Array(model.log.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Island without push")
        }
    }
}
