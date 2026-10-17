# StageFit

A native macOS menu bar app that arranges windows with room for Stage Manager
and consistent spacing across displays. Built with Swift and AppKit.

## Requirements

- macOS 14 or later.
- Swift 6 and the macOS SDK for building; Xcode includes both.

The app is built locally from source. No Developer ID certificate or notarization
is needed for this workflow. The build targets the Mac on which it runs.

## Build and install

From the repository root:

```sh
./scripts/build.sh
```

The app is created at `.build/StageFit.app`. The build does not launch it.
Copy the app to `/Applications/StageFit.app`, then:

1. Open StageFit.
2. Allow it in System Settings → Privacy & Security → Accessibility. If it is
   missing from the list, use **+** to add the installed app.
3. Optionally add it in System Settings → General → Login Items → Open at Login.

**Automatic sizing is on by default.** Once permission is granted, existing
eligible windows are resized once at startup; afterward only new windows are
resized. Re-enabling automation leaves existing windows unchanged.

To update, quit StageFit, rebuild and replace the installed app. The build uses
an ad-hoc signature; rebuilding may require re-enabling Accessibility permission.
StageFit reads window geometry and does not request screen or audio recording.

## Controls

- **Left-click the menu bar icon:** arrange windows on each display.
- **Keyboard shortcut:** choose a combination from **Change Shortcut…** in the
  menu. No shortcut is assigned by default.
- **Right-click** or **Control-click:** toggle automatic sizing, change the
  shortcut, open Accessibility settings or quit.
- **Quit StageFit:** stop automation and release the shortcut. The app starts
  again at login only if you added it to Open at Login.

Switching apps or manually moving/resizing windows does not trigger automation.

## Layout

- Each window stays on the display containing its largest area. Menu bar and
  Dock space are excluded separately for each display.
- Display edges, Stage Manager thumbnails and adjacent windows have a **9-point**
  gap. If Stage Manager cannot be measured, the left reserve is **190 points**,
  including when Stage Manager is hidden or disabled.
- One visible window fills the available area. Two share it left to right,
  allowing larger minimum widths to take space from the other window.
- If the pair cannot fit, original frames are restored. More than two visible
  windows leave that display unchanged.
- Windows in hidden Stage Manager groups are enlarged after the visible layout
  succeeds. Automatic sizing only changes the newly opened windows.

Measurements use logical display points. Full-screen, minimized, nonstandard and
nonresizable windows are skipped. Minimum-size probing can briefly resize a
window; closed or unresponsive apps can prevent restoration. Automatic errors
appear in the menu status and macOS logs; manual errors also show a dialog.

## Tests

```sh
swift test
./scripts/test-cli.sh
```

Build the app before running the CLI checks. Unit tests cover geometry, layout
constraints, rollback and automation. CLI checks validate arguments, bundle
metadata and signatures without opening the app or arranging real windows.

## License

[MIT](LICENSE).
