# Design decisions

Canvas: https://claude.ai/artifact/EHRLDWxRFhb8Q3gCwnMGMj (private to the owner)

## Picks (2026-11-27)

| Screen | Pick | Changes asked for |
|---|---|---|
| Main window | **B. Sidebar**: TV and Send-to folders on the left, queue table on the right | Keep a normal title bar across the top showing "TV Ferry", as in option A |
| Menu bar | **E. Menu bar panel**, *in addition* to the main window | Can be switched on or off (Settings) |
| Appearance | New | Light / Dark / Match System switch (Settings) |
| About window | New polish | Restyle to match the new design |

## Rules stated

- Use the canvas colours (blue accent, flat grey sidebar, canvas greens and oranges), not the Mac's accent colour. Defined in `Palette` (Theme.swift), with dark-mode pairs.
- The window keeps its title header ("TV Ferry").
- The menu bar panel is optional, never the only way in.
- Appearance follows the system unless the user picks Light or Dark.

## Needs that the canvas assumed

- **TV name** ("Living Room TV"): the app had none. Added as an optional field in Connection…; falls back to the IP address.
- **Recent folders** in the sidebar: the app remembered only one folder. Now keeps the last five chosen.
- Dropping files onto the menu bar *icon* isn't possible with SwiftUI's menu bar API; files are dropped onto the open panel instead.

## Stages

1. Main window (sidebar), menu bar panel, Settings window (appearance, menu bar, transfer options), About window. **Built 2026-11-27**, waiting for the owner's review.

## Where the build differs from the canvas

- The "may not play" warning sits on its own full-width line under the file, not squeezed into the name column, so long file names stay readable.
- The queue's Convert button is labelled "Convert" (its tooltip says Convert & Send) to fit the status column.
