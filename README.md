# Donna – macOS Menu Bar Productivity Tracker (Swift)

Donna is a privacy-first macOS menu bar app that tracks app usage, idle time, away-from-desk time (camera presence), goals, and trends — all stored locally.

## Current Status

- Primary app: Swift (in [DonnaSwift](DonnaSwift))
- Local storage: JSON in [data](data)
- Logging: structured JSON logs in [data/logs/donna.log](data/logs/donna.log)
- Browser extension tracking: removed

## Features

- Frontmost app tracking (active time)
- Idle detection
- Camera-based presence detection (away time)
- Daily productive-time goals
- Daily summary popup
- Weekly trends dashboard popup
- CSV export for today
- Per-app category overrides (productive/distracting/neutral)
- Launch at Login toggle (LaunchAgent)
- Auto-save + manual save
- Structured logging

## Project Structure

```
Donna/
├── DonnaSwift/
│   ├── Package.swift
│   └── Sources/DonnaMacApp/
│       ├── DonnaMacApp.swift
│       ├── AppState.swift
│       ├── Models/
│       │   └── DailyRecord.swift
│       └── Services/
│           ├── AppLog.swift
│           ├── CategoryService.swift
│           ├── GoalService.swift
│           ├── LaunchAtLoginService.swift
│           ├── PresenceService.swift
│           ├── StorageService.swift
│           ├── TrackingService.swift
│           └── TrendsService.swift
├── data/
│   ├── YYYY-MM-DD.json
│   ├── goals.json
│   ├── categories.json
│   └── logs/
│       └── donna.log
└── README.md
```

## Run

From repo root:

```bash
swift run --package-path DonnaSwift DonnaMacApp
```

Or from [DonnaSwift](DonnaSwift):

```bash
swift run DonnaMacApp
```

## Menu Actions

- Start/Pause Tracking
- Reset Today
- Today's Summary
- Weekly Trends
- Export CSV
- Set Goal
- Categorise App…
- Enable/Disable Launch at Login
- Enable/Disable Camera Presence
- Save Now
- Quit

## Data Files

- Daily records: [data](data)/YYYY-MM-DD.json
- Goals: [data/goals.json](data/goals.json)
- Category overrides: [data/categories.json](data/categories.json)
- Logs: [data/logs/donna.log](data/logs/donna.log)

## Privacy

- Data stays local.
- No external server sync.
- Camera is only used for local face-presence detection.
- Website/domain tracking via extension is not part of the current app.

## Notes

- Running via `swift run` is unbundled; some macOS notification/login-item behavior can vary from a signed .app build.
- Legacy Python files were removed; this repository now contains only the active Swift app path.
