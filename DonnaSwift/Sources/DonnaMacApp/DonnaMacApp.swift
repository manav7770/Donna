import SwiftUI
import AppKit

@main
struct DonnaMacApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
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
                showSummaryWindow()
            }

            Button(state.launchAtLoginEnabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                toggleLaunchAtLogin()
            }

            Divider()

            Button("Quit Donna") {
                state.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if let icon = state.frontmostAppIcon {
                Image(nsImage: icon)
            }
            Text(state.menuTitle)
        }
        .menuBarExtraStyle(.menu)
    }

    private func showSummaryWindow() {
        SummaryWindowController.shared.show(data: state.summaryData())
    }

    private func confirmResetToday() {
        let alert = NSAlert()
        alert.messageText = "Reset Today?"
        alert.informativeText = "This clears today's active/idle and per-app totals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            state.resetToday()
        }
    }

    private func toggleLaunchAtLogin() {
        let requested = !state.launchAtLoginEnabled
        let ok = state.setLaunchAtLogin(requested)

        let alert = NSAlert()
        alert.alertStyle = ok ? .informational : .warning

        if ok {
            if state.launchAtLoginEnabled {
                alert.messageText = "Launch at Login Enabled"
                alert.informativeText = "Donna will launch automatically when you sign in to macOS."
            } else {
                alert.messageText = "Launch at Login Disabled"
                alert.informativeText = "Donna will no longer launch automatically when you sign in to macOS."
            }
            alert.addButton(withTitle: "Done")
            alert.runModal()
            return
        }

        alert.messageText = "Couldn’t Update Launch at Login"
        alert.informativeText = "Donna couldn’t update Login Items from this run. You can change this in System Settings > General > Login Items."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Done")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Summary Window Controller

final class SummaryWindowController: NSWindowController {
    static let shared = SummaryWindowController()

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Today's Summary"
        w.isReleasedWhenClosed = false
        super.init(window: w)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(data: AppState.SummaryData) {
        let view = SummaryView(data: data)
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = NSSize(width: 400, height: 480)
        window?.contentView = hosting
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Summary SwiftUI View

struct SummaryView: View {
    let data: AppState.SummaryData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Donna")
                        .font(.system(size: 22, weight: .bold))
                    Text(formattedDate(data.date))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(data.activeTime)
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                    Text("active")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Stats Grid
            HStack(spacing: 10) {
                StatCard(label: "IDE", value: data.ideTime, icon: "chevron.left.forwardslash.chevron.right")
                StatCard(label: "AI Tools", value: data.aiTime, icon: "cpu")
                StatCard(label: "AI %", value: "\(data.aiPercent)%", icon: "chart.bar.fill")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Top Apps
            VStack(alignment: .leading, spacing: 10) {
                Text("TOP APPS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .kerning(0.5)

                if data.topApps.isEmpty {
                    Text("No tracked apps yet")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(data.topApps.enumerated()), id: \.offset) { _, app in
                            AppRow(name: app.name, time: app.time, fraction: app.fraction)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Spacer()
        }
        .frame(width: 400, height: 480)
    }

    private func formattedDate(_ iso: String) -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withFullDate]
        guard let date = isoFmt.date(from: iso) else { return iso }
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        return fmt.string(from: date)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}

struct AppRow: View {
    let name: String
    let time: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(time)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: max(CGFloat(fraction) * geo.size.width, 4))
                }
            }
            .frame(height: 6)
        }
    }
}
