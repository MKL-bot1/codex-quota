import AppKit
import SwiftUI
import ServiceManagement
import Security
import Darwin

struct QuotaWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Int { Int(max(0, min(100, 100-usedPercent)).rounded()) }
    var title: String {
        switch windowDurationMins {
        case 300: return "5 小时额度"
        case 10080: return "每周额度"
        case let n?: return n >= 60 && n % 60 == 0 ? "\(n/60) 小时额度" : "\(n) 分钟额度"
        default: return "额度"
        }
    }
}
struct Bucket: Codable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let planType: String?
    var windows: [QuotaWindow] { [primary,secondary].compactMap{$0} }
    var name: String { limitName ?? (limitId == "codex" ? "Codex" : limitId ?? "Codex") }
}
struct Snapshot: Codable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String:Bucket]?
    var buckets: [Bucket] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.keys.sorted { a,b in a == "codex" ? b != "codex" : b == "codex" ? false : a < b }.compactMap{map[$0]}
        }
        return [rateLimits].compactMap{$0}
    }
    var main: Bucket? { buckets.first(where:{$0.limitId == "codex"}) ?? ((rateLimits?.limitId == nil || rateLimits?.limitId == "codex") ? rateLimits : nil) }
}
// No quota or identity is persisted by this app.
enum CodexInstallation {
    static let teamID = "2DC432GLL2" // OpenAI's signed macOS application.
    static let appPaths = ["/Applications/Codex.app", "/Applications/ChatGPT.app",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app").path]
    static func trustedApp() -> URL? {
        for path in appPaths {
            let url = URL(fileURLWithPath:path)
            guard Bundle(url:url)?.bundleIdentifier == "com.openai.codex" else { continue }
            let executable = url.appendingPathComponent("Contents/Resources/codex")
            guard FileManager.default.isExecutableFile(atPath:executable.path) else { continue }
            var appCode: SecStaticCode?, binaryCode: SecStaticCode?, requirement: SecRequirement?
            let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCreateWithPath(url as CFURL, [], &appCode) == errSecSuccess,
                  SecStaticCodeCreateWithPath(executable as CFURL, [], &binaryCode) == errSecSuccess,
                  let appCode, let binaryCode, let requirement,
                  SecStaticCodeCheckValidity(appCode, [], requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(binaryCode, [], requirement) == errSecSuccess else { continue }
            return url
        }
        return nil
    }
    static func environment() -> [String:String] {
        let source = ProcessInfo.processInfo.environment
        // Exclude API keys, injected libraries, custom endpoints and arbitrary shell state.
        var clean = ["HOME":FileManager.default.homeDirectoryForCurrentUser.path,
                     "PATH":"/usr/bin:/bin:/usr/sbin:/sbin",
                     "TMPDIR":NSTemporaryDirectory()]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = source[key] { clean[key] = value }
        }
        return clean
    }
}

final class QuotaStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var refreshing = false
    @Published var autoStart = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?
    var process: Process?
    var input: Pipe?
    var output: Pipe?
    var buffer = Data()
    var ready = false
    var generation = UUID()
    var nextID = 1
    var pendingID: Int?
    var timeout: DispatchWorkItem?
    var timer: Timer?
    var stale: Bool { error != nil || updatedAt == nil || Date().timeIntervalSince(updatedAt!) > 150 }
    var remaining: Int? { snapshot?.main?.windows.map(\.remaining).min() }
    var statusTitle: String {
        guard let value = remaining else { return "Codex —" }
        return "Codex \(value)%" + (stale ? " · !" : "")
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.refresh() }
    }
    func stop() {
        timer?.invalidate(); timeout?.cancel(); generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; ready = false; pendingID = nil
    }
    func disconnect() {
        timeout?.cancel(); generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; ready = false; pendingID = nil
    }
    func fail(_ message: String) {
        disconnect(); refreshing = false; error = message; onChange?()
    }
    func refresh() {
        if refreshing { return }
        refreshing = true; onChange?()
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.fail("连接超时，将自动重试") }
        timeout = task; DispatchQueue.main.asyncAfter(deadline:.now()+30,execute:task)
        if ready { requestQuota(); return }
        guard let appURL = CodexInstallation.trustedApp() else {
            fail("未找到有效签名的 Codex，请安装官方 App 并登录"); return
        }
        let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.executableURL = appURL.appendingPathComponent("Contents/Resources/codex")
        p.arguments = ["app-server", "--stdio", "-c", "analytics.enabled=false"]
        // Avoid running inside a project whose local configuration could change startup.
        p.currentDirectoryURL = URL(fileURLWithPath:"/")
        p.environment = CodexInstallation.environment()
        p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = FileHandle.nullDevice
        process = p; input = stdinPipe; output = stdoutPipe; buffer = Data()
        let token = generation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail("Codex 连接已断开，将自动重试") }
                else { self.receive(data) }
            }
        }
        do {
            try p.run()
            send(["method":"initialize","id":0,"params":["clientInfo":["name":"codex_quota_local","title":"Codex Quota","version":"1.1.0"]]])
        } catch { fail("无法启动 Codex 连接，请检查安装") }
    }
    func send(_ obj: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:obj) else { return }
        do { try input?.fileHandleForWriting.write(contentsOf:data+Data([10])) }
        catch { fail("无法发送额度查询，将自动重试") }
    }
    func requestQuota() {
        nextID += 1; pendingID = nextID
        send(["method":"account/rateLimits/read","id":nextID])
    }
    func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 4_000_000 { fail("连接响应异常，将自动重试"); return }
        while let newline = buffer.firstIndex(of:10) {
            let line = buffer.subdata(in:0..<newline); buffer.removeSubrange(0...newline)
            guard let obj = (try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else { continue }
            let id = obj["id"] as? Int
            if id == 0 {
                guard obj["result"] != nil else { fail("Codex 初始化失败，请重新登录后刷新"); return }
                ready = true; send(["method":"initialized","params":[:]]); requestQuota()
            } else if id != nil && id == pendingID {
                if obj["error"] != nil { fail("无法读取额度，请确认 Codex 已登录并检查网络"); return }
                guard let result = obj["result"] as? [String:Any], let payload = try? JSONSerialization.data(withJSONObject:result), let snapshot = try? JSONDecoder().decode(Snapshot.self,from:payload) else {
                    fail("额度数据格式发生变化，请更新小工具"); return
                }
                accept(snapshot)
            } else if obj["method"] as? String == "account/updated" {
                snapshot = nil; updatedAt = nil
                fail("账号状态已变化，请刷新重新连接")
                return
            } else if obj["method"] as? String == "account/rateLimits/updated", !refreshing {
                // Notifications may be partial: fetch a full snapshot before replacing existing buckets.
                refresh()
            }
        }
    }
    func accept(_ value: Snapshot) {
        timeout?.cancel(); pendingID = nil; refreshing = false
        snapshot = value; updatedAt = Date(); error = nil
        onChange?()
    }
    func toggleAutoStart() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            autoStart = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "未能设置登录启动"; alert.informativeText = "请在系统设置 → 通用 → 登录项中添加 Codex Quota。"; alert.runModal()
        }
    }
}

