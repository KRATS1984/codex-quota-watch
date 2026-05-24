import Cocoa
import ScreenCaptureKit

let appVersion = "0.3.0"
let defaultConfigPath = "~/.codex-quota-watch/config.json"
let defaultWidgetStatePath = "~/.codex-quota-watch/widget-state.json"
let orbWindowPadding: CGFloat = 8

struct WidgetConfig {
    var pollIntervalSeconds: TimeInterval = 300
    var showOnLaunch = true
    var alwaysOnTop = true
    var statePath = expandHome(defaultWidgetStatePath)
    var size: CGFloat = 96
    var idleOpacity: CGFloat = 0.48
    var activeOpacity: CGFloat = 0.9
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

func isDarkAppearance(_ appearance: NSAppearance?) -> Bool {
    let resolved = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [
        .aqua,
        .darkAqua,
        .vibrantLight,
        .vibrantDark,
    ])
    return resolved == .darkAqua || resolved == .vibrantDark
}

enum BackgroundTone {
    case light
    case dark

    var usesLightContent: Bool {
        self == .dark
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
    var backgroundTone: BackgroundTone = .light {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lightContent = backgroundTone.usesLightContent
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
        let lineWidth: CGFloat = 2.5

        let track = NSBezierPath()
        track.lineWidth = lineWidth
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        (lightContent ? NSColor.white : NSColor.black).withAlphaComponent(lightContent ? 0.28 : 0.18).setStroke()
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
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        let contrastColor = lightContent ? NSColor.white : NSColor.black
        let softAccent = accent.blended(withFraction: lightContent ? 0.14 : 0.26, of: contrastColor) ?? accent
        let color = offline
            ? NSColor.systemOrange.withAlphaComponent(lightContent ? 0.82 : 0.72)
            : softAccent.withAlphaComponent(lightContent ? 0.92 : 0.86)
        color.setStroke()
        ring.stroke()
    }
}

final class DetailBubbleView: NSView {
    private let materialView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var backgroundTone: BackgroundTone = .light

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateResolvedColors()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.cornerRadius = 15
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.8
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)

        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        updateResolvedColors()
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        label.frame = NSRect(x: 12, y: 6, width: bounds.width - 24, height: 20)
    }

    func render(text: String) {
        label.stringValue = text
    }

    func refreshAppearance() {
        updateResolvedColors()
        needsDisplay = true
    }

    func setBackgroundTone(_ tone: BackgroundTone) {
        backgroundTone = tone
        refreshAppearance()
    }

    private func updateResolvedColors() {
        let lightContent = backgroundTone.usesLightContent
        materialView.appearance = NSAppearance(named: lightContent ? .darkAqua : .aqua)
        materialView.material = lightContent ? .hudWindow : .popover
        materialView.layer?.borderColor = (lightContent ? NSColor.white : NSColor.black)
            .withAlphaComponent(lightContent ? 0.26 : 0.14)
            .cgColor
        label.textColor = (lightContent ? NSColor.white : NSColor.black).withAlphaComponent(lightContent ? 0.88 : 0.62)
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
    private var currentPercent: Int?
    private var showingOfflinePlaceholder = false
    private var backgroundTone: BackgroundTone = .light

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateResolvedColors()
        ringView.needsDisplay = true
        if let currentPercent {
            setPercentValue(currentPercent)
        } else if showingOfflinePlaceholder {
            setOfflinePercent()
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.8
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)

        ringView.autoresizingMask = [.width, .height]
        ringView.isHidden = false
        addSubview(ringView)

        percentLabel.alignment = .center
        percentLabel.font = .systemFont(ofSize: 25, weight: .medium)
        percentLabel.backgroundColor = .clear
        percentLabel.isBezeled = false
        percentLabel.isEditable = false
        percentLabel.isSelectable = false
        addSubview(percentLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.isHidden = true
        addSubview(statusDot)
        updateResolvedColors()
    }

    override func layout() {
        super.layout()
        let visualFrame = bounds.insetBy(dx: orbWindowPadding, dy: orbWindowPadding)
        materialView.frame = visualFrame
        materialView.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        materialView.layer?.cornerRadius = min(visualFrame.width, visualFrame.height) / 2
        ringView.frame = visualFrame
        percentLabel.frame = NSRect(x: visualFrame.minX, y: visualFrame.midY - 15, width: visualFrame.width, height: 32)
        statusDot.frame = NSRect(x: visualFrame.maxX - 24, y: visualFrame.minY + 18, width: 6, height: 6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func render(quota: WeeklyQuota, offline: Bool) {
        currentPercent = quota.remainingPercent
        showingOfflinePlaceholder = false
        setPercentValue(quota.remainingPercent)
        ringView.progress = CGFloat(quota.remainingPercent) / 100
        ringView.offline = offline
        statusDot.isHidden = !offline
        toolTip = offline
            ? "Offline. Last known: \(quota.remainingPercent)%, reset \(quota.resetsAtText)"
            : "Weekly remaining \(quota.remainingPercent)%, reset \(quota.resetsAtText)"
    }

    func renderOffline(message: String) {
        currentPercent = nil
        showingOfflinePlaceholder = true
        setOfflinePercent()
        ringView.progress = 0
        ringView.offline = true
        statusDot.isHidden = false
        toolTip = "Offline: \(message)"
    }

    private func setPercentValue(_ value: Int) {
        let lightContent = backgroundTone.usesLightContent
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let baseColor = lightContent ? NSColor.white : NSColor.black
        let text = NSMutableAttributedString(
            string: "\(value)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 25, weight: .medium),
                .foregroundColor: baseColor.withAlphaComponent(lightContent ? 0.96 : 0.68),
                .paragraphStyle: paragraph,
            ]
        )
        text.append(NSAttributedString(
            string: "%",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: baseColor.withAlphaComponent(lightContent ? 0.78 : 0.5),
                .baselineOffset: 2,
                .paragraphStyle: paragraph,
            ]
        ))
        percentLabel.attributedStringValue = text
    }

    private func setOfflinePercent() {
        let lightContent = backgroundTone.usesLightContent
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        percentLabel.attributedStringValue = NSAttributedString(
            string: "--%",
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: (lightContent ? NSColor.white : NSColor.black).withAlphaComponent(lightContent ? 0.9 : 0.54),
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func updateResolvedColors() {
        let lightContent = backgroundTone.usesLightContent
        materialView.appearance = NSAppearance(named: lightContent ? .darkAqua : .aqua)
        materialView.material = lightContent ? .hudWindow : .popover
        materialView.layer?.borderColor = (lightContent ? NSColor.white : NSColor.black)
            .withAlphaComponent(lightContent ? 0.28 : 0.14)
            .cgColor
        statusDot.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(lightContent ? 0.86 : 0.72).cgColor
    }

    func refreshAppearance() {
        updateResolvedColors()
        ringView.needsDisplay = true
        if let currentPercent {
            setPercentValue(currentPercent)
        } else if showingOfflinePlaceholder {
            setOfflinePercent()
        }
        needsDisplay = true
    }

    func setBackgroundTone(_ tone: BackgroundTone) {
        backgroundTone = tone
        ringView.backgroundTone = tone
        refreshAppearance()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverChanged?(true)
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onHoverChanged?(true)
        }
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
    private var detailPanel: NSPanel?
    private var detailView: DetailBubbleView?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var idleTimer: Timer?
    private var backgroundSampleTimer: Timer?
    private var lastQuota: WeeklyQuota?
    private var offline = false
    private var backgroundTone: BackgroundTone = .light
    private var isSamplingBackground = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        config = loadConfig(path: parseConfigPath())
        state = loadState(path: config.widget.statePath)
        client = CodexQuotaClient(config: config)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        createStatusItem()
        createPanel()
        updateStatusMenu()

        if config.widget.showOnLaunch && !state.hidden {
            showOrb()
        }
        startBackgroundSampling()

        refreshQuota()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.widget.pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundSampleTimer?.invalidate()
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
        let size = config.widget.size + orbWindowPadding * 2
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
        panel.acceptsMouseMovedEvents = true
        panel.alphaValue = adjustedIdleOpacity()

        let orb = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        orb.onHoverChanged = { [weak self] hovering in
            self?.setActive(hovering)
            if hovering {
                self?.showDetailBubble()
            } else {
                self?.hideDetailBubble()
            }
        }
        orb.onDragChanged = { [weak self] dragging in
            self?.setActive(dragging)
            if dragging {
                self?.hideDetailBubble()
            }
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
        applyBackgroundTone(backgroundTone)
    }

    private func createDetailPanel() {
        let frame = NSRect(x: 0, y: 0, width: 150, height: 32)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = config.widget.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0

        let view = DetailBubbleView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        panel.contentView = view
        detailPanel = panel
        detailView = view
        view.setBackgroundTone(backgroundTone)
    }

    @objc private func systemAppearanceChanged() {
        refreshBackgroundTone()
        if panel?.isVisible == true {
            panel?.alphaValue = adjustedIdleOpacity()
        }
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
            updateDetailBubbleText()
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
        refreshBackgroundTone()
        setActive(true, autoFade: true)
        updateStatusMenu()
    }

    private func hideOrb() {
        panel?.orderOut(nil)
        hideDetailBubble()
        state.hidden = true
        persistState()
        updateStatusMenu()
    }

    @objc private func quit() {
        persistState()
        NSApp.terminate(nil)
    }

    private func setActive(_ active: Bool, autoFade: Bool = false) {
        idleTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel?.animator().alphaValue = active ? adjustedActiveOpacity() : adjustedIdleOpacity()
        }
        if active && autoFade {
            scheduleIdleFade()
        }
    }

    private func adjustedIdleOpacity() -> CGFloat {
        return backgroundTone.usesLightContent
            ? max(config.widget.idleOpacity, 0.66)
            : max(config.widget.idleOpacity, 0.58)
    }

    private func adjustedActiveOpacity() -> CGFloat {
        return backgroundTone.usesLightContent
            ? max(config.widget.activeOpacity, 0.94)
            : max(config.widget.activeOpacity, 0.9)
    }

    private func startBackgroundSampling() {
        backgroundSampleTimer?.invalidate()
        refreshBackgroundTone()
        backgroundSampleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshBackgroundTone()
        }
    }

    private func refreshBackgroundTone() {
        guard !isSamplingBackground else {
            return
        }

        guard let sampleRect = sampleRectNearOrb(), #available(macOS 15.2, *) else {
            setBackgroundTone(.light)
            return
        }

        isSamplingBackground = true
        SCScreenshotManager.captureImage(in: sampleRect) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSamplingBackground = false
                guard let image,
                      let luminance = self.averageLuminance(of: image) else {
                    self.setBackgroundTone(.light)
                    return
                }
                self.setBackgroundTone(luminance < 0.52 ? .dark : .light)
            }
        }
    }

    private func setBackgroundTone(_ tone: BackgroundTone) {
        guard tone != backgroundTone else { return }
        backgroundTone = tone
        applyBackgroundTone(tone)
        if panel?.isVisible == true {
            panel?.alphaValue = adjustedIdleOpacity()
        }
    }

    private func applyBackgroundTone(_ tone: BackgroundTone) {
        orbView?.setBackgroundTone(tone)
        detailView?.setBackgroundTone(tone)
    }

    private func sampleRectNearOrb() -> CGRect? {
        guard let panel,
              panel.isVisible,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)
        let screenFrame = screen.frame
        let sampleSize: CGFloat = 48
        let gap: CGFloat = 8
        let showLeft = panel.frame.midX > screenFrame.midX
        let leftX = panel.frame.minX - gap - sampleSize
        let rightX = panel.frame.maxX + gap
        let preferredX = showLeft ? leftX : rightX
        let fallbackX = showLeft ? rightX : leftX
        let fitsPreferred = preferredX >= screenFrame.minX && preferredX + sampleSize <= screenFrame.maxX
        let chosenX = fitsPreferred ? preferredX : fallbackX
        let sampleFrame = NSRect(
            x: clampDouble(chosenX, min: screenFrame.minX, max: screenFrame.maxX - sampleSize),
            y: clampDouble(panel.frame.midY - sampleSize / 2, min: screenFrame.minY, max: screenFrame.maxY - sampleSize),
            width: sampleSize,
            height: sampleSize
        )
        let xInScreen = sampleFrame.minX - screenFrame.minX
        let yFromTop = screenFrame.maxY - sampleFrame.maxY
        return CGRect(
            x: displayBounds.minX + xInScreen,
            y: displayBounds.minY + yFromTop,
            width: sampleFrame.width,
            height: sampleFrame.height
        )
    }

    private func averageLuminance(of image: CGImage) -> CGFloat? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func detailText() -> String {
        if offline {
            if let lastQuota {
                return "Offline · Reset \(lastQuota.resetsAtText)"
            }
            return "Offline"
        }
        return lastQuota.map { "Reset \($0.resetsAtText)" } ?? "Syncing"
    }

    private func updateDetailBubbleText() {
        detailView?.render(text: detailText())
    }

    private func showDetailBubble() {
        guard panel?.isVisible == true else { return }
        if detailPanel == nil {
            createDetailPanel()
        }
        updateDetailBubbleText()
        positionDetailBubble()
        detailPanel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            detailPanel?.animator().alphaValue = 0.92
        }
    }

    private func hideDetailBubble() {
        guard let detailPanel, detailPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            detailPanel.animator().alphaValue = 0
        } completionHandler: {
            detailPanel.orderOut(nil)
        }
    }

    private func positionDetailBubble() {
        guard let panel, let detailPanel else { return }
        let orbFrame = panel.frame
        let bubbleFrame = detailPanel.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(orbFrame) } ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }

        let gap: CGFloat = 8
        let showLeft = orbFrame.midX > screenFrame.midX
        let x = showLeft ? orbFrame.minX - bubbleFrame.width - gap : orbFrame.maxX + gap
        let y = clampDouble(
            orbFrame.midY - bubbleFrame.height / 2,
            min: screenFrame.minY + config.widget.snapMargin,
            max: screenFrame.maxY - bubbleFrame.height - config.widget.snapMargin
        )
        let clampedX = clampDouble(
            x,
            min: screenFrame.minX + config.widget.snapMargin,
            max: screenFrame.maxX - bubbleFrame.width - config.widget.snapMargin
        )
        detailPanel.setFrameOrigin(NSPoint(x: clampedX, y: y))
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
