import Foundation

final class TrendsService {
    private let storage: StorageService
    private let categories: CategoryService

    init(storage: StorageService, categories: CategoryService) {
        self.storage = storage
        self.categories = categories
    }

    func weeklyTrends(weeks: Int = 1) -> String {
        let days = max(1, weeks) * 7
        let today = Date()
        let cal = Calendar.current

        var dates: [String] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            if let day = cal.date(byAdding: .day, value: -i, to: today) {
                dates.append(Self.dayString(day))
            }
        }

        let records: [(String, DailyRecord?)] = dates.map { ($0, storage.load(date: $0)) }

        var lines: [String] = []
        lines.append("╔══════════════════════════════════════════════════════╗")
        lines.append("║           📊  WEEKLY TRENDS DASHBOARD               ║")
        lines.append("╚══════════════════════════════════════════════════════╝")
        lines.append("")

        let maxActive = records.map { $0.1?.activeSeconds ?? 0 }.max() ?? 0
        lines.append("Active time per day:")
        lines.append(String(repeating: "─", count: 55))

        for (date, rec) in records {
            let active = rec?.activeSeconds ?? 0
            let weekday = Self.weekday(for: date)
            let mmdd = String(date.dropFirst(5))
            lines.append("  \(weekday) \(mmdd)  \(bar(value: active, maxValue: maxActive)) \(fmtHM(active))")
        }
        lines.append("")

        var weekActive = 0.0
        var weekIdle = 0.0
        var weekAway = 0.0
        var weekCats: [String: Double] = ["productive": 0, "distracting": 0, "neutral": 0]
        var weekApps: [String: Double] = [:]

        for (_, rec) in records {
            guard let rec else { continue }
            weekActive += rec.activeSeconds
            weekIdle += rec.idleSeconds
            weekAway += rec.awaySeconds

            let catTotals = categories.categorise(rec.appSeconds)
            for (k, v) in catTotals { weekCats[k, default: 0] += v }
            for (app, secs) in rec.appSeconds { weekApps[app, default: 0] += secs }
        }

        lines.append("Weekly totals:")
        lines.append(String(repeating: "─", count: 55))
        lines.append("  ✅  Active:      \(fmtHM(weekActive))")
        lines.append("  💤  Idle:        \(fmtHM(weekIdle))")
        lines.append("  🚶  Away:        \(fmtHM(weekAway))")
        lines.append("")

        let maxCat = weekCats.values.max() ?? 0
        lines.append("Category breakdown (week):")
        lines.append(String(repeating: "─", count: 55))
        for cat in ["productive", "distracting", "neutral"] {
            let secs = weekCats[cat, default: 0]
            let emoji = cat == "productive" ? "🟢" : (cat == "distracting" ? "🔴" : "⚪")
            let label = cat.prefix(1).uppercased() + cat.dropFirst()
            lines.append("  \(emoji) \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(bar(value: secs, maxValue: maxCat, width: 20)) \(fmtHM(secs))")
        }
        lines.append("")

        if weekActive > 0 {
            let score = (weekCats["productive", default: 0] / weekActive) * 100
            lines.append("🎯  Productivity score: \(Int(score.rounded()))%")
            lines.append("")
        }

        if !weekApps.isEmpty {
            lines.append("Top apps (week):")
            lines.append(String(repeating: "─", count: 55))
            for (index, pair) in weekApps.sorted(by: { $0.value > $1.value }).prefix(10).enumerated() {
                let app = pair.key
                let secs = pair.value
                let cat = categories.classify(app)
                let emoji = cat == "productive" ? "🟢" : (cat == "distracting" ? "🔴" : "⚪")
                let rank = String(format: "%2d", index + 1)
                let appLabel = app.padding(toLength: 25, withPad: " ", startingAt: 0)
                lines.append("  \(rank). \(emoji) \(appLabel) \(fmtHM(secs))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func fmtHM(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    private func bar(value: Double, maxValue: Double, width: Int = 30) -> String {
        guard maxValue > 0, width > 0 else { return "" }
        let length = Int((value / maxValue) * Double(width))
        return String(repeating: "█", count: max(0, length))
    }

    private static func weekday(for isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: isoDate) else { return "---" }

        let out = DateFormatter()
        out.dateFormat = "EEE"
        out.locale = Locale(identifier: "en_US_POSIX")
        return out.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
