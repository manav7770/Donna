import Foundation
import os

final class CategoryService {
    private let logger = Logger(subsystem: "DonnaSwift", category: "categories")
    private let appLog = AppLog.shared
    private let categoriesURL: URL

    private let defaultMapping: [String: String] = [
        "xcode": "productive",
        "visual studio code": "productive",
        "code": "productive",
        "terminal": "productive",
        "iterm2": "productive",
        "warp": "productive",
        "notion": "productive",
        "figma": "productive",
        "slack": "productive",

        "safari": "distracting",
        "google chrome": "distracting",
        "firefox": "distracting",
        "youtube": "distracting",
        "netflix": "distracting",
        "reddit": "distracting",
        "twitter": "distracting",
        "instagram": "distracting",

        "finder": "neutral",
        "system settings": "neutral",
        "activity monitor": "neutral"
    ]

    private var mapping: [String: String]

    init(categoriesURL: URL) {
        self.categoriesURL = categoriesURL
        self.mapping = defaultMapping
        load()
    }

    func classify(_ appName: String) -> String {
        mapping[appName.lowercased()] ?? "neutral"
    }

    func setCategory(appName: String, category: String) -> Bool {
        guard ["productive", "distracting", "neutral"].contains(category) else {
            return false
        }
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }

        mapping[key] = category
        save()
        appLog.log(.info, category: "categories", "app recategorised", metadata: ["app": key, "category": category])
        return true
    }

    func knownApps() -> [String] {
        mapping.keys.sorted()
    }

    func categorise(_ appSeconds: [String: Double]) -> [String: Double] {
        var totals = ["productive": 0.0, "distracting": 0.0, "neutral": 0.0]
        for (app, secs) in appSeconds {
            let category = classify(app)
            totals[category, default: 0] += secs
        }
        return totals
    }

    private func load() {
        guard let data = try? Data(contentsOf: categoriesURL) else {
            save()
            return
        }

        guard let parsed = try? JSONDecoder().decode([String: String].self, from: data) else {
            appLog.log(.error, category: "categories", "failed to decode categories file")
            return
        }

        for (app, category) in parsed where ["productive", "distracting", "neutral"].contains(category) {
            self.mapping[app.lowercased()] = category
        }
        logger.info("categories loaded count=\(self.mapping.count, privacy: .public)")
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(mapping)
            try data.write(to: categoriesURL)
        } catch {
            appLog.log(.error, category: "categories", "failed to save categories", metadata: ["error": error.localizedDescription])
        }
    }
}
