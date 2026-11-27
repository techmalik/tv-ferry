<p align="center">
  <img src="assets/logo.svg" width="160" alt="TV Ferry logo: a file dropping into a TV, with a couch in front">
</p>

<h1 align="center">TV Ferry</h1>

<p align="center">
  <b>Drag movies from your Mac onto your Android TV.</b><br>
  A small, native macOS app that sends files straight to <i>File Manager+</i> on the TV, with nothing new to install on the TV.
</p>

<p align="center">
  <a href="https://github.com/techmalik/tv-ferry/actions/workflows/build.yml"><img src="https://github.com/techmalik/tv-ferry/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black.svg" alt="macOS 14+">
</p>

---

## Why

If you use **File Manager+** on an Android TV, its **Access from network** feature turns the TV into an FTP server. Phones can send files to it through the same app, but the Mac has no good way in: Finder opens FTP servers **read-only**, so you can't drop files onto the TV.

TV Ferry fills that gap. Drop a movie on the window and it lands on the TV.

## Features

- **Drag and drop:** drop files or whole folders on the window or the Dock icon, or use *Open With → TV Ferry* in Finder.
- **Resumes interrupted transfers:** if Wi-Fi drops halfway through a 4 GB movie, press Retry and it continues from where it stopped. It only resumes files it started sending itself, so a different file that happens to share the name is never appended to.
- **Spots videos the TV can't play:** some videos play fine on a Mac, but on the TV the picture freezes or goes black while the sound carries on. TV Ferry flags these before sending and offers **Convert & Send**, which makes a TV-friendly copy with macOS's own encoder. Your original isn't touched, and nothing extra needs installing.
- **Skips what's already there:** files already on the TV with the same size aren't sent again.
- **Checks every upload:** after each file, the size on the TV is compared with the Mac's copy. If the TV won't say, the file is marked as not checked rather than passed.
- **Find TV:** scans your Wi-Fi for the TV, so you don't have to look up its IP address.
- **Browse the TV:** pick the destination folder, or create a new one, without leaving the Mac.
- **Keeps the Mac awake** while a transfer is running, and shows live speed and time left.
- **Menu bar panel:** drop files and watch transfers from the menu bar (can be turned off).
- **Light, Dark or Match System** appearance, in **TV Ferry → Settings…** (⌘,).
- **No dependencies:** pure SwiftUI plus the system `curl`. The password is kept in the macOS Keychain.

### Two ways to connect

| | File Manager+ (FTP) | Network debugging (ADB) |
|---|---|---|
| On the TV each time | Open File Manager+ and press **Start service** | Nothing: works whenever the TV is on |
| One-time setup | Untick **Random password** | Turn on Developer options and **Network debugging**, then allow this Mac when the TV asks |
| Needs on the Mac | Nothing | Google's `adb` tool (TV Ferry offers to download it, or uses one from Homebrew / Android Studio) |
| Resume after a drop | Yes | No, the file is sent again |
| Security | Unencrypted FTP, password-protected | Anyone you allow can fully control the TV; use on your home Wi-Fi only |

### Mac ↔ Android file-system differences, handled

| Problem | What TV Ferry does |
|---|---|
| macOS often stores accented names decomposed (NFD); Android expects NFC | Converts names to NFC, so `Amélie.mkv` doesn't show up garbled or twice |
| Android's shared storage rejects `: * ? " < > \| \` (macOS allows most of them) | Replaces them with safe look-alikes, and flags renamed files in the list |
| macOS litters folders with `.DS_Store`, `._*` resource forks, Spotlight folders | Never sends them |
| Android names max out at 255 bytes | Shortens long names, keeping the extension |
| Videos made from images or exported by some editors use full-range "JPEG" colour, very high H.264 levels, 10-bit/4:2:2 H.264, or ProRes; Macs play them, TV chips often don't | Flags them and offers to convert to standard H.264 (High profile, level 4.1 for HD, TV colour range, a keyframe every 2 s). Colours stay as they look on the Mac. Turn on **TV Ferry → Convert Videos the TV May Not Play Without Asking** to skip the question |
| Files over 4 GB can't go onto a FAT32 USB drive plugged into the TV | Explains the failure, and suggests internal storage instead |

