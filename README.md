# DropWheel

A macOS menu-bar app. Start dragging any file and a radial wheel pops up beside the cursor. Drop the file on a slice to convert it, or hover the centre to flip to **Tools**.

Built with **Swift 6 + SwiftUI**. No dependencies. Everything runs on your Mac.

## Features

| Ring | Image | PDF | Video | Audio | Word / RTF / HTML / text |
|---|---|---|---|---|---|
| Convert | PNG, JPG, WebP, HEIC, TIFF, GIF, BMP, PDF, DOCX (OCR), TXT (OCR) | DOCX, JPG, PNG, TXT (OCR for scans) | MP4, MOV, GIF, M4A, WAV | M4A, WAV | PDF, DOCX, TXT, RTF |
| Tools | Compress, Metadata, Edit, Annotate, Add BG, Crop, Redact, Remove BG, Resize | Compress, Rotate, Split, Metadata, Protect, Pages, Watermark | Compress, Trim, Mute | Trim | — |

Several files dropped at once: **1 PDF** combines images, **MERGE** joins PDFs, **RENAME** renames them all with a pattern (`Trip-{n}`, with undo), and conversions, resize and compression apply to every file.

- **Remove BG** cuts the subject out of a photo on-device (Vision) and saves a transparent PNG. Pair it with **Add BG**.
- **Pages** shows every page as a thumbnail: drag to reorder, rotate, delete, or extract a selection to a new PDF.
- **Trim** previews video or audio, sets start/end from the playhead and can save the current frame as PNG.

- Results are saved next to the original (`Photo Cropped.jpg`, `Page 001.jpg`) and never overwrite anything.
- **⌥⌘D** opens the wheel without dragging. Click a slice, or click the centre to choose files.
- Settings: when the wheel appears (always / holding ⌥ / never), where it appears, where to save, quality, PDF render DPI, launch at login.
- WebP is written by a built-in lossless encoder (`WebPEncoder.swift`), since macOS can read WebP but can't write it.

## Build

Needs macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```bash
swift run -c release dropwheel-selftest   # runs 72 feature checks
./scripts/build-app.sh 1.0.0              # dist/DropWheel.app, .zip, .dmg
open dist/DropWheel.app
```

`UNIVERSAL=1 ./scripts/build-app.sh` builds for Apple silicon and Intel (needs full Xcode).

## Release and website (free)

- Push a tag such as `v1.0.0`. GitHub Actions runs the self-test, builds a universal app and attaches `DropWheel.dmg` to a GitHub Release.
- Every push to `main` publishes `website/` to GitHub Pages (Settings → Pages → Source: **GitHub Actions**). The download button links to the latest release.

The app is ad-hoc signed. Without a paid Apple Developer ID, people must right-click → **Open** the first time.

## Layout

```
Sources/DropWheelCore/   conversion + tools engine (no UI)
Sources/DropWheel/       menu-bar app, wheel, editors
Sources/dropwheel-selftest/
scripts/                 app bundle, icon, DMG
website/                 GitHub Pages landing page
```
