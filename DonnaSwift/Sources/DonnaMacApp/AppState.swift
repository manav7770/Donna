import Foundation
import os
import UserNotifications
import Combine

@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "DonnaSwift", category: "appstate")
    private let appLog = AppLog.shared

    let storage: StorageService
    let categories: CategoryService
    let goals: GoalService
    let tracking: TrackingService
    let presence: PresenceService
    let trends: TrendsService
    let launchAtLogin: LaunchAtLoginService

    @Published var trackingEnabled: Bool = false
    @Published var launchAtLoginEnabled: Bool = false
    @Published var presenceEnabled: Bool = false
    @Published var presenceIsAway: Bool = false
    private var maintenanceTimer: Timer?
    private var lastMaintenanceTick: Date = .now
    private var saveCounterSeconds: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        let dataDir = AppState.resolveDataDirectory()
        self.storage = StorageService(dataDirectory: dataDir)
        self.categories = CategoryService(categoriesURL: dataDir.appendingPathComponent("categories.json"))
        self.goals = GoalService(
            goalsURL: dataDir.appendingPathComponent("goals.json"),
            categoryService: categories
        )
        self.tracking = TrackingService()
        self.presence = PresenceService()
        self.presenceEnabled = presence.isEnabled
        self.presenceIsAway = presence.isAway
        self.trends = TrendsService(storage: storage, categories: categories)
        self.launchAtLogin = LaunchAtLoginService()
        self.launchAtLoginEnabled = launchAtLogin.isEnabled()
        setupPresenceBindings()

        if let existing = storage.load(date: DailyRecord.today()) {
            tracking.load(record: existing)
        }

        requestNotificationPermission()

        logger.info("app state initialized with data dir=\(dataDir.path, privacy: .public)")
        appLog.log(.info, category: "appstate", "initialized", metadata: ["data_dir": dataDir.path])
        startAll()
    }

    func startAll() {
        tracking.start()
        trackingEnabled = true
        presence.start()
        startMaintenanceLoop()
        appLog.log(.info, category: "appstate", "start all")
    }

    func togglePresence() {
        if presenceEnabled {
            presence.stop()
        } else {
            presence.start()
        }
        appLog.log(.info, category: "appstate", "presence toggled", metadata: ["requested_enabled": String(!presenceEnabled)])
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
        presence.stop()
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

    func setGoal(hours: Double) {
        goals.setGoal(hours: hours)
    }

    func resetToday() {
        tracking.reset()
        lastMaintenanceTick = .now
        saveNow()
        appLog.log(.info, category: "appstate", "today reset")
    }

    func exportTodayCSV() -> URL? {
        storage.exportCSV(record: tracking.record, classify: categories.classify)
    }

    func weeklyTrendsText() -> String {
        trends.weeklyTrends(weeks: 1)
    }

    @discardableResult
    func recategorise(appName: String, category: String) -> Bool {
        let ok = categories.setCategory(appName: appName, category: category)
        if ok {
            appLog.log(.info, category: "appstate", "recategorised app", metadata: ["app": appName, "category": category])
        }
        return ok
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

    private func startMaintenanceLoop() {
        guard maintenanceTimer == nil else { return }
        lastMaintenanceTick = .now
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.maintenanceTick()
            }
        }
    }

    private func maintenanceTick() {
        guard trackingEnabled else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastMaintenanceTick)
        lastMaintenanceTick = now

        if presenceEnabled && presenceIsAway {
            tracking.addAway(seconds: elapsed)
        }

        saveCounterSeconds += elapsed
        if saveCounterSeconds >= 30 {
            saveNow()
            appLog.log(.debug, category: "appstate", "auto-saved")
        }

        if goals.shouldNotify(appSeconds: tracking.record.appSeconds, today: tracking.record.date) {
            postGoalReachedNotification()
        }
    }

    private func requestNotificationPermission() {
        guard canUseSystemNotifications() else {
            appLog.log(.warning, category: "appstate", "notifications disabled in unbundled run")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                self.appLog.log(.error, category: "appstate", "notification permission error", metadata: ["error": error.localizedDescription])
                return
            }
            self.appLog.log(.info, category: "appstate", "notification permission", metadata: ["granted": String(granted)])
        }
    }

    private func postGoalReachedNotification() {
        guard canUseSystemNotifications() else {
            appLog.log(.info, category: "appstate", "goal reached notification skipped in unbundled run")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Goal reached 🎯"
        content.body = "You reached your productive-hours goal for today."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "donna-goal-reached-\(tracking.record.date)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.appLog.log(.error, category: "appstate", "goal notification failed", metadata: ["error": error.localizedDescription])
            } else {
                self?.appLog.log(.info, category: "appstate", "goal notification posted")
            }
        }
    }

    private func canUseSystemNotifications() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return !Bundle.main.bundleURL.path.contains("/.build/")
    }

    private func setupPresenceBindings() {
        presence.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.presenceEnabled = enabled
            }
            .store(in: &cancellables)

        presence.$isAway
            .receive(on: RunLoop.main)
            .sink { [weak self] away in
                self?.presenceIsAway = away
            }
            .store(in: &cancellables)
    }

    var menuTitle: String {
        let catTotals = categories.categorise(tracking.record.appSeconds)
        let progress = goals.progress(appSeconds: tracking.record.appSeconds)
        let awayTag = presenceEnabled && presenceIsAway ? " · 🚶away" : ""
        return "⏱ \(fmtHM(tracking.record.activeSeconds)) active · 🟢\(fmtHM(catTotals["productive", default: 0])) · 🔴\(fmtHM(catTotals["distracting", default: 0])) · 🎯\(Int(progress.percent))%\(awayTag)"
    }

    var presenceStatusText: String {
        guard presenceEnabled else { return "📷 Presence: Off" }
        return presenceIsAway ? "📷 Presence: Away" : "📷 Presence: Present"
    }

    func summaryText() -> String {
        let r = tracking.record
        let catTotals = categories.categorise(r.appSeconds)
        let p = goals.progress(appSeconds: r.appSeconds)
        let topApps = r.appSeconds
            .sorted { $0.value > $1.value }
            .prefix(5)

        let topAppLines: String
        if topApps.isEmpty {
            topAppLines = "  (no tracked apps yet)"
        } else {
            topAppLines = topApps.enumerated().map { idx, pair in
                let app = pair.key
                let secs = pair.value
                let cat = categories.classify(app)
                let emoji = cat == "productive" ? "🟢" : (cat == "distracting" ? "🔴" : "⚪")
                return "  \(idx + 1). \(emoji) \(app): \(fmtHM(secs))"
            }.joined(separator: "\n")
        }

        return """
        📅 \(r.date)
        ✅ Active: \(fmtHM(r.activeSeconds))
        💤 Idle:   \(fmtHM(r.idleSeconds))
        🚶 Away:   \(fmtHM(r.awaySeconds))

        🎯 Goal: \(String(format: "%.1f", p.currentHours))h / \(String(format: "%.1f", p.goalHours))h (\(Int(p.percent))%)

        Category breakdown:
          🟢 Productive: \(fmtHM(catTotals["productive", default: 0]))
          🔴 Distracting: \(fmtHM(catTotals["distracting", default: 0]))
          ⚪ Neutral: \(fmtHM(catTotals["neutral", default: 0]))

                Top apps today:
                \(topAppLines)
        """
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
