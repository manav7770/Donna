import Foundation
import AppKit
import os
import Combine

@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "DonnaSwift", category: "appstate")
    private let appLog = AppLog.shared

    let storage: StorageService
    let tracking: TrackingService
    let launchAtLogin: LaunchAtLoginService

    @Published var trackingEnabled: Bool = false
    @Published var launchAtLoginEnabled: Bool = false
    @Published var frontmostAppIcon: NSImage?
    private var maintenanceTimer: Timer?
    private var saveCounterSeconds: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        let dataDir = AppState.resolveDataDirectory()
        self.storage = StorageService(dataDirectory: dataDir)
        self.tracking = TrackingService()
        self.launchAtLogin = LaunchAtLoginService()
        self.launchAtLoginEnabled = launchAtLogin.isEnabled()
        bindTrackingChanges()

        // Enable launch-at-login by default on first run
        let hasSetLogin = UserDefaults.standard.bool(forKey: "donna.hasSetLaunchAtLogin")
        if !hasSetLogin {
            setLaunchAtLogin(true)
            UserDefaults.standard.set(true, forKey: "donna.hasSetLaunchAtLogin")
        }

        if let existing = storage.load(date: DailyRecord.today()) {
            tracking.load(record: existing)
        }

        logger.info("app state initialized with data dir=\(dataDir.path, privacy: .public)")
        appLog.log(.info, category: "appstate", "initialized", metadata: ["data_dir": dataDir.path])

        requestPermissionsOnFirstLaunch()
        startAll()
    }

    func startAll() {
        tracking.start()
        trackingEnabled = true
        startMaintenanceLoop()
        appLog.log(.info, category: "appstate", "start all")
    }

    func stopTracking() {
        tracking.stop()
        trackingEnabled = false
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        saveNow()
        appLog.log(.info, category: "appstate", "tracking paused")
    }

    func shutdown() {
        tracking.stop()
        trackingEnabled = false
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        saveNow()
        appLog.log(.info, category: "appstate", "shutdown complete")
    }

    func saveNow() {
        storage.save(record: tracking.record)
        saveCounterSeconds = 0
    }

    func resetToday() {
        tracking.reset()
        saveNow()
        appLog.log(.info, category: "appstate", "today reset")
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let ok = launchAtLogin.setEnabled(enabled)
        launchAtLoginEnabled = launchAtLogin.isEnabled()
        if ok {
            appLog.log(.info, category: "appstate", "launch at login changed", metadata: ["enabled": String(launchAtLoginEnabled)])
        } else {
            appLog.log(.error, category: "appstate", "launch at login change failed", metadata: ["requested": String(enabled)])
        }
        return ok
    }

    // MARK: - Permissions

    private func requestPermissionsOnFirstLaunch() {
        // 1. Accessibility — triggers the system prompt automatically
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        appLog.log(.info, category: "permissions", "accessibility trusted=\(trusted)")

        // 2. Automation — handled lazily during tracking.
        //    macOS shows "Allow <app> to control <browser>?" the first time
        //    an AppleScript targets a *running* browser. No need to trigger it
        //    here — TrackingService.frontmostBrowserDomain() will fire it
        //    naturally the first time the user switches to each browser.
    }

    private func startMaintenanceLoop() {
        guard maintenanceTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.maintenanceTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        maintenanceTimer = t
    }

    private func maintenanceTick() {
        // Update frontmost app icon
        if let app = NSWorkspace.shared.frontmostApplication {
            let icon = app.icon
            icon?.size = NSSize(width: 18, height: 18)
            frontmostAppIcon = icon
        }

        objectWillChange.send()

        guard trackingEnabled else { return }

        saveCounterSeconds += 1
        if saveCounterSeconds >= 30 {
            saveNow()
            appLog.log(.debug, category: "appstate", "auto-saved")
        }
    }

    private func bindTrackingChanges() {
        tracking.$record
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        tracking.$currentApp
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        tracking.$debugIdleSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var menuTitle: String {
        let r = tracking.record
        return "Active \(fmtSmart(r.activeSeconds))"
    }

    private func fmtSmart(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    struct SummaryData {
        let date: String
        let activeTime: String
        let ideTime: String
        let aiTime: String
        let aiPercent: Int
        let topApps: [(name: String, time: String, fraction: Double)]
    }

    func summaryData() -> SummaryData {
        let r = tracking.record
        let ide = ideSeconds(in: r.appSeconds)
        let ai = aiToolSeconds(in: r.appSeconds)
        let pct = r.activeSeconds > 0 ? (ai / r.activeSeconds) * 100 : 0
        let maxSec = r.appSeconds.values.max() ?? 1

        let top = r.appSeconds
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, time: fmtHM($0.value), fraction: $0.value / maxSec) }

        return SummaryData(
            date: r.date,
            activeTime: fmtHM(r.activeSeconds),
            ideTime: fmtHM(ide),
            aiTime: fmtHM(ai),
            aiPercent: Int(pct.rounded()),
            topApps: top
        )
    }

    private func ideSeconds(in appSeconds: [String: Double]) -> Double {
        let ideNames: Set<String> = [
            "Xcode", "Visual Studio Code", "Code", "Cursor", "Windsurf",
            "IntelliJ IDEA", "PyCharm", "WebStorm", "CLion", "GoLand", "Rider", "Fleet", "Zed", "Nova", "Sublime Text"
        ]
        return appSeconds.reduce(0) { partial, item in
            partial + (ideNames.contains(item.key) ? item.value : 0)
        }
    }

    private func aiToolSeconds(in appSeconds: [String: Double]) -> Double {
        let aiKeywords: [String] = [
            "ChatGPT", "Claude", "Perplexity", "Microsoft Copilot",
            "Gemini", "Grok", "Mistral", "HuggingChat", "Poe",
            "Phind", "You.com", "Replit AI", "v0",
            "DeepSeek", "Codeium", "Copilot", "Cody",
            "Amazon Q", "Tabnine"
        ]
        return appSeconds.reduce(0) { partial, item in
            // Match any key containing an AI keyword
            // Covers: "Google Chrome (ChatGPT)", "GitHub Copilot (Code)", "ChatGPT", etc.
            for keyword in aiKeywords {
                if item.key.contains(keyword) { return partial + item.value }
            }
            return partial
        }
    }

    private static func resolveDataDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["DONNA_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        // If running from repo root, this points at ./data.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directData = cwd.appendingPathComponent("data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: directData.path) {
            return directData
        }

        // If running from DonnaSwift/, this points at ../data.
        let parentData = cwd.appendingPathComponent("../data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: parentData.path) {
            return parentData
        }

        // Fallback for app bundle runs.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Donna/data", isDirectory: true)
    }

    private func fmtHM(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }
}
