# Changelog

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
