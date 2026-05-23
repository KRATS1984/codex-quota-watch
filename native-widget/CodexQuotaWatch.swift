import Cocoa

let appVersion = "0.3.0"
let defaultConfigPath = "~/.codex-quota-watch/config.json"
let defaultWidgetStatePath = "~/.codex-quota-watch/widget-state.json"

struct WidgetConfig {
    var pollIntervalSeconds: TimeInterval = 300
    var showOnLaunch = true
    var alwaysOnTop = true
    var statePath = expandHome(defaultWidgetStatePath)
    var size: CGFloat = 96
    var idleOpacity: CGFloat = 0.55
    var activeOpacity: CGFloat = 0.94
    var edgeSnap = true
    var snapMargin: CGFloat = 12
}

struct AppConfig {
    var configPath = expandHome(defaultConfigPath)
    var codexPath = ProcessInfo.processInfo.environment["CODEX_CLI"] ?? "codex"
    var timeoutMs = 20_000
    var timeZone = TimeZone.current.identifier
    var widget = WidgetConfig()
}

struct WidgetState {
    var frame: NSRect?
    var hidden = false
}

struct WeeklyQuota {
    var remainingPercent: Int
    var usedPercent: Int
    var resetsAtText: String
    var checkedAt: Date
}

func expandHome(_ value: String) -> String {
    if value == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if value.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(value.dropFirst(2))).path
    }
    return value
}

func clampDouble(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
    return min(max(value, minValue), maxValue)
}

func clampPercent(_ value: Double) -> Int {
    return Int(clampDouble(value.rounded(), min: 0, max: 100))
}

func dictionary(from path: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandHome(path))),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return [:]
    }
    return dictionary
}

func stringValue(_ dictionary: [String: Any], _ key: String) -> String? {
    return dictionary[key] as? String
}

func doubleValue(_ dictionary: [String: Any], _ key: String) -> Double? {
    if let number = dictionary[key] as? NSNumber { return number.doubleValue }
    if let string = dictionary[key] as? String { return Double(string) }
    return nil
}

func boolValue(_ dictionary: [String: Any], _ key: String) -> Bool? {
    if let bool = dictionary[key] as? Bool { return bool }
    if let number = dictionary[key] as? NSNumber { return number.boolValue }
    return nil
}

func loadConfig(path: String) -> AppConfig {
    let expandedPath = expandHome(path)
    let root = dictionary(from: expandedPath)
    var config = AppConfig()
    config.configPath = expandedPath

    if let codexPath = stringValue(root, "codexPath"), !codexPath.isEmpty {
        config.codexPath = expandHome(codexPath)
    }
    if let timeoutMs = doubleValue(root, "timeoutMs") {
        config.timeoutMs = max(1_000, Int(timeoutMs))
    }
    if let timeZone = stringValue(root, "timeZone"), !timeZone.isEmpty {
        config.timeZone = timeZone
    }

    let widget = root["widget"] as? [String: Any] ?? [:]
    if let pollIntervalSeconds = doubleValue(widget, "pollIntervalSeconds") {
        config.widget.pollIntervalSeconds = max(15, pollIntervalSeconds)
    }
    if let showOnLaunch = boolValue(widget, "showOnLaunch") {
        config.widget.showOnLaunch = showOnLaunch
    }
    if let alwaysOnTop = boolValue(widget, "alwaysOnTop") {
        config.widget.alwaysOnTop = alwaysOnTop
    }
    if let statePath = stringValue(widget, "statePath"), !statePath.isEmpty {
        config.widget.statePath = expandHome(statePath)
    }
    if let size = doubleValue(widget, "size") {
        config.widget.size = CGFloat(clampDouble(size, min: 56, max: 160))
    }
    if let idleOpacity = doubleValue(widget, "idleOpacity") {
        config.widget.idleOpacity = CGFloat(clampDouble(idleOpacity, min: 0.25, max: 1))
    }
    if let activeOpacity = doubleValue(widget, "activeOpacity") {
        config.widget.activeOpacity = CGFloat(clampDouble(activeOpacity, min: 0.45, max: 1))
    }
    if config.widget.activeOpacity < config.widget.idleOpacity {
        config.widget.activeOpacity = config.widget.idleOpacity
    }
    if let edgeSnap = boolValue(widget, "edgeSnap") {
        config.widget.edgeSnap = edgeSnap
    }
    if let snapMargin = doubleValue(widget, "snapMargin") {
        config.widget.snapMargin = CGFloat(clampDouble(snapMargin, min: 0, max: 64))
    }

    return config
}

