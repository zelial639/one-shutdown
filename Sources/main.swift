// OneShutdown — 菜单栏一键关机:强制退出所有 App,跳过一切「确认退出/是否保存」弹窗
// 构建: ./build.sh

import AppKit
import SwiftUI
import BorderBeamKit

final class Actions: NSObject, NSMenuDelegate {
    private var busy = false // 防止关机流程进行中重复点击
    private var killedBundles: [String] = [] // 刚强退的 App 的 bundle 路径,用于追杀其残留子进程

    // 各 harness 的可执行文件名,与常见可恢复 agent 一一对应
    private let agentNames = ["claude", "codex", "pi", "devin", "opencode", "cursor-agent", "gemini", "amp"]

    private func targets() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
        }
    }

    // 按可执行文件 basename 匹配 agent 进程(含 Orca 这类宿主里跑的——SIGTERM 的是
    // agent 进程本身而非宿主 app,宿主留着)。ChatGPT 的 codex app-server 是纯服务无会话,排除。
    // 同名合并显示用:pi×2 而不是 pi, pi
    private func agentSummary(_ agents: [(pid: Int32, name: String)]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for a in agents { if counts[a.name] == nil { order.append(a.name) }; counts[a.name, default: 0] += 1 }
        return order.map { counts[$0]! > 1 ? "\($0)×\(counts[$0]!)" : $0 }.joined(separator: ", ")
    }

    private func runningAgents() -> [(pid: Int32, name: String)] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,args="] // args 而非 comm:需要过滤 app-server 这类无会话服务
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = Pipe()
        do { try ps.run() } catch { return [] }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        var found: [(Int32, String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let argv0 = parts[1].split(separator: " ").first ?? ""
            let name = URL(fileURLWithPath: String(argv0)).lastPathComponent
            // ChatGPT 的 codex app-server 是无会话常驻服务,没有可 resume 的会话
            if parts[1].contains("app-server") { continue }
            if agentNames.contains(name) && !found.contains(where: { $0.0 == pid }) {
                found.append((pid, name))
            }
        }
        return found
    }

    // 关机进度 HUD:深色悬浮小窗,列出 agent 等待状态和正在强退的 App
    private lazy var hud: NSPanel = {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 448, height: 248),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isFloatingPanel = true
        w.level = .floating // 浮在普通窗口上;不抢焦点
        w.backgroundColor = .clear
        w.isOpaque = false
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        let host = NSHostingView(rootView: HudView(text: ""))
        host.frame = NSRect(x: 0, y: 0, width: 448, height: 248)
        host.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(host)
        hudHost = host
        if let s = NSScreen.main {
            w.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 224, y: s.visibleFrame.midY - 124))
        }
        return w
    }()
    private var agentStates: [(pid: Int32, name: String, done: String?)] = [] // done: nil=等待中,否则为退出方式
    private var appNames: [String] = []
    private var phase = ""

    // HUD 内容 + BorderBeamKit(md/dark/colorful 旋转光束)——SwiftUI 视图套进 NSPanel
    private struct HudView: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(Color(white: 0.1).opacity(0.95), in: RoundedRectangle(cornerRadius: 10))
                .borderBeam(.md, theme: .dark, borderRadius: 10, brightness: 1.8) // HUD 小,默认强度看不清光束
                .padding(4)
        }
    }
    private var hudHost: NSHostingView<HudView>?

    private func updateHUD() {
        var lines = [phase]
        if !agentStates.isEmpty {
            lines += agentStates.map { "  \($0.done == nil ? "…" : "✓") \($0.name)\($0.done.map { " (\($0))" } ?? "")" }
        }
        if !appNames.isEmpty {
            lines.append(zh ? "正在退出 App:" : "Quitting apps:")
            lines.append("  " + appNames.joined(separator: ", "))
        }
        hudHost?.rootView = HudView(text: lines.joined(separator: "\n"))
        hud.orderFrontRegardless()
    }

    // ⌥点菜单项触发:用 mock 数据弹 HUD 循环演示,不动真进程;再 ⌥点关掉
    private var demoTimer: Timer?
    @objc func previewHUD() {
        if hud.isVisible { hud.close(); demoTimer?.invalidate(); return }
        // 演示固定英文:截图/README 里中文太长反而看不清状态
        phase = "Waiting for agents to exit (sessions stay resumable)…"
        agentStates = [(0, "pi", nil), (0, "claude", nil), (0, "devin", nil)]
        appNames = []
        updateHUD()
        var step = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            step += 1
            if step <= 3 {
                self.agentStates[step - 1].done = "exited"
                if step == 3 { self.phase = "\nForce-quitting apps (2 left)…"; self.appNames = ["Chrome", "iTerm2"] }
            } else if step == 4 {
                self.appNames = ["iTerm2"]
                self.phase = "\nForce-quitting apps (1 left)…"
            } else {
                self.hud.close(); self.demoTimer?.invalidate()
            }
            self.updateHUD()
        }
    }

    // SIGTERM 让 agent 把会话文件写完;pi/claude/devin 的 jsonl 追加落盘后下次才能 resume。
    // 轮询不阻塞主线程,HUD 才能实时刷新;5s 一轮后还不退的强杀。
    private func pollAgents(deadline: Date) {
        var waiting = false
        for i in agentStates.indices where agentStates[i].done == nil {
            if kill(agentStates[i].pid, 0) != 0 {
                agentStates[i].done = zh ? "已退出" : "exited"
            } else if Date() >= deadline {
                kill(agentStates[i].pid, SIGKILL)
                agentStates[i].done = zh ? "已强制结束" : "killed"
            } else { waiting = true }
        }
        updateHUD()
        if waiting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pollAgents(deadline: deadline) }
        } else {
            killAppsAndWait()
        }
    }

    private func killAppsAndWait() {
        // 普通关机会被 App 的确认弹窗拦住,所以先强退所有前台 App(Finder 强退会自动重启,跳过)
        phase = zh ? "\n正在强退 App…" : "\nForce-quitting apps…"
        killedBundles = targets().compactMap { $0.bundleURL?.path }
        appNames = targets().compactMap { $0.localizedName }
        targets().forEach { $0.forceTerminate() }
        updateHUD()
        waitUntilAllExit(deadline: Date().addingTimeInterval(30))
    }

    @objc func shutdownNow() {
        guard !busy else { return }

        let agents = runningAgents()

        // 二次确认:误点菜单时不该直接丢未保存数据
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = zh ? "确定要关机吗?" : "Shut Down Now?"
        var info = zh
            ? "将强制退出所有 App,未保存的内容会丢失。"
            : "All apps will be force-quit. Unsaved changes will be lost."
        if !agents.isEmpty {
            let names = agentSummary(agents)
            info += zh
                ? "\n检测到 \(agents.count) 个 agent 会话仍在运行(\(names)),关机前会先正常退出它们,确保会话记录可 resume。"
                : "\n\(agents.count) agent session(s) still running (\(names)). They'll be quit gracefully first so their session logs stay resumable."
        }
        alert.informativeText = info
        alert.addButton(withTitle: zh ? "关机" : "Shut Down")
        alert.addButton(withTitle: zh ? "取消" : "Cancel")
        NSApp.activate(ignoringOtherApps: true) // accessory 应用需主动抢焦点,否则弹窗可能藏在后面
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        // 先收 agent 再动 App:否则 agent 的宿主(终端/Orca)被先杀,会话丢尾巴
        phase = zh ? "正在等待 agent 正常退出(保留会话记录)…" : "Waiting for agents to exit (sessions stay resumable)…"
        agentStates = agents.map { (pid: $0.pid, name: $0.name, done: nil) }
        agents.forEach { kill($0.pid, SIGTERM) }
        updateHUD()
        if agents.isEmpty { killAppsAndWait() } else {
            pollAgents(deadline: Date().addingTimeInterval(5))
        }
    }

    // 每 0.2s 一轮:清掉 bundle 里的残留子进程,再查还有没有活着的 App——有就再强退一次
    // (有 CLI 会自动把浏览器拉活,比如 ego-browser;只要关机开始时还有 App 活着,它就能弹一个框拦下整个关机)。
    // 看到「干净」的空窗才发起关机;deadline 只是防止工具自己永远转下去的最后兜底。
    private func waitUntilAllExit(deadline: Date) {
        killLeftovers(in: killedBundles)
        let live = targets().filter { !$0.isTerminated }
        if live.isEmpty || Date() >= deadline {
            busy = false
            phase = zh ? "\n正在关机…" : "\nShutting down…"
            updateHUD()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"System Events\" to shut down"]
            try? task.run()
        } else {
            live.forEach { $0.forceTerminate() }
            let liveNames = Set(live.compactMap { $0.localizedName })
            appNames = appNames.filter { liveNames.contains($0) } // HUD 实时反映还剩谁
            phase = zh ? "\n正在强退 App(剩 \(live.count) 个)…" : "\nForce-quitting apps (\(live.count) left)…"
            updateHUD()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitUntilAllExit(deadline: deadline)
            }
        }
    }

    // 菜单每次展开时刷新第一行:用户能一眼看到还有 harness 在跑,再决定点不点关机
    func menuWillOpen(_ menu: NSMenu) {
        let agents = runningAgents()
        guard let item = menu.items.first else { return }
        item.title = agents.isEmpty
            ? (zh ? "没有运行中的 agent" : "No agents running")
            : (zh ? "\(agents.count) 个 agent 运行中: " : "\(agents.count) agent(s) running: ")
                + agentSummary(agents)
    }

    // forceTerminate 只杀 App 主进程;Chromium 系会留下一堆 helper/crashpad 子进程,
    // 可能占着外置盘拖慢卸载。按「可执行文件在 bundle 内」批量补刀。
    private func killLeftovers(in bundles: [String]) {
        guard !bundles.isEmpty else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,comm="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = Pipe()
        do {
            try ps.run()
        } catch { return }
        // 必须先读完管道再 wait:进程表输出可能超过 64KB 管道缓冲区,反过来写会死锁
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]),
                  bundles.contains(where: { parts[1].hasPrefix($0) }) else { continue }
            kill(pid, SIGKILL)
        }
    }
}

let actions = Actions()
let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.image = NSImage(systemSymbolName: "power", accessibilityDescription: "OneShutdown") // 模板图,自动适配深浅色

let menu = NSMenu()
let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
statusItem.isEnabled = false
menu.addItem(statusItem)
menu.addItem(.separator())
let shutdownItem = NSMenuItem(title: zh ? "立即关机" : "Shut Down Now", action: #selector(Actions.shutdownNow), keyEquivalent: "")
shutdownItem.target = actions
menu.addItem(shutdownItem)
// alternate 项:与其前一普通项同位配对,⌥按下时那行原地变成预览项
let previewItem = NSMenuItem(title: zh ? "预览关机面板(演示)" : "Preview shutdown panel", action: #selector(Actions.previewHUD), keyEquivalent: "")
previewItem.target = actions
previewItem.isAlternate = true
menu.addItem(previewItem)
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: zh ? "退出" : "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
item.menu = menu
menu.delegate = actions // 展开时刷新「运行中 agent」行

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 不占 Dock
app.run()