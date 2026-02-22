#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Quick script to dump VS Code's AX tree structure
func dumpElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 8) {
    guard depth < maxDepth else { return }
    let indent = String(repeating: "  ", count: depth)
    
    var roleValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
    let role = (roleValue as? String) ?? "?"
    
    var titleValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
    let title = (titleValue as? String) ?? ""
    
    var descValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
    let desc = (descValue as? String) ?? ""
    
    var valueValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueValue)
    let value = (valueValue as? String) ?? ""
    
    let info = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
    
    if info.lowercased().contains("copilot") || !info.isEmpty {
        print("\(indent)[\(role)] \(info)")
    }
    
    var childrenValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
          let children = childrenValue as? [AXUIElement] else {
        return
    }
    
    for child in children {
        dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

// Find VS Code
let apps = NSWorkspace.shared.runningApplications
if let vscode = apps.first(where: { $0.localizedName == "Code" || $0.localizedName == "Visual Studio Code" }) {
    print("Found: \(vscode.localizedName ?? "?") (PID: \(vscode.processIdentifier))")
    let axApp = AXUIElementCreateApplication(vscode.processIdentifier)
    
    var windowsValue: AnyObject?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
       let windows = windowsValue as? [AXUIElement] {
        print("\n=== Found \(windows.count) windows ===\n")
        for (i, window) in windows.enumerated() {
            print("Window \(i + 1):")
            dumpElement(window, maxDepth: 10)
            print()
        }
    }
} else {
    print("VS Code not running")
}