func loadState(path: String) -> WidgetState {
    let root = dictionary(from: path)
    var state = WidgetState()
    state.hidden = boolValue(root, "hidden") ?? false

    if let bounds = root["bounds"] as? [String: Any],
       let x = doubleValue(bounds, "x"),
       let y = doubleValue(bounds, "y") {
        let width = doubleValue(bounds, "width") ?? 96
        let height = doubleValue(bounds, "height") ?? 96
        state.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    return state
}

func saveState(_ state: WidgetState, path: String) {
    var root: [String: Any] = ["hidden": state.hidden]
    if let frame = state.frame {
        root["bounds"] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.width,
            "height": frame.height,
        ]
    }

    do {
        let url = URL(fileURLWithPath: expandHome(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    } catch {
        logError("Failed to save widget state: \(error.localizedDescription)")
    }
}

func logInfo(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func logError(_ message: String) {
    if let data = "\(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

final class CodexQuotaClient {
    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func fetchWeeklyQuota(completion: @escaping (Result<WeeklyQuota, Error>) -> Void) {
        let config = self.config
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            if config.codexPath.contains("/") {
                process.executableURL = URL(fileURLWithPath: config.codexPath)
                process.arguments = ["app-server", "--listen", "stdio://"]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [config.codexPath, "app-server", "--listen", "stdio://"]
            }

            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = environment["TERM"] == nil || environment["TERM"] == "dumb" ? "xterm-256color" : environment["TERM"]
            process.environment = environment

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let lock = NSLock()
            var stdoutBuffer = Data()
            var stderrText = ""
            var didFinish = false

            func finish(_ result: Result<WeeklyQuota, Error>) {
                lock.lock()
                if didFinish {
                    lock.unlock()
                    return
                }
                didFinish = true
                lock.unlock()

                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                try? stdin.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
                DispatchQueue.main.async {
                    completion(result)
                }
            }

            func sendJSON(_ object: [String: Any]) {
                guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                var line = data
                line.append(0x0A)
                try? stdin.fileHandleForWriting.write(contentsOf: line)
            }

            func parseLine(_ line: String) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let message = object as? [String: Any],
                      let id = (message["id"] as? NSNumber)?.intValue else {
                    return
                }

                if id == 1, message["result"] != nil {
                    sendJSON(["method": "initialized"])
                    sendJSON(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
                } else if id == 1, let error = message["error"] {
                    finish(.failure(NSError(domain: "CodexQuotaWatch", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Codex initialize failed: \(error)",
                    ])))
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    do {
                        finish(.success(try Self.weeklyQuota(from: result, timeZone: config.timeZone)))
                    } catch {
                        finish(.failure(error))
                    }
                } else if id == 2, let error = message["error"] {
                    finish(.failure(NSError(domain: "CodexQuotaWatch", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Codex rate limit read failed: \(error)",
                    ])))
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }

                lock.lock()
                stdoutBuffer.append(data)
                while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                    let lineData = stdoutBuffer[..<newline]
                    stdoutBuffer.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        lock.unlock()
                        parseLine(line)
                        lock.lock()
                    }
                }
                lock.unlock()
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let chunk = String(data: data, encoding: .utf8) {
                    lock.lock()
                    stderrText += chunk
                    lock.unlock()
                }
            }

            process.terminationHandler = { _ in
                lock.lock()
                let alreadyFinished = didFinish
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                if !alreadyFinished {
                    finish(.failure(NSError(domain: "CodexQuotaWatch", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: detail.isEmpty ? "Codex app-server exited before returning rate limits" : detail,
                    ])))
                }
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error))
                return
            }

            sendJSON([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "codex-quota-watch-native-widget", "version": appVersion],
                    "capabilities": [
                        "experimentalApi": true,
                        "optOutNotificationMethods": [],
                    ],
                ],
            ])

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(config.timeoutMs)) {
                finish(.failure(NSError(domain: "CodexQuotaWatch", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out reading Codex rate limits after \(config.timeoutMs) ms",
                ])))
            }
        }
    }

    private static func weeklyQuota(from result: [String: Any], timeZone: String) throws -> WeeklyQuota {
        let byId = result["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = byId?["codex"] as? [String: Any]
        let fallbackSnapshot = result["rateLimits"] as? [String: Any]
        let snapshot = codexSnapshot ?? fallbackSnapshot
        let secondary = snapshot?["secondary"] as? [String: Any] ?? fallbackSnapshot?["secondary"] as? [String: Any]

        guard let window = secondary,
              let used = doubleValue(window, "usedPercent") else {
            throw NSError(domain: "CodexQuotaWatch", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Weekly Codex quota window is unavailable",
            ])
        }

        let usedPercent = clampPercent(used)
        let remainingPercent = clampPercent(100 - Double(usedPercent))
        let resetsAt = doubleValue(window, "resetsAt")

        return WeeklyQuota(
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            resetsAtText: formatResetTime(resetsAt, timeZone: timeZone),
            checkedAt: Date()
        )
    }

    private static func formatResetTime(_ epochSeconds: Double?, timeZone: String) -> String {
        guard let epochSeconds else { return "unknown" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }
}

