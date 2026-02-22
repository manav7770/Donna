import Foundation
import os

struct GoalProgress {
    let goalHours: Double
    let currentHours: Double
    let percent: Double
    let reached: Bool
}

final class GoalService {
    private let logger = Logger(subsystem: "DonnaSwift", category: "goals")
    private let appLog = AppLog.shared
    private let goalsURL: URL
    private let categoryService: CategoryService
    private(set) var goalHours: Double = 4.0
    private var notifiedDate: String?

    init(goalsURL: URL, categoryService: CategoryService) {
        self.goalsURL = goalsURL
        self.categoryService = categoryService
        load()
    }

    var goalSeconds: Double { goalHours * 3600 }

    func setGoal(hours: Double) {
        guard hours > 0 else { return }
        goalHours = hours
        save()
        logger.info("goal updated hours=\(hours, privacy: .public)")
        appLog.log(.info, category: "goals", "goal updated", metadata: ["hours": String(hours)])
    }

    func progress(appSeconds: [String: Double]) -> GoalProgress {
        let totals = categoryService.categorise(appSeconds)
        let productive = totals["productive", default: 0]
        let percent = goalSeconds > 0 ? min(100, (productive / goalSeconds) * 100) : 100
        return GoalProgress(
            goalHours: goalHours,
            currentHours: productive / 3600,
            percent: percent,
            reached: productive >= goalSeconds
        )
    }

    func shouldNotify(appSeconds: [String: Double], today: String) -> Bool {
        let p = progress(appSeconds: appSeconds)
        guard p.reached, notifiedDate != today else { return false }
        notifiedDate = today
        appLog.log(.info, category: "goals", "goal reached", metadata: ["date": today, "hours": String(format: "%.2f", p.currentHours)])
        return true
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: goalsURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hours = obj["goal_hours"] as? Double
        else { return }
        goalHours = hours
        appLog.log(.info, category: "goals", "goal loaded", metadata: ["hours": String(hours)])
    }

    private func save() {
        let payload: [String: Any] = ["goal_hours": goalHours]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        do {
            try data.write(to: goalsURL)
        } catch {
            appLog.log(.error, category: "goals", "goal save failed", metadata: ["error": error.localizedDescription])
        }
    }
}
