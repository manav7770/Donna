# Donna

A privacy-first macOS menu bar tracker focused on one question: **how much of your coding time is AI-assisted**.

The app tracks frontmost app usage, idle time, and AI-tool time for major AI surfaces (ChatGPT, Claude, Perplexity, GitHub Copilot web) using local-only processing and local storage in [data](data).

Core app code lives in [DonnaSwift](DonnaSwift), with orchestration in [DonnaSwift/Sources/DonnaMacApp/AppState.swift](DonnaSwift/Sources/DonnaMacApp/AppState.swift), tracking logic in [DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift](DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift), and persistence in [DonnaSwift/Sources/DonnaMacApp/Services/StorageService.swift](DonnaSwift/Sources/DonnaMacApp/Services/StorageService.swift).

## Interesting implementation techniques

- **Timer-driven sampling loop** for frontmost app and idle state in [DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift](DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift).
	If you’re coming from web runtimes, this is conceptually similar to [`setInterval()`](https://developer.mozilla.org/en-US/docs/Web/API/Window/setInterval).

- **OS-level idle detection** through Quartz event APIs instead of app-local input hooks.
	This gives a cleaner signal than UI event listeners and avoids invasive instrumentation.

- **Surface normalization for AI domains** (browser tab URL → canonical AI tool label) in [DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift](DonnaSwift/Sources/DonnaMacApp/Services/TrackingService.swift).
	Domain extraction maps well to URL parsing semantics like [`URL.hostname`](https://developer.mozilla.org/en-US/docs/Web/API/URL/hostname).

- **Structured daily persistence** via Codable JSON in [DonnaSwift/Sources/DonnaMacApp/Models/DailyRecord.swift](DonnaSwift/Sources/DonnaMacApp/Models/DailyRecord.swift) and [DonnaSwift/Sources/DonnaMacApp/Services/StorageService.swift](DonnaSwift/Sources/DonnaMacApp/Services/StorageService.swift).
	Format choice mirrors well-known [JSON](https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Scripting/JSON) workflows.

- **Menu-bar-first UX architecture** using SwiftUI scene composition in [DonnaSwift/Sources/DonnaMacApp/DonnaMacApp.swift](DonnaSwift/Sources/DonnaMacApp/DonnaMacApp.swift), with a single app coordinator (`AppState`) for predictable state transitions.

## Non-obvious technologies and libraries

- [SwiftUI](https://developer.apple.com/xcode/swiftui/) for menu bar scene composition.
- [AppKit](https://developer.apple.com/documentation/appkit) for macOS-native alerts and status-bar behavior.
- [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz_event_services) for idle-time detection.
- [NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript) for active browser tab URL introspection.
- [os.Logger](https://developer.apple.com/documentation/os/logger) for structured system logging.
- [Swift Package Manager](https://www.swift.org/package-manager/) for build/dependency workflow.

### Fonts and UI assets

- No external font package is bundled.
- UI uses macOS system typography (San Francisco family) and system symbols where available.
	References: [SF Symbols](https://developer.apple.com/sf-symbols/), [Apple Fonts](https://developer.apple.com/fonts/).

## Project structure

```text
Donna/
├── CONTRIBUTING.md
├── DESIGN.md
├── LICENSE
├── README.md
├── prompt.md
├── DonnaSwift/
│   ├── .build/
│   └── Sources/
│       └── DonnaMacApp/
│           ├── Models/
│           └── Services/
└── data/
		└── logs/
```

- [DonnaSwift](DonnaSwift): Swift package root and app source.
- [DonnaSwift/Sources/DonnaMacApp](DonnaSwift/Sources/DonnaMacApp): app entrypoint and app state layer.
- [DonnaSwift/Sources/DonnaMacApp/Models](DonnaSwift/Sources/DonnaMacApp/Models): persistence model types.
- [DonnaSwift/Sources/DonnaMacApp/Services](DonnaSwift/Sources/DonnaMacApp/Services): tracking, storage, and logging services.
- [data](data): local runtime records (intentionally local-first).
- [data/logs](data/logs): runtime logs.

## Release focus

This release is intentionally narrow: reliable tracking + clear daily AI leverage summary.
No cloud sync, no remote analytics, no prompt/content collection.