struct WindowRow: View {
    let window: QuotaWindow
    var tint: Color { window.remaining <= 10 ? .orange : window.remaining <= 25 ? .yellow : Color(red:0.12,green:0.67,blue:0.53) }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(window.title).font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Text("剩余 \(window.remaining)%").font(.system(size:14,weight:.semibold,design:.rounded)).foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment:.leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(tint).frame(width:geo.size.width*CGFloat(window.remaining)/100)
                }
            }.frame(height:5)
            if let reset = window.resetsAt {
                let date = Date(timeIntervalSince1970:reset)
                HStack(spacing:3) {
                    Image(systemName:"arrow.clockwise").font(.system(size:9))
                    if date > Date() { Text(date,style:.relative); Text("后重置") }
                    else { Text("等待服务器更新") }
                    Spacer()
                    Text(date,format:.dateTime.month().day().hour().minute())
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
    }
}
struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    let pinned: Bool
    let pinAction: ()->Void
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:10) {
                Image(nsImage:NSImage(named:"BrandMark") ?? NSImage()).resizable().frame(width:32,height:32).accessibilityLabel("Codex 额度标志")
                VStack(alignment:.leading,spacing:3) {
                    Text("Codex 额度").font(.system(size:18,weight:.semibold))
                    Text("\(store.snapshot?.main?.planType?.uppercased() ?? "ACCOUNT") · 本机登录账号").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action:pinAction) { Image(systemName:pinned ? "pin.slash" : "pin") }.buttonStyle(.plain).help(pinned ? "关闭桌面面板" : "固定到桌面")
            }
            if let snapshot = store.snapshot, !snapshot.buckets.isEmpty {
                ScrollView {
                    VStack(spacing:12) {
                        ForEach(Array(snapshot.buckets.enumerated()),id:\.offset) { _,bucket in
                            VStack(alignment:.leading,spacing:14) {
                                Text(bucket.name).font(.system(size:12,weight:.semibold))
                                ForEach(Array(bucket.windows.enumerated()),id:\.offset) { _,window in WindowRow(window:window) }
                                if bucket.windows.isEmpty { Text("服务器未提供额度窗口").font(.caption).foregroundStyle(.secondary) }
                            }.padding(14).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:13))
                        }
                    }
                }.frame(height:320)
            } else {
                VStack(spacing:12) {
                    Image(systemName:store.refreshing ? "arrow.triangle.2.circlepath" : "questionmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.refreshing ? "正在读取额度…" : "暂无可用额度数据").font(.callout)
                }.frame(maxWidth:.infinity,minHeight:150)
            }
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:6) {
                    Circle().fill(store.stale ? Color.orange : Color.green).frame(width:6,height:6)
                    Text(store.error ?? (store.refreshing ? "正在刷新…" : store.stale ? "数据已过期，正在等待刷新" : "已连接 · 每分钟自动刷新"))
                        .font(.system(size:11)).foregroundStyle(store.stale ? .orange : .secondary)
                }
                if let updated = store.updatedAt {
                    Text("上次更新 \(updated.formatted(date:.omitted,time:.standard))").font(.system(size:10)).foregroundStyle(.tertiary)
                }
                Text("仅显示服务器提供的额度窗口").font(.system(size:10)).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Button(action:{store.refresh()}) { Label("刷新",systemImage:"arrow.clockwise") }.disabled(store.refreshing)
                Spacer()
                Menu {
                    Button(store.autoStart ? "✓ 登录时启动" : "登录时启动") { store.toggleAutoStart() }
                    Button("打开 Codex") {
                        if let url = CodexInstallation.trustedApp() {
                            NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
                        }
                    }
                    Divider()
                    Button("退出小工具") { NSApp.terminate(nil) }
                } label: { Image(systemName:"ellipsis.circle") }.menuStyle(.borderlessButton).frame(width:24)
            }.font(.system(size:12))
        }.padding(20).frame(width:340)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = QuotaStore()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var panel: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--probe") {
            store.onChange = { [weak self] in
                guard let self, !self.store.refreshing else { return }
                if let error = self.store.error { print("PROBE FAILED: \(error)"); self.store.stop(); exit(1) }
                if let snapshot = self.store.snapshot {
                    for b in snapshot.buckets { for w in b.windows { print("\(b.name) | \(w.title) | remaining=\(w.remaining)%") } }
                    self.store.stop(); exit(0)
                }
            }
            store.start(); return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier:"io.github.codexquota.app").count > 1 { NSApp.terminate(nil); return }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:QuotaView(store:store,pinned:false,pinAction:{ [weak self] in self?.showPanel() }))
        store.onChange = { [weak self] in self?.updateTitle() }
        updateTitle(); store.start()
        if CommandLine.arguments.contains("--show-panel") { showPanel() }
    }
    func updateTitle() {
        statusItem?.button?.title = store.statusTitle
        statusItem?.button?.toolTip = "Codex 剩余额度；点击查看详情" + (store.stale ? "（数据待更新）" : "")
        let icon = NSImage(named:"StatusIcon")
        icon?.isTemplate = true
        icon?.size = NSSize(width:18,height:18)
        statusItem?.button?.image = icon
        statusItem?.button?.imagePosition = .imageLeading
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY) }
    }
    func showPanel() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps:true)
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:520),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        panel.title = "Codex 额度"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView:QuotaView(store:store,pinned:true,pinAction:{ [weak self] in self?.panel?.close() }))
        if let screen = NSScreen.main { panel.setFrameTopLeftPoint(NSPoint(x:screen.visibleFrame.maxX-360,y:screen.visibleFrame.maxY-25)) }
        self.panel = panel; panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationWillTerminate(_ notification: Notification) { store.stop() }
}

