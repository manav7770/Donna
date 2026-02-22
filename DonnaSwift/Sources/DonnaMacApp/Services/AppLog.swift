import Foundation
import os

enum LogLevel: String {
    case debug
    case info
    case warning
    case error
}

final class AppLog {
    static let shared = AppLog()

    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "DonnaSwift.AppLog.Queue")
    private let fileURL: URL

    private init() {
        encoder.outputFormatting = [.sortedKeys]

        let directory = AppLog.resolveLogDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("donna.log")
    }

    func log(_ level: LogLevel, category: String, _ message: String, metadata: [String: String] = [:]) {
        let payload = LogPayload(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: level.rawValue,
            category: category,
            message: message,
            metadata: metadata
        )

        queue.async { [encoder, fileURL] in
            guard let line = try? encoder.encode(payload), var text = String(data: line, encoding: .utf8) else { return }
            text += "\n"
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    private static func resolveLogDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["DONNA_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("logs", isDirectory: true)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directData = cwd.appendingPathComponent("data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: directData.path) {
            return directData.appendingPathComponent("logs", isDirectory: true)
        }

        let parentData = cwd.appendingPathComponent("../data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: parentData.path) {
            return parentData.appendingPathComponent("logs", isDirectory: true)
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Donna/logs", isDirectory: true)
    }
}

private struct LogPayload: Codable {
    let timestamp: String
    let level: String
    let category: String
    let message: String
    let metadata: [String: String]
}
