# Changelog

## 0.3.0
- **New look:** a sidebar with the TV and your recent Send-to folders, and the queue as a table with clear status for each file. The TV can now have a name.
- **Menu bar panel:** drop files and watch transfers from the menu bar, without opening the window. Turn it off in Settings.
- **Settings window** (⌘,): Light, Dark or Match System appearance, the menu bar panel, transfer options and update checks.
- Redesigned About window.
- **Network debugging (ADB):** a second way to connect. Turn on Network debugging on the TV once, allow this Mac, and TV Ferry can send files whenever the TV is on: no app has to be open on the TV. Pick it in **Connection…**. TV Ferry uses Google's adb tool: one already on the Mac (Homebrew, Android Studio), or a copy it downloads from Google when you click **Download adb**. Files go to the TV's internal storage; ADB transfers always send the whole file (no resume).
- Resume is now safe: TV Ferry only continues a partial file it started sending from the same, unchanged Mac file. A smaller file that just has the same name on the TV (an older copy, a different movie) is replaced from the start instead of having the rest appended to it.
- A converted copy that was interrupted now resumes too, as long as that converted copy still exists.
- The post-upload size check now asks the TV in UTF-8 like every other request, so accented names are checked properly. If the TV won't report a size, the file shows "Sent · …wasn't checked" in orange instead of a plain "Sent".

## 0.2.0
- Spots videos the TV probably can't play (full-range colour, H.264 levels above 4.2 at HD, 10-bit/4:2:2/4:4:4 H.264, ProRes and other non-TV codecs) and offers **Convert & Send** or **Send As Is**.
- Conversion uses macOS's own encoder: H.264 High (level 4.1 for HD), TV colour range, BT.709, a keyframe every 2 s, audio kept. Colours match what the Mac shows.
- New menu option: convert such videos without asking. **Convert All** button when several need a decision.
- Converted copies are always sent from the start (never "resumed" onto an older copy), and are deleted once sent.

## 0.1.0
- First release: drag-and-drop uploads from macOS to File Manager+ on Android TV over FTP.
- Android-safe file names (NFC normalisation, forbidden characters), macOS junk filtering.
- Resume interrupted transfers, skip files already on the TV, post-upload size check.
- Find TV on the local network, browse and create folders on the TV.
- About window, in-app feedback form (with screenshots), and GitHub update check.
