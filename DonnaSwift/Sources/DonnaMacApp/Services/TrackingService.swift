import AppKit
import Foundation
import Quartz
import os

@MainActor
final class TrackingService: ObservableObject {
    private let logger = Logger(subsystem: "DonnaSwift", category: "tracking")
    private let appLog = AppLog.shared

    @Published private(set) var record: DailyRecord = DailyRecord()
    @Published private(set) var currentApp: String = "—"

    var pollInterval: TimeInterval = 5
    var idleThreshold: TimeInterval = 120

    private var timer: Timer?
    private var lastTick: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        logger.info("tracking started")
        appLog.log(.info, category: "tracking", "tracking started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("tracking stopped")
        appLog.log(.info, category: "tracking", "tracking stopped")
    }

    func reset() {
        record = DailyRecord()
        lastTick = nil
        currentApp = "—"
        logger.info("tracking reset")
        appLog.log(.info, category: "tracking", "tracking reset")
    }

    func load(record: DailyRecord) {
        self.record = record
        self.lastTick = nil
        appLog.log(.info, category: "tracking", "record loaded", metadata: ["date": record.date])
    }

    func addAway(seconds: Double) {
        guard seconds > 0 else { return }
        record.addAway(seconds: seconds)
    }

    private func tick() {
        let now = Date()
        let today = DailyRecord.today()

        if record.date != today {
            record = DailyRecord(date: today)
            logger.info("day rollover to \(today, privacy: .public)")
            appLog.log(.info, category: "tracking", "day rollover", metadata: ["date": today])
        }

        guard let previous = lastTick else {
            lastTick = now
            return
        }

        let elapsed = now.timeIntervalSince(previous)
        lastTick = now

        if isIdle() {
            record.addIdle(seconds: elapsed)
            currentApp = "—"
        } else {
            let app = frontmostApp() ?? "Unknown"
            record.addActive(app: app, seconds: elapsed)
            currentApp = app
        }
    }

    private func isIdle() -> Bool {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        return idleSeconds >= idleThreshold
    }

    private func frontmostApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
