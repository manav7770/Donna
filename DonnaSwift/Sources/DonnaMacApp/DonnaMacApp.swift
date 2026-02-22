import SwiftUI
import AppKit

@main
struct DonnaMacApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra(state.menuTitle, systemImage: "timer") {
            Button(state.trackingEnabled ? "Pause Tracking" : "Start Tracking") {
                if state.trackingEnabled {
                    state.stopTracking()
                } else {
                    state.startAll()
                }
            }

            Button("Reset Today") {
                confirmResetToday()
            }

            Divider()

            Button("Today's Summary") {
                showSummaryAlert()
            }

            Button("Weekly Trends") {
                showWeeklyTrendsAlert()
            }

            Button("Export CSV") {
                exportCSV()
            }

            Button("Set Goal") {
                showGoalPrompt()
            }

            Button("Categorise App…") {
                showCategoriseAppPrompt()
            }

            Button(state.launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                toggleLaunchAtLogin()
            }

            Divider()

            Text(state.presenceStatusText)

            Button(state.presenceEnabled ? "Disable Camera Presence" : "Enable Camera Presence") {
                state.togglePresence()
            }

            Divider()

            Button("Save Now") {
                state.saveNow()
            }

            Button("Quit") {
                state.shutdown()
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func showSummaryAlert() {
        let alert = NSAlert()
        alert.messageText = "Today's Summary"
        alert.informativeText = state.summaryText()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showGoalPrompt() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set Daily Goal (hours)"
        alert.informativeText = "Enter a positive number of hours."

        let input = NSTextField(string: String(format: "%.1f", state.goals.goalHours))
        input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        input.focusRingType = .exterior
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            alert.window.makeKey()
            alert.window.makeFirstResponder(input)
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let value = Double(input.stringValue),
           value > 0 {
            state.setGoal(hours: value)
        }
    }

    private func showWeeklyTrendsAlert() {
        let alert = NSAlert()
        alert.messageText = "Weekly Trends"
        alert.informativeText = state.weeklyTrendsText()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func exportCSV() {
        let alert = NSAlert()
        if let path = state.exportTodayCSV() {
            alert.messageText = "CSV Exported"
            alert.informativeText = "Saved to:\n\(path.path)"
        } else {
            alert.messageText = "CSV Export Failed"
            alert.informativeText = "Could not write CSV. Check permissions and logs."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCategoriseAppPrompt() {
        let alert = NSAlert()
        alert.messageText = "Categorise App"
        alert.informativeText = "Set app category for tracking."

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        let appField = NSTextField(string: state.tracking.currentApp == "—" ? "" : state.tracking.currentApp)
        appField.placeholderString = "App name (e.g. Safari)"
        appField.frame = NSRect(x: 0, y: 34, width: 320, height: 24)
        appField.isEditable = true
        appField.isSelectable = true
        appField.focusRingType = .exterior

        let categoryPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        categoryPicker.addItems(withTitles: ["productive", "distracting", "neutral"])
        categoryPicker.selectItem(withTitle: "neutral")

        container.addSubview(appField)
        container.addSubview(categoryPicker)
        alert.accessoryView = container
        alert.window.initialFirstResponder = appField

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            alert.window.makeKey()
            alert.window.makeFirstResponder(appField)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let appName = appField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = categoryPicker.selectedItem?.title ?? "neutral"
        let ok = state.recategorise(appName: appName, category: category)

        let result = NSAlert()
        result.messageText = ok ? "Category Updated" : "Update Failed"
        result.informativeText = ok
            ? "\(appName) is now \(category)."
            : "Provide a valid app name and category."
        result.addButton(withTitle: "OK")
        result.runModal()
    }

    private func toggleLaunchAtLogin() {
        let requested = !state.launchAtLoginEnabled
        let ok = state.setLaunchAtLogin(requested)

        let alert = NSAlert()
        alert.messageText = ok ? "Launch at Login Updated" : "Launch at Login Failed"
        alert.informativeText = ok
            ? (state.launchAtLoginEnabled ? "Donna will start when you log in." : "Donna will not start at login.")
            : "Could not change login launch setting. Check logs for details."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func confirmResetToday() {
        let alert = NSAlert()
        alert.messageText = "Reset Today?"
        alert.informativeText = "This clears today's active/idle/away and per-app totals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            state.resetToday()
        }
    }
}
