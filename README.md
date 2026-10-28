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

The app is created at `.build/StageFit.app`. To install or update it, quit
StageFit and run:

```sh
./scripts/build.sh --install
```

This replaces `/Applications/StageFit.app` without launching it. Then:

1. Open StageFit.
2. Allow it in System Settings → Privacy & Security → Accessibility. If it is
   missing from the list, use **+** to add the installed app.
3. Optionally add it in System Settings → General → Login Items → Open at Login.

**Automatic sizing is on by default.** Opening StageFit, granting permission or
re-enabling automation leaves existing windows unchanged. Use the menu bar icon
or shortcut to arrange them. Only windows opened afterward are sized automatically.

By default, builds use an ad-hoc signature. For a persistent local signing
identity, create a Code Signing certificate in Keychain Access, trust it for
Code Signing, and build with
`STAGEFIT_SIGN_IDENTITY="Certificate Name" ./scripts/build.sh --install`.
To reuse it automatically, save its SHA-1 fingerprint as a single line in
`~/Library/Application Support/StageFit/signing-identity`. Certificates and
private keys stay in the local keychain and are not part of the repository.
An explicit `STAGEFIT_SIGN_IDENTITY` overrides the saved identity. A missing or
unusable configured identity fails the build rather than reverting to ad-hoc.
Changing signing identities may require granting Accessibility permission again.
StageFit reads window geometry and does not request screen or audio recording.

## Controls

- **Left-click the menu bar icon:** arrange windows on each display.
- **Keyboard shortcut:** choose a combination from **Change Shortcut…** in the
  menu. No shortcut is assigned by default.
- **Right-click** or **Control-click:** open the light menu to swap visible
  windows, toggle automatic sizing, change the shortcut or quit.
- **Swap Visible Windows** in the right-click menu swaps the visible pair on
  each display. Aligned pairs keep their sizes. Unaligned pairs receive the
  standard pair layout in reversed order, without an initial normal layout pass.
  Hidden groups are untouched. This command has no keyboard shortcut.
- **Quit:** stop automation and release the shortcut. The app starts
  again at login only if you added it to Open at Login.

Switching apps or manually moving/resizing windows does not trigger automation.
Repeated manual triggers are coalesced into at most one pending refresh while a
layout is running. That refresh reads the current windows again, so switching
groups during an operation does not leave a queued request tied to the old group.

## Layout

- Windows stay on the display containing their largest area. Menu bar and Dock
  space are excluded separately for each display.
- All edges and window gaps are **9 points**. Each display has a fixed
  **190-point** Stage Manager reserve followed by the same 9-point gap, including
  when Stage Manager is hidden or disabled. Foreground and background groups use
  the same layout area; changing thumbnail widths do not change window sizes.
- One visible window fills the area. Two share it, respecting their size limits
  and keeping their current left-to-right order, including after a swap.
  Capped heights align at the top, and unused width stays on the right.
- Groups with more than two windows are left unchanged.
- Size limits are checked before resizing. Unknown limits may require a brief
  size probe. Measured successes and failures are reused for **5 seconds**;
  repeated clicks do not extend this period. Changes to frames, group membership,
  display area or reported limits invalidate the result immediately.
- Pairs check the smaller existing window first. A newly discovered limit
  updates the plan before its partner is changed. Accepted final frames are not
  applied twice. Unreported limits and apps that resist shrinking can still
  require visible size probes; macOS position and size writes are separate.
- After a visible layout succeeds, identified hidden groups are arranged with
  the same rules. Native Stage Manager membership takes precedence. Without it,
  three consistent visibility readings 150 ms apart confirm the foreground group,
  with at most one second of waiting. Unknown or incomplete hidden groups are preserved.
- Automation changes only new windows. A hidden group is arranged only when all
  members belong to the same new-window batch. Windows
  that are not ready receive up to four retries (250/500/1000/2000 ms), within
  five seconds of the first unsuccessful attempt. Disabling automation cancels retries.

Measurements use logical display points. Full-screen, minimized, nonstandard and
nonresizable windows are skipped. Infeasible layouts are preserved or restored;
status messages explain the required and available width when known. Skipped
operations appear in the menu bar icon's tooltip and logs. Manual access,
placement and restoration errors also show a dialog. Closed or unresponsive
apps can prevent restoration.

Stage Manager detection uses undocumented accessibility metadata and an optional
window-number bridge. When these are unavailable, only previously observed hidden
groups can be arranged safely. Window access runs separately from the menu UI.

## Tests

Errors are recorded in the macOS unified log under subsystem
`com.pitonmert.StageFit`, including the display, foreground/background group,
application identifiers and requested/accepted sizes. Window titles and contents
are not logged. To inspect current geometry without arranging windows, run:

```sh
/Applications/StageFit.app/Contents/MacOS/StageFit --diagnose
```

This read-only command needs the app's Accessibility permission. Regular CLI
checks below do not read window data.

```sh
swift test
./scripts/test-cli.sh
```

Build the app before running the CLI checks. Unit tests cover geometry, layout
constraints, rollback, cache expiry, group transitions and bounded automation
retries. CLI checks validate arguments, bundle metadata and signatures without
opening the app or arranging real windows.

Manual acceptance checks after installing a build:

- Arrange a visible single or pair; verify 9-point spacing at every edge,
  preserved left-to-right order and a useful status when a pair cannot fit.
- Swap an aligned pair twice; verify sizes are preserved, the original order
  returns and hidden windows stay unchanged. Swap an unaligned pair; it must
  receive the reversed standard layout directly. A single or triple is skipped.
- Switch between single and paired groups, arranging each in the foreground and
  background. Their frames must stay the same; the left edge is 9 points after
  the fixed Stage Manager reserve, regardless of the visible thumbnail widths.
- Arrange a capped window beside a flexible one, with the capped window on
  either side. The flexible partner should receive its final frame without an
  initial half-width step. Check a growing single near the screen's right edge.
- Groups of three or more must remain unchanged, whether visible or hidden,
  including WhatsApp, Telegram and Messages.
- Switch groups during a request, split a pair, and revisit hidden groups;
  uncertain membership must preserve windows and explain the skipped operation.
- Open windows in a slow-starting app, then disable automation or quit while
  work is pending; existing windows must stay unchanged and retries must stop.
- Check multiple displays, shortcut responsiveness and read-only `--diagnose`.

## License

[MIT](LICENSE).
