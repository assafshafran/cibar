# Contributing to CIBar

Thanks for helping. CIBar is a small native SwiftUI app with no dependencies beyond macOS, and it should stay that way.

## Build and run

```bash
swift build                          # compile
./scripts/build-app.sh --install     # bundle, sign, install to ~/Applications and launch
~/Applications/CIBar.app/Contents/MacOS/CIBar --dump                     # print what each source returns
~/Applications/CIBar.app/Contents/MacOS/CIBar --render-glyphs icons.png  # every menu bar icon state on one sheet
```

## Where things are

| File | What it does |
|---|---|
| `Sources/CIBar/Models.swift` | `BuildState`, `BuildRun`, `Source` (one watched pipeline or repo) and URL parsing |
| `Sources/CIBar/Providers.swift` | API clients: Azure DevOps, GitHub Actions, GitHub commit statuses |
| `Sources/CIBar/Monitor.swift` | Polling, change detection, notifications, menu bar icon drawing |
| `Sources/CIBar/MenuContent.swift` | The popover |
| `Sources/CIBar/SettingsView.swift` | Settings window, token fields, repository picker |
| `Sources/CIBar/Settings.swift` | Stored settings and the token file |

## Adding a provider

1. Add a case to `Provider` in `Models.swift`, any fields it needs to `Source`, and teach `Source.from(urlString:)` to recognise its URLs.
2. Add an `enum YourProvider` in `Providers.swift` with `static func fetch(_ s: Source, token: String, top: Int) async throws -> [BuildRun]`. Map the provider's statuses onto `BuildState`, and throw `ProviderError` with a message a person can act on (for example "token rejected" or "project not found").
3. Route it in `Providers.fetch`, and add its fields and token to `SettingsView`.
4. Check it with `--dump` against a real project.

## Pull requests

- Keep them focused, and describe what a user sees change.
- Run `swift build` with no warnings.
- UI changes: include a screenshot of the menu or Settings.
- Never commit tokens, organization names or other private data in code, tests or screenshots.
