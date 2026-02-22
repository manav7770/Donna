import AppKit
import Foundation
import Quartz
import IOKit
import os


@MainActor
final class TrackingService: ObservableObject {
    private let logger = Logger(subsystem: "DonnaSwift", category: "tracking")
    private let appLog = AppLog.shared

    @Published private(set) var record: DailyRecord = DailyRecord()
    @Published private(set) var currentApp: String = "—"
    @Published private(set) var debugIdleSeconds: TimeInterval = 0

    var pollInterval: TimeInterval = 30
    var idleThreshold: TimeInterval = 300

    private var timer: Timer?
    private var lastTick: Date?
    private var lastInputDate = Date()
    private var eventMonitors: [Any] = []
    
    // Cache for AI extension process detection (avoid running ps aux repeatedly)
    private var aiProcessCache: String?
    private var aiProcessCacheTime: Date?
    private let aiProcessCacheDuration: TimeInterval = 10  // Cache for 10 seconds

    func start() {
        guard timer == nil else { return }
        lastInputDate = Date()
        startEventMonitors()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        logger.info("tracking started")
        appLog.log(.info, category: "tracking", "tracking started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopEventMonitors()
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

        let idleSeconds = currentIdleSeconds()
        debugIdleSeconds = idleSeconds

        if idleSeconds >= idleThreshold {
            record.addIdle(seconds: elapsed)
            currentApp = "—"
        } else {
            let surface = frontmostSurface()
            record.addActive(app: surface, seconds: elapsed)
            currentApp = surface
            
            // Debug: log when we detect AI tools
            if surface.contains("Copilot") || surface.contains("ChatGPT") || surface.contains("Claude") {
                logger.info("🤖 AI detected: \(surface, privacy: .public)")
            }
        }
    }

    private func currentIdleSeconds() -> TimeInterval {
        var candidates: [TimeInterval] = []

        // 1. IOKit HIDIdleTime — hardware-level, most reliable with external peripherals
        if let io = ioKitIdleSeconds() {
            candidates.append(io)
        }

        // 2. CGEventSource — Quartz-level
        let combined = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
        for v in [combined, hid] where v >= 0 && !v.isNaN && !v.isInfinite && v <= 86_400 {
            candidates.append(v)
        }

        // 3. NSEvent monitor — Cocoa-level
        candidates.append(Date().timeIntervalSince(lastInputDate))

        return candidates.min() ?? 0
    }

    // MARK: - IOKit idle

    private func ioKitIdleSeconds() -> TimeInterval? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        let entry = IOIteratorNext(iter)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }

        guard let dict = unmanagedDict?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let nanos: Int64
        if let n = dict["HIDIdleTime"] as? Int64 {
            nanos = n
        } else if let n = (dict["HIDIdleTime"] as? NSNumber)?.int64Value {
            nanos = n
        } else {
            return nil
        }