func selfTest() {
    func decode(_ json:String)->Snapshot { try! JSONDecoder().decode(Snapshot.self,from:Data(json.utf8)) }
    let weekly = decode(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null}}"#)
    precondition(weekly.main!.windows.count == 1 && weekly.main!.windows[0].remaining == 63)
    precondition(weekly.main!.windows[0].title == "每周额度")
    let missing = decode(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#)
    precondition(missing.main == nil)
    let multi = decode(#"{"rateLimitsByLimitId":{"spark":{"limitId":"spark","primary":{"usedPercent":0}},"codex":{"limitId":"codex","primary":{"usedPercent":110},"secondary":{"usedPercent":-2}}}}"#)
    precondition(multi.main!.limitId == "codex")
    precondition(multi.main!.windows.map(\.remaining) == [0,100])
    let otherOnly = decode(#"{"rateLimitsByLimitId":{"other":{"limitId":"other","primary":{"usedPercent":0}}}}"#)
    precondition(otherOnly.main == nil)
    let invalid = Data(#"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#.utf8)
    precondition((try? JSONDecoder().decode(Snapshot.self,from:invalid)) == nil)
    let decorated = decode(#"{"accountId":"TEST-ACCOUNT-NOT-REAL","accessToken":"TEST-TOKEN-NOT-REAL","rateLimits":{"limitId":"codex","primary":{"usedPercent":25}}}"#)
    let encoded = String(data:try! JSONEncoder().encode(decorated),encoding:.utf8)!
    precondition(!encoded.contains("TEST-ACCOUNT") && !encoded.contains("TEST-TOKEN"))
    let allowed = Set(["HOME","PATH","TMPDIR","USER","LOGNAME","LANG","LC_ALL","LC_CTYPE"])
    precondition(Set(CodexInstallation.environment().keys).isSubset(of:allowed))
    precondition(CodexInstallation.environment()["OPENAI_API_KEY"] == nil)
    print("PASS: quota parsing, missing windows, bounds, invalid data, identity exclusion, child environment allowlist")
}
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
