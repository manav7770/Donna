import Foundation

struct DailyRecord: Codable {
    var date: String
    var activeSeconds: Double
    var idleSeconds: Double
    var appSeconds: [String: Double]

    init(
        date: String = DailyRecord.today(),
        activeSeconds: Double = 0,
        idleSeconds: Double = 0,
        appSeconds: [String: Double] = [:]
    ) {
        self.date = date
        self.activeSeconds = activeSeconds
        self.idleSeconds = idleSeconds
        self.appSeconds = appSeconds
    }

    mutating func addActive(app: String, seconds: Double) {
        activeSeconds += seconds
        appSeconds[app, default: 0] += seconds
    }

    mutating func addIdle(seconds: Double) {
        idleSeconds += seconds
    }

    static func today() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }

    enum CodingKeys: String, CodingKey {
        case date
        case activeSeconds = "active_seconds"
        case idleSeconds = "idle_seconds"
        case appSeconds = "app_seconds"
    }
}
