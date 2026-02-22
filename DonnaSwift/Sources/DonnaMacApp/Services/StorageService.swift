import Foundation
import os

final class StorageService {
    private let logger = Logger(subsystem: "DonnaSwift", category: "storage")
    private let appLog = AppLog.shared
    let dataDirectory: URL

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    func save(record: DailyRecord) {
        let path = dataDirectory.appendingPathComponent("\(record.date).json")
        do {
            let data = try JSONEncoder.pretty.encode(record)
            try data.write(to: path)
            logger.info("record saved date=\(record.date, privacy: .public)")
            appLog.log(.info, category: "storage", "record saved", metadata: ["date": record.date, "path": path.path])
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            appLog.log(.error, category: "storage", "save failed", metadata: ["error": error.localizedDescription])
        }
    }

    func load(date: String) -> DailyRecord? {
        let path = dataDirectory.appendingPathComponent("\(date).json")
        guard let data = try? Data(contentsOf: path) else {
            appLog.log(.debug, category: "storage", "record not found", metadata: ["date": date])
            return nil
        }
        guard let record = try? JSONDecoder().decode(DailyRecord.self, from: data) else {
            appLog.log(.error, category: "storage", "decode failed", metadata: ["date": date])
            return nil
        }
        appLog.log(.info, category: "storage", "record loaded", metadata: ["date": date])
        return record
    }

    @discardableResult
    func exportCSV(record: DailyRecord, classify: (String) -> String) -> URL? {
        let path = dataDirectory.appendingPathComponent("\(record.date).csv")

        var lines: [String] = ["date,app_name,seconds,hours,category"]
        for (app, seconds) in record.appSeconds.sorted(by: { $0.value > $1.value }) {
            let escapedApp = app.replacingOccurrences(of: "\"", with: "\"\"")
            let hours = seconds / 3600
            let category = classify(app)
            lines.append("\(record.date),\"\(escapedApp)\",\(Int(seconds.rounded())),\(String(format: "%.4f", hours)),\(category)")
        }

        do {
            let csv = lines.joined(separator: "\n") + "\n"
            try csv.write(to: path, atomically: true, encoding: .utf8)
            appLog.log(.info, category: "storage", "csv exported", metadata: ["date": record.date, "path": path.path])
            return path
        } catch {
            appLog.log(.error, category: "storage", "csv export failed", metadata: ["date": record.date, "error": error.localizedDescription])
            return nil
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