final class RingView: NSView {
    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var offline = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset: CGFloat = 7
        let diameter = min(bounds.width, bounds.height) - inset * 2
        let rect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = diameter / 2
        let lineWidth: CGFloat = 3.5

        let track = NSBezierPath()
        track.lineWidth = lineWidth
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        let ring = NSBezierPath()
        ring.lineWidth = lineWidth
        ring.lineCapStyle = .round
        ring.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * progress,
            clockwise: true
        )
        let color = offline ? NSColor.systemOrange : NSColor.controlAccentColor
        color.withAlphaComponent(0.9).setStroke()
        ring.stroke()
    }
}

final class OrbView: NSView {
    let materialView = NSVisualEffectView()
    let ringView = RingView()
    let percentLabel = NSTextField(labelWithString: "--%")
    let statusDot = NSView()
    var onHoverChanged: ((Bool) -> Void)?
    var onDragChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onRefreshRequested: (() -> Void)?
    var contextualMenuProvider: (() -> NSMenu?)?

    private var trackingAreaRef: NSTrackingArea?
    private var dragStartMouse: NSPoint?
    private var dragStartFrame: NSRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)

        ringView.autoresizingMask = [.width, .height]
        ringView.isHidden = false
        addSubview(ringView)

        percentLabel.alignment = .center
        percentLabel.textColor = .labelColor
        percentLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        percentLabel.backgroundColor = .clear
        percentLabel.isBezeled = false
        percentLabel.isEditable = false
        percentLabel.isSelectable = false
        addSubview(percentLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.isHidden = true
        addSubview(statusDot)
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        materialView.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        ringView.frame = bounds
        percentLabel.frame = NSRect(x: 0, y: bounds.midY - 16, width: bounds.width, height: 34)
        statusDot.frame = NSRect(x: bounds.maxX - 24, y: 18, width: 7, height: 7)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func render(quota: WeeklyQuota, offline: Bool) {
        percentLabel.stringValue = "\(quota.remainingPercent)%"
        ringView.progress = CGFloat(quota.remainingPercent) / 100
        ringView.offline = offline
        statusDot.isHidden = !offline
        toolTip = offline
            ? "Offline. Last known: \(quota.remainingPercent)%, reset \(quota.resetsAtText)"
            : "Weekly remaining \(quota.remainingPercent)%, reset \(quota.resetsAtText)"
    }

    func renderOffline(message: String) {
        percentLabel.stringValue = "--%"
        ringView.progress = 0
        ringView.offline = true
        statusDot.isHidden = false
        toolTip = "Offline: \(message)"
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onRefreshRequested?()
            return
        }
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window?.frame
        onDragChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartMouse, let dragStartFrame else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y
        window.setFrameOrigin(NSPoint(x: dragStartFrame.minX + dx, y: dragStartFrame.minY + dy))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartFrame = nil
        onDragChanged?(false)
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextualMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig()
    private var state = WidgetState()
    private var client: CodexQuotaClient?
    private var panel: NSPanel?
    private var orbView: OrbView?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var idleTimer: Timer?
    private var lastQuota: WeeklyQuota?
    private var offline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        config = loadConfig(path: parseConfigPath())
        state = loadState(path: config.widget.statePath)
        client = CodexQuotaClient(config: config)

        createStatusItem()
        createPanel()
        updateStatusMenu()

        if config.widget.showOnLaunch && !state.hidden {
            showOrb()
        }

        refreshQuota()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.widget.pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistState()
    }

    private func parseConfigPath() -> String {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--config"), args.indices.contains(idx + 1) else {
            return defaultConfigPath
        }
        return args[idx + 1]
    }

    private func createPanel() {
        let size = config.widget.size
        let frame = normalizedFrame(savedFrame: state.frame, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = config.widget.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.alphaValue = config.widget.idleOpacity

        let orb = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        orb.onHoverChanged = { [weak self] hovering in
            self?.setActive(hovering)
        }
        orb.onDragChanged = { [weak self] dragging in
            self?.setActive(dragging)
        }
        orb.onDragEnded = { [weak self] in
            self?.snapPanelIfNeeded()
            self?.persistState()
        }
        orb.onRefreshRequested = { [weak self] in
            self?.refreshQuota()
        }
        orb.contextualMenuProvider = { [weak self] in
            self?.buildMenu()
        }

        panel.contentView = orb
        self.panel = panel
        self.orbView = orb
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "percent", accessibilityDescription: "Codex quota")
            button.imagePosition = .imageLeading
            button.title = ""
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let title = lastQuota.map { "Weekly Remaining: \($0.remainingPercent)%" } ?? "Weekly Remaining: --"
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let reset = lastQuota.map { "Reset: \($0.resetsAtText)" } ?? "Reset: unknown"
        let resetItem = NSMenuItem(title: offline ? "\(reset) (offline)" : reset, action: nil, keyEquivalent: "")
        resetItem.isEnabled = false
        menu.addItem(resetItem)
        menu.addItem(.separator())

        let visible = panel?.isVisible == true
        let showHide = NSMenuItem(title: visible ? "Hide Orb" : "Show Orb", action: #selector(toggleOrb), keyEquivalent: "")
        showHide.target = self
        showHide.image = NSImage(systemSymbolName: visible ? "eye.slash" : "eye", accessibilityDescription: nil)
        menu.addItem(showHide)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshQuotaFromMenu), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        return menu
    }

    private func updateStatusMenu() {
        statusItem?.menu = buildMenu()
        if let button = statusItem?.button {
            if let quota = lastQuota {
                button.title = " \(quota.remainingPercent)%"
                button.toolTip = offline
                    ? "Codex weekly remaining: \(quota.remainingPercent)% (offline)"
                    : "Codex weekly remaining: \(quota.remainingPercent)%"
            } else {
                button.title = ""
                button.toolTip = "Codex weekly quota"
            }
        }
    }

    @objc private func refreshQuotaFromMenu() {
        refreshQuota()
    }

    private func refreshQuota() {
        client?.fetchWeeklyQuota { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let quota):
                lastQuota = quota
                offline = false
                orbView?.render(quota: quota, offline: false)
                logInfo("[widget] weekly remaining=\(quota.remainingPercent)% used=\(quota.usedPercent)% reset=\(quota.resetsAtText)")
            case .failure(let error):
                offline = true
                logError("[widget] quota refresh failed: \(error.localizedDescription)")
                if let lastQuota {
                    orbView?.render(quota: lastQuota, offline: true)
                } else {
                    orbView?.renderOffline(message: error.localizedDescription)
                }
            }
            updateStatusMenu()
        }
    }

    @objc private func toggleOrb() {
        if panel?.isVisible == true {
            hideOrb()
        } else {
            showOrb()
        }
    }

    private func showOrb() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
        panel?.level = config.widget.alwaysOnTop ? .floating : .normal
        state.hidden = false
        persistState()
        setActive(true)
        scheduleIdleFade()
        updateStatusMenu()
    }

    private func hideOrb() {
        panel?.orderOut(nil)
        state.hidden = true
        persistState()
        updateStatusMenu()
    }

    @objc private func quit() {
        persistState()
        NSApp.terminate(nil)
    }

    private func setActive(_ active: Bool) {
        idleTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel?.animator().alphaValue = active ? config.widget.activeOpacity : config.widget.idleOpacity
        }
        if active {
            scheduleIdleFade()
        }
    }

    private func scheduleIdleFade() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
            self?.setActive(false)
        }
    }

    private func normalizedFrame(savedFrame: NSRect?, size: CGFloat) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fallback = NSRect(
            x: screenFrame.maxX - size - config.widget.snapMargin,
            y: screenFrame.maxY - size - 72,
            width: size,
            height: size
        )
        guard var frame = savedFrame else { return fallback }
        frame.size = NSSize(width: size, height: size)
        return clampedFrame(frame, in: screenFrame)
    }

    private func clampedFrame(_ frame: NSRect, in screenFrame: NSRect) -> NSRect {
        let x = clampDouble(frame.minX, min: screenFrame.minX, max: screenFrame.maxX - frame.width)
        let y = clampDouble(frame.minY, min: screenFrame.minY, max: screenFrame.maxY - frame.height)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func snapPanelIfNeeded() {
        guard config.widget.edgeSnap, let panel else { return }
        let frame = panel.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }

        let margin = config.widget.snapMargin
        let leftX = screenFrame.minX + margin
        let rightX = screenFrame.maxX - frame.width - margin
        let snappedX = abs(frame.minX - leftX) <= abs(frame.minX - rightX) ? leftX : rightX
        let snappedY = clampDouble(frame.minY, min: screenFrame.minY + margin, max: screenFrame.maxY - frame.height - margin)
        panel.setFrameOrigin(NSPoint(x: snappedX, y: snappedY))
    }

    private func persistState() {
        if let panel {
            state.frame = panel.frame
        }
        saveState(state, path: config.widget.statePath)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
