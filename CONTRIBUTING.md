# Contributing to Donna

Thanks for contributing.

## Development setup

1. Install Xcode Command Line Tools.
2. Build from repo root:
   - `swift build --package-path DonnaSwift`
3. Run the app:
   - `swift run --package-path DonnaSwift DonnaMacApp`

## Code guidelines

- Keep changes focused and small.
- Preserve existing architecture (`AppState` + services).
- Add/update docs when behavior changes.
- Keep local runtime data out of commits (`data/*.json`, `data/logs/*`).

## Pull request checklist

- [ ] Build passes (`swift build --package-path DonnaSwift`)
- [ ] Behavior tested manually from menu bar
- [ ] README updated if user-facing behavior changed
- [ ] No personal data/logs committed
