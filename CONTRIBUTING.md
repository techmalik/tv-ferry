# Contributing to TV Ferry

Thanks for helping! Bug reports, fixes and ideas are all welcome. You can also reach the author, Malik Kabir, at techmaleek@gmail.com.

## Getting set up
- macOS 14 or later.
- Xcode **or** just the Command Line Tools (`xcode-select --install`).
- `./build.sh` builds `dist/TV Ferry.app`.
- `./scripts/e2e-test.sh` starts a throwaway local FTP server and pushes real files through the app's transfer queue. Please run it before opening a pull request; CI runs it too.

## Code layout
| File | What it does |
|---|---|
| `FTPClient.swift` | Talks FTP by driving the system `curl` (listing, size checks, uploads with progress). |
| `TransferQueue.swift` | The upload queue: folder expansion, resume, skip-existing, verification. |
| `NameSanitizer.swift` | Makes macOS file names safe for Android storage. |
| `NetworkScanner.swift` | "Find TV": probes the local /24 subnet for an FTP greeting. |
| `ContentView.swift`, `ConnectionSheet.swift`, `RemoteBrowser.swift` | SwiftUI interface. |
| `Feedback.swift`, `AboutWindow.swift` | In-app feedback form (emails the author via formsubmit.co) and About window. |
| `Updates.swift`, `AppInfo.swift` | GitHub release update check; app name, author, links. |
| `LocalState.swift` | Stand-in for `@State`, so the app builds without full Xcode. |

## Releasing
Bump `CHANGELOG.md`, then push a tag (`git tag v0.2.0 && git push --tags`). The Build workflow tests, packages a universal `.dmg` and `.zip`, and publishes the GitHub release that the in-app update check reads.

## Guidelines
- Keep it dependency-free (system frameworks + `/usr/bin/curl`).
- Never put the password on a command line; it goes to curl on stdin.
- Keep pull requests focused, and describe how you tested.
