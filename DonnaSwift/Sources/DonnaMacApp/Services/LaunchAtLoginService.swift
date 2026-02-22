import Foundation

final class LaunchAtLoginService {
    private let appLog = AppLog.shared

    private let label = "com.donna.tracker.swift"
    private let plistURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.plistURL = dir.appendingPathComponent("com.donna.tracker.swift.plist")
    }

    func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? install() : uninstall()
    }

    private func install() -> Bool {
        guard let executable = resolvedExecutablePath() else {
            appLog.log(.error, category: "autostart", "cannot resolve executable path")
            return false
        }

        let workingDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let dataDir = resolvedDataDirectoryPath()

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "WorkingDirectory": workingDirectory,
            "StandardOutPath": (dataDir as NSString).appendingPathComponent("donna_stdout.log"),
            "StandardErrorPath": (dataDir as NSString).appendingPathComponent("donna_stderr.log")
        ]

        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)

            _ = runLaunchctl(["unload", "-w", plistURL.path])
            _ = runLaunchctl(["load", "-w", plistURL.path])
            appLog.log(.info, category: "autostart", "enabled", metadata: ["plist": plistURL.path, "executable": executable])
            return true
        } catch {
            appLog.log(.error, category: "autostart", "enable failed", metadata: ["error": error.localizedDescription])
            return false
        }
    }

    private func uninstall() -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return true
        }

        _ = runLaunchctl(["unload", "-w", plistURL.path])
        do {
            try FileManager.default.removeItem(at: plistURL)
            appLog.log(.info, category: "autostart", "disabled", metadata: ["plist": plistURL.path])
            return true
        } catch {
            appLog.log(.error, category: "autostart", "disable failed", metadata: ["error": error.localizedDescription])
            return false
        }
    }

    private func runLaunchctl(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            appLog.log(.error, category: "autostart", "launchctl failed", metadata: ["error": error.localizedDescription])
            return -1
        }
    }

    private func resolvedExecutablePath() -> String? {
        if let bundledExecutable = Bundle.main.executablePath,
           !bundledExecutable.contains("/.build/") {
            return bundledExecutable
        }

        // Fallback for swift run/debug environments.
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("DonnaSwift/.build/arm64-apple-macosx/debug/DonnaMacApp").path,
            URL(fileURLWithPath: cwd).appendingPathComponent(".build/arm64-apple-macosx/debug/DonnaMacApp").path,
            URL(fileURLWithPath: cwd).appendingPathComponent("DonnaSwift/.build/debug/DonnaMacApp").path,
            URL(fileURLWithPath: cwd).appendingPathComponent(".build/debug/DonnaMacApp").path
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func resolvedDataDirectoryPath() -> String {
        if let env = ProcessInfo.processInfo.environment["DONNA_DATA_DIR"], !env.isEmpty {
            return env
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let direct = cwd.appendingPathComponent("data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct.path
        }
        let parent = cwd.appendingPathComponent("../data", isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: parent.path) {
            return parent.path
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Donna/data", isDirectory: true).path
    }
}