        return TimeInterval(nanos) / 1_000_000_000.0
    }

    // MARK: - NSEvent monitors

    private func startEventMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .scrollWheel, .keyDown, .leftMouseDragged, .rightMouseDragged
        ]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.lastInputDate = Date() }
        }) {
            eventMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.lastInputDate = Date() }
            return event
        }) {
            eventMonitors.append(m)
        }
    }

    private func stopEventMonitors() {
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors = []
    }

    private func frontmostApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func frontmostSurface() -> String {
        let appName = frontmostApp() ?? "Unknown"

        // Check browser tabs for AI tool domains
        if let domain = frontmostBrowserDomain(appName: appName),
           let aiTool = aiToolName(forDomain: domain) {
            return "\(appName) (\(aiTool))"
        }

        // Check if IDE has Copilot/AI assistant active via window title
        if let aiLabel = aiAssistedIDE(appName: appName) {
            return aiLabel
        }

        return appName
    }

    /// Detects if the frontmost IDE window shows an AI assistant (Copilot, Cody, etc.)
    /// Checks window title first, then checks for running AI assistant processes.
    private func aiAssistedIDE(appName: String) -> String? {
        let ideApps: Set<String> = [
            "Code", "Visual Studio Code", "Cursor", "Windsurf",
            "Xcode", "IntelliJ IDEA", "PyCharm", "WebStorm",
            "CLion", "GoLand", "Rider", "Fleet", "Zed", "Nova"
        ]
        guard ideApps.contains(appName) else { return nil }

        // 1. Quick check: window title (catches some IDEs/setups)
        if let title = frontmostWindowTitle() {
            if let match = matchAIAssistant(title) { return "\(match) (\(appName))" }
        }

        // 2. Check for AI assistant extension processes
        // VS Code Copilot runs as extension processes that we can detect
        if let match = detectAIExtensionProcess(for: appName) {
            return "\(match) (\(appName))"
        }

        // 3. Deep check: scan the AX tree for AI panel/tab elements
        // (This works for some IDEs but not Electron-based ones like VS Code)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                if let match = findAIAssistantInAXTree(window, depth: 0) {
                    return "\(match) (\(appName))"
                }
            }
        }

        return nil
    }
    
    /// Detects AI assistant extension processes (for Electron-based IDEs like VS Code)
    private func detectAIExtensionProcess(for appName: String) -> String? {
        // Return cached result if still fresh
        if let cacheTime = aiProcessCacheTime,
           Date().timeIntervalSince(cacheTime) < aiProcessCacheDuration {
            return aiProcessCache
        }
        
        // Run detection in background to avoid blocking
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["aux"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            
            // Use a timeout to avoid blocking too long
            let deadline = Date().addingTimeInterval(0.5)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            if task.isRunning {
                task.terminate()
                return aiProcessCache  // Return old cache if ps is slow
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return aiProcessCache
            }
            
            let lines = output.components(separatedBy: "\n")
            var result: String? = nil
            
            // Check for Copilot extension processes
            if lines.contains(where: { $0.contains("copilot") && !$0.contains("grep") }) {
                result = "GitHub Copilot"
            }
            // Check for other AI assistants
            else if lines.contains(where: { $0.contains("cody") && !$0.contains("grep") }) {
                result = "Sourcegraph Cody"
            }
            else if lines.contains(where: { ($0.contains("codewhisperer") || $0.contains("amazon-q")) && !$0.contains("grep") }) {
                result = "Amazon Q"
            }
            else if lines.contains(where: { $0.contains("tabnine") && !$0.contains("grep") }) {
                result = "Tabnine"
            }
            
            // Update cache
            aiProcessCache = result
            aiProcessCacheTime = Date()
            
            return result
        } catch {
            return aiProcessCache  // Return old cache on error
        }
    }

    /// Matches a string against known AI assistant keywords.
    private func matchAIAssistant(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("copilot")      { return "GitHub Copilot" }
        if lower.contains("cody")         { return "Sourcegraph Cody" }
        if lower.contains("codewhisperer") || lower.contains("amazon q") { return "Amazon Q" }
        if lower.contains("tabnine")      { return "Tabnine" }
        return nil
    }

    /// Scans the AX tree of an IDE window for AI assistant panels/tabs.
    /// Searches multiple attributes across all UI elements.
    private func findAIAssistantInAXTree(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }  // Increased depth for deeper nesting

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        // Skip web content and scroll areas — we only want chrome UI
        if role == "AXWebArea" || role == "AXScrollArea" { return nil }

        // Check ALL text attributes for AI keywords
        let textAttributes: [String] = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            "AXLabel",
            "AXIdentifier", 
            kAXValueAttribute as String,
            kAXHelpAttribute as String
        ]
        
        for attr in textAttributes {
            var attrValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &attrValue) == .success,
               let text = attrValue as? String, !text.isEmpty {
                if let match = matchAIAssistant(text) { 
                    return match 
                }
            }
        }

        // Recurse into children
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let match = findAIAssistantInAXTree(child, depth: depth + 1) {
                return match
            }
        }

        return nil
    }

    /// Gets the title of the frontmost window via Accessibility API, with CGWindowList fallback
    private func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = app.processIdentifier

        // 1. Try Accessibility API
        let axApp = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let winResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        if winResult == .success {
            var titleValue: AnyObject?
            let titleResult = AXUIElementCopyAttributeValue(value as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
            if titleResult == .success, let title = titleValue as? String, !title.isEmpty {
                return title
            }
        } else {
        }

        // 2. Fallback: CGWindowList (works if Screen Recording is allowed)
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                if let ownerPID = w[kCGWindowOwnerPID as String] as? Int32,
                   ownerPID == pid,
                   let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                   let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                    return name
                }
            }
        }

        return nil
    }

    /// Known browsers that support AppleScript URL introspection
    private static let appleScriptBrowsers: Set<String> = [
        "Safari", "Google Chrome", "Arc", "Brave Browser",
        "Microsoft Edge", "Chromium", "Opera"
    ]

    /// All recognized browser app names (AppleScript + non-AppleScript)
    private static let allBrowsers: Set<String> = appleScriptBrowsers.union([
        "Firefox", "Orion", "Vivaldi", "Zen Browser"
    ])

    private func frontmostBrowserDomain(appName: String) -> String? {
        guard Self.allBrowsers.contains(appName) else { return nil }

        // 1. Try AppleScript URL introspection (most accurate, needs Automation permission)
        if Self.appleScriptBrowsers.contains(appName) {
            let script: String
            if appName == "Safari" {
                script = "tell application \"Safari\" to if (count of windows) > 0 then return URL of current tab of front window"
            } else {
                script = "tell application \"\(appName)\" to if (count of windows) > 0 then return URL of active tab of front window"
            }
            if let raw = runAppleScript(script),
               let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               var host = url.host?.lowercased() {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                return host
            }
        }

        // 2. Read URL from the browser's address bar via Accessibility API
        //    Only needs Accessibility permission — works without Automation
        if let app = NSWorkspace.shared.frontmostApplication {
            if let urlString = browserURLViaAccessibility(pid: app.processIdentifier),
               let url = URL(string: urlString),
               var host = url.host?.lowercased() {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                return host
            }
        }

        // 3. Fallback: window title keyword matching
        if let title = frontmostWindowTitle() {
            let domain = aiDomainFromWindowTitle(title)
            return domain
        }

        return nil
    }

    /// Reads the current URL from a browser's address bar via the Accessibility API.
    /// Searches the toolbar area for text fields containing URL-like text.
    /// Skips web content areas to keep traversal fast.
    private func browserURLViaAccessibility(pid: Int32) -> String? {
        let axApp = AXUIElementCreateApplication(pid)

        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }

        let result = findURLFieldInElement(windowValue as! AXUIElement, depth: 0)
        if result == nil {
        }
        return result
    }

    /// Recursively searches AX tree for a text field containing a URL.
    /// Skips web content areas (AXWebArea, AXScrollArea) to avoid traversing page DOM.
    private func findURLFieldInElement(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        // Skip web content areas — only search toolbar/chrome UI
        if role == "AXWebArea" || role == "AXScrollArea" { return nil }

        // Check text fields for URL-like content (the omnibox / address bar)
        if role == "AXTextField" || role == "AXComboBox" {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty,
               text.contains("."), !text.contains(" ") {
                let url = text.hasPrefix("http") ? text : "https://\(text)"
                return url
            }
        }

        // Recurse into children
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let url = findURLFieldInElement(child, depth: depth + 1) {
                return url
            }
        }

        return nil
    }

    /// Matches browser window titles to known AI tool domains.
    /// Browser titles are typically "Page Title - Browser Name" or just "Page Title".
    private func aiDomainFromWindowTitle(_ title: String) -> String? {
        let lower = title.lowercased()

        if lower.contains("chatgpt")                       { return "chatgpt.com" }
        if lower.contains("claude")                         { return "claude.ai" }
        if lower.contains("perplexity")                     { return "perplexity.ai" }
        if lower.contains("gemini")                         { return "gemini.google.com" }
        if lower.contains("copilot")                        { return "copilot.microsoft.com" }
        if lower.contains("grok")                           { return "grok.x.ai" }
        if lower.contains("hugging") || lower.contains("huggingchat") { return "huggingface.co" }
        if lower.contains("mistral")                        { return "chat.mistral.ai" }
        if lower.contains("poe.com") || (lower.contains("poe") && lower.contains("ai")) { return "poe.com" }
        if lower.contains("deepseek")                       { return "chat.deepseek.com" }
        if lower.contains("phind")                          { return "phind.com" }
        if lower.contains("you.com")                        { return "you.com" }
        if lower.contains("replit")                         { return "replit.com" }
        if lower.contains("v0.dev") || lower.contains("v0 by vercel") { return "v0.dev" }
        if lower.contains("codeium")                        { return "codeium.com" }
        if lower.contains("cursor")                         { return "cursor.com" }

        return nil
    }

    private func aiToolName(forDomain domain: String) -> String? {
        // OpenAI / ChatGPT
        if domain == "chatgpt.com" || domain.hasSuffix(".chatgpt.com") { return "ChatGPT" }
        if domain == "chat.openai.com" || domain.hasSuffix(".openai.com") { return "ChatGPT" }

        // Anthropic / Claude
        if domain == "claude.ai" || domain.hasSuffix(".claude.ai") { return "Claude" }
        if domain == "anthropic.com" || domain.hasSuffix(".anthropic.com") { return "Claude" }

        // Google Gemini
        if domain == "gemini.google.com" || domain == "bard.google.com" { return "Gemini" }
        if domain == "aistudio.google.com" { return "Gemini" }

        // Perplexity
        if domain == "perplexity.ai" || domain.hasSuffix(".perplexity.ai") { return "Perplexity" }

        // Microsoft Copilot
        if domain == "copilot.microsoft.com" || domain.hasSuffix(".copilot.microsoft.com") { return "Microsoft Copilot" }
        if domain == "github.com" {
            // GitHub Copilot chat lives at github.com/copilot
            return nil // can't distinguish from regular GitHub without path
        }

        // Grok (xAI)
        if domain == "grok.x.ai" || domain.hasSuffix(".x.ai") { return "Grok" }

        // Mistral
        if domain == "chat.mistral.ai" || domain == "mistral.ai" || domain.hasSuffix(".mistral.ai") { return "Mistral" }

        // HuggingChat
        if domain == "huggingface.co" { return "HuggingChat" }

        // Poe
        if domain == "poe.com" || domain.hasSuffix(".poe.com") { return "Poe" }

        // Cursor (web)
        if domain == "cursor.com" || domain.hasSuffix(".cursor.com") { return "Cursor" }

        // Phind
        if domain == "phind.com" || domain.hasSuffix(".phind.com") { return "Phind" }

        // You.com
        if domain == "you.com" || domain.hasSuffix(".you.com") { return "You.com" }

        // Replit AI
        if domain == "replit.com" || domain.hasSuffix(".replit.com") { return "Replit AI" }

        // v0 by Vercel
        if domain == "v0.dev" || domain.hasSuffix(".v0.dev") { return "v0" }

        // DeepSeek
        if domain == "chat.deepseek.com" || domain == "deepseek.com" || domain.hasSuffix(".deepseek.com") { return "DeepSeek" }

        // Codeium / Windsurf web
        if domain == "codeium.com" || domain.hasSuffix(".codeium.com") { return "Codeium" }

        return nil
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let output = script?.executeAndReturnError(&error)
        if let error {
            appLog.log(.debug, category: "tracking", "applescript error", metadata: ["error": error.description])
        }
        return output?.stringValue
    }
}
