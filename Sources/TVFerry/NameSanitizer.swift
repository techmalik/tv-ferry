import Foundation

/// Bridges the gap between macOS (APFS) and Android (ext4/F2FS behind the FUSE "shared storage" layer).
enum NameSanitizer {
    /// macOS-only metadata that is useless (and clutter) on Android.
    private static let junkNames: Set<String> = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".fseventsd", ".Trashes",
        ".TemporaryItems", ".DocumentRevisions-V100", ".VolumeIcon.icns", "Icon\r", ".apdisk"
    ]

    static func isJunk(_ name: String) -> Bool {
        junkNames.contains(name) || name.hasPrefix("._")
    }

    /// Characters Android's shared storage rejects (it applies FAT-style rules),
    /// mapped to safe look-alikes. macOS allows most of these, and ":" in particular.
    private static let replacements: [Character: String] = [
        ":": " -", "*": "_", "?": "", "\"": "'", "<": "(", ">": ")", "|": "-", "\\": "-"
    ]

    /// Returns an Android-safe file name.
    /// - Converts to NFC: macOS often stores accented names decomposed (NFD); Android expects
    ///   precomposed (NFC), otherwise "Amélie.mkv" can show up garbled or as a duplicate.
    /// - Replaces forbidden characters, strips control characters, trailing dots/spaces.
    /// - Keeps names within Android's 255-byte limit, preserving the extension.
    static func sanitize(_ name: String) -> String {
        var s = name.precomposedStringWithCanonicalMapping
        var out = ""
        for ch in s {
            if let r = replacements[ch] { out += r; continue }
            if ch.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) { continue }
            out.append(ch)
        }
        s = out.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { s = "untitled" }
        if s.utf8.count > 255 {
            let ext = (s as NSString).pathExtension
            var base = (s as NSString).deletingPathExtension
            let budget = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > budget { base.removeLast() }
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s
    }
}