## Install

1. Download **TV-Ferry-X.Y.Z.dmg** (or the `.zip`) from [Releases](https://github.com/techmalik/tv-ferry/releases), and drag **TV Ferry** into Applications.
2. TV Ferry isn't notarized by Apple yet, so the first launch is blocked. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   Or run this once:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/TV Ferry.app"
   ```
3. When macOS asks to let TV Ferry find devices on your local network, click **Allow**.

Or [build it yourself](#build-from-source) in under a minute.

## Use

**On the TV**
1. Open **File Manager+ → Access from network**.
2. Untick **Random password**, so the password stays the same between sessions.
3. Press **Start service**.

**On the Mac**
1. Open TV Ferry. Enter the TV's IP address (or press **Find TV**), plus the port and password the TV shows. Click **Test Connection**, then **Save**.
2. Click **Change…** to choose where files go on the TV, for example `/Movies`.
3. Drop files or folders on the window.

> **Tip:** give the TV a fixed IP address in your router settings, so you only ever set this up once.

**Works with other FTP servers too.** File Manager+ is what TV Ferry was made for, but any FTP server (another Android app, a NAS, a Raspberry Pi) works the same way.

## Updates and feedback

- **Updates:** **TV Ferry → Check for Updates…** asks GitHub for the latest release. Turn on **Check for Updates Automatically** for a daily check. When there's a new version, TV Ferry offers to download it; quit TV Ferry and drag the new one into Applications. Your TV settings are kept.
- **Send Feedback…** (Help menu, or the speech-bubble button in the window) opens a small form. Type your message, optionally take or attach a screenshot, and press **Send**: it goes straight to the author's inbox.
- **Privacy:** no telemetry. TV Ferry only talks to your TV, plus two optional things: the feedback form, only when you press Send (sent over HTTPS via formsubmit.co), and the daily update check, if you turn it on (a plain request to GitHub's API, with nothing about you or your Mac).

## Troubleshooting

| Message | Fix |
|---|---|
| *Can't reach the TV* | Make sure **Start service** is running on the TV, and that the Mac and TV are on the same Wi-Fi. |
| *The TV refused the login* | Re-check the password. If the TV shows a username, enter it too; otherwise leave the username blank. |
| *The TV refused the upload* | The TV may be out of space, or you're sending a file over 4 GB to a FAT32 USB drive. |
| Picture freezes or goes black, sound keeps playing | The TV can't decode that video format. Send it again with **Convert & Send**. TV Ferry can check `.mp4`, `.m4v` and `.mov` files; for `.mkv` files, try VLC on the TV. |
| Find TV finds nothing | The service must be running on the TV. Also check System Settings → Privacy & Security → Local Network → TV Ferry is on. |

## Build from source

You need macOS 14 or later, and Xcode **or** just the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/techmalik/tv-ferry.git
cd tv-ferry
./build.sh               # → dist/TV Ferry.app
./scripts/e2e-test.sh    # runs real transfers against a throwaway local FTP server
./scripts/package.sh     # → dist/TV-Ferry-<version>.zip / .dmg + SHA256SUMS.txt
```

Pushing a tag like `v0.2.0` makes GitHub Actions test, build and publish a release, and the in-app update check picks it up.

`UNIVERSAL=1 ./build.sh` builds for both Apple Silicon and Intel; this needs full Xcode.

## Security

FTP is unencrypted. Use TV Ferry only on a home network you trust, and stop the service on the TV when you're done. See [SECURITY.md](SECURITY.md).

## Roadmap ideas

- Remember several TVs
- A "Send to TV Ferry" Finder action
- Recognise the TV automatically by name, once File Manager+ announces itself on the network
- Notarized builds

## Author

Made by **Malik Kabir**. Questions, feedback or ideas: [techmaleek@gmail.com](mailto:techmaleek@gmail.com), or use **Send Feedback…** in the app.

## Contributing

Pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Malik Kabir. TV Ferry is an independent project and isn't affiliated with File Manager+ or its developers.
