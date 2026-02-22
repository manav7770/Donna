import Foundation
import ServiceManagement
import os

final class LaunchAtLoginService {
    private let logger = Logger(subsystem: "DonnaSwift", category: "launchAtLogin")
    private let appLog = AppLog.shared
    private let label = "com.donna.DonnaMacApp"

    func isEnabled() -> Bool {
        if canUseSMAppService() {
            return SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        }

        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        if canUseSMAppService() {
            return setEnabledViaSMAppService(enabled)
        }

        return setEnabledViaLaunchAgent(enabled)
    }

    private func canUseSMAppService() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return !Bundle.main.bundleURL.path.contains("/.build/")
    }

    private func setEnabledViaSMAppService(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            let current = isEnabled()
            appLog.log(.info, category: "launchAtLogin", "updated via ServiceManagement", metadata: ["enabled": String(current)])
            return current == enabled || (enabled && SMAppService.mainApp.status == .requiresApproval)
        } catch {
            logger.error("ServiceManagement update failed: \(error.localizedDescription, privacy: .public)")
            appLog.log(.error, category: "launchAtLogin", "ServiceManagement update failed", metadata: ["error": error.localizedDescription, "requested": String(enabled)])
            // Fallback for development / unbundled runs.
            return setEnabledViaLaunchAgent(enabled)
        }
    }

    private func setEnabledViaLaunchAgent(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try installLaunchAgent()
                // Do not load immediately. Loading with RunAtLoad can spawn a second Donna process
                // in the current session. Saving the agent file is enough for next login.
            } else {
                _ = runLaunchctl(["unload", launchAgentURL.path])
                try? FileManager.default.removeItem(at: launchAgentURL)
            }

            let current = isEnabled()
            appLog.log(.info, category: "launchAtLogin", "updated via LaunchAgent", metadata: ["enabled": String(current)])
            return current == enabled
        } catch {
            logger.error("LaunchAgent update failed: \(error.localizedDescription, privacy: .public)")
            appLog.log(.error, category: "launchAtLogin", "LaunchAgent update failed", metadata: ["error": error.localizedDescription, "requested": String(enabled)])
            return false
        }
    }

    private var launchAgentURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private func installLaunchAgent() throws {
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let executable = resolvedExecutablePath()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func resolvedExecutablePath() -> String {
        if let bundleExec = Bundle.main.executableURL?.path,
           !bundleExec.contains("/.build/") {
            return bundleExec
        }

        if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
            return URL(fileURLWithPath: arg0).standardizedFileURL.path
        }

        return ProcessInfo.processInfo.arguments.first ?? ""
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            appLog.log(.error, category: "launchAtLogin", "launchctl failed", metadata: ["error": error.localizedDescription, "args": args.joined(separator: " ")])
            return false
        }
    }
}
