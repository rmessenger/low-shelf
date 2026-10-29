# FineTune

A native macOS equalizer that learns your preferred sound through A/B comparisons, with headphone profiles and independent tuning for each ear. SwiftUI interface; Core Audio process taps; no dependencies, kernel extensions, accounts, or network access. Requires macOS 14.2 or newer and a stereo output.

## Run

```sh
./scripts/build.sh
open dist/FineTune.app
```

Apple's Command Line Tools with Swift 6 are sufficient; full Xcode is optional. The script produces an app for your Mac's architecture and signs it locally. To use a developer signing identity, set `CODESIGN_IDENTITY` when building. This local build is not notarized for public distribution.

Choose a headphone profile and press **Enable EQ**. If macOS asks, allow FineTune to capture system audio. This access is used only to process playback in memory; audio is never saved or uploaded. Permissions live in System Settings → Privacy & Security → Screen & System Audio Recording. An ad-hoc rebuild may require granting permission again.

## Controls

- **Headphones:** choose the profile for the pair you are wearing; the gear button adds, renames, or deletes profiles.
- **A / Current / B:** listen to the current profile or either candidate. The graph always shows Current, keeping candidate shapes hidden.
- **Five preference buttons:** listen to both A and B with EQ enabled, then vote. Every vote updates and saves Current immediately, returns playback to Current, and starts a new comparison.
- **History:** votes are grouped by day and by 30-minute gaps. Roll back a vote or session to restore Current before it; that vote and all newer votes are removed. There is no redo.
- **Enable / Disable EQ:** starts or stops processing. Disabling restores ordinary playback at its original volume, which may sound louder. **Control–Option–Command–B (⌃⌥⌘B)** toggles it globally while the app is running. Command-E also works inside the app.
- **Menu-bar icon:** a filled waveform circle means enabled; an outlined circle means disabled.

The curves show relative tonal shape before automatic attenuation. Processing never starts automatically. Closing the window leaves the menu-bar control running; quitting removes the audio route.

## Global keyboard shortcut

FineTune registers ⌃⌥⌘B with macOS's native hotkey API. It does not need Accessibility or Input Monitoring access. The shortcut toggles once per key press, ignores held-key repeats, and does not bring FineTune to the foreground. Quit releases the shortcut.

At launch, FineTune checks enabled macOS symbolic shortcuts and requests exclusive registration. If registration fails, the window displays a persistent message and the on-screen controls remain usable. This detects registered global hotkeys, not every app-specific menu shortcut or key remapper. The chosen combination is not configured as a system shortcut on the development Mac; applications may still assign it locally (for example, Xcode has used it for an Analyze command).

The original ⌃⌥B candidate was avoided because Apple uses it for backward word navigation and a VoiceOver reading command. See [Apple's Pages shortcuts](https://support.apple.com/en-au/guide/pages/-tanc0ffef022/mac) and [VoiceOver web commands](https://support.apple.com/en-ae/guide/voiceover/vo27972/10/mac/27).

## Headphone profiles and A/B tuning

Add a named headphone profile and enable EQ. A and B are opposite variations around Current, with randomized labels. Select both before choosing strongly/slightly prefer A, can’t tell the difference, or slightly/strongly prefer B. All five choices stay disabled until both candidates have been heard in that round. You can vote while listening to Current, or stay on Current as long as you like. There is no separate training mode or save action.

History can restore an individual round or the beginning of a session, including votes from before separate L/R tuning. Older votes have no timestamps and appear under Earlier votes. Existing profiles and their latest learned curves migrate automatically, with an original-file backup on the first save. Profiles and history stay on this Mac.

The experimental full-range processor has nine overlapping bands per ear, attenuation-only output with 6 dB additional headroom, and smooth A/B transitions. [Design, algorithm, limitations, and simulation instructions](docs/tuning.md).

## Audio design

Each ear uses nine overlapping filters calculated and processed in 64-bit floating point. Core Audio input and output buffers remain 32-bit float. Left and right channels have independent coefficients and state. There is no compression, limiting, saturation, or lossy encoding.

Filter changes crossfade over approximately 50 ms. The callback uses no memory allocation, locks, Swift object management, file access, or logging. Controls and meters cross threads through lock-free atomics. No fast-math optimizations are enabled.

The app uses a private aggregate containing the selected output and one device-specific process tap. FineTune's own process is excluded to prevent feedback, and hardware input streams are disabled. The physical output is the clock source; tap drift compensation uses Core Audio's highest quality. FineTune does not request a different device sample rate or add its own sample-rate converter. Core Audio may still perform conversion or clock alignment, so this is not a claim of bit-perfect system routing.

The tap uses `mutedWhenTapped`: normal playback is suppressed only while the tap is being consumed. A device or sample-rate change pauses processing; enable EQ again. Sleep also pauses it. Mono Bluetooth call mode and multichannel/surround devices are unsupported and are rejected. Bluetooth stereo playback still uses the device's normal Bluetooth codec.

Headroom reduces clipping risk but does not guarantee protection from every transient or intersample peak. Start/stop and device switching can briefly interrupt playback. The app processes the current default output, not apps explicitly routed to another device.

## Validation

```sh
./scripts/check.sh
```

The checks run without XCTest so they also work with Command Line Tools. They exercise actual DSP samples, shelf endpoints and midpoint across 44.1–192 kHz, monotonic response across steepness settings, transition width, live steepness changes, headroom and trim, silence, stereo separation, rapid control changes, and Core Audio buffer routing. Additional native hotkey checks verify conflict detection, registration cleanup, event delivery, and held-key repeat suppression. The build treats Swift warnings as errors and checks C with `-Wall -Wextra -Werror`.

Live routing and enable/disable controls were exercised on macOS 15.1 with External Headphones at 48 kHz. Other hardware, Bluetooth switching, permission denial, sleep/wake, and OS versions still need hardware validation.

## Layout

- `Sources/BassDSP`: C audio callback, double-precision filter, atomic controls/meters.
- `Sources/HotKeySupport`: native global shortcut registration and keyboard handling.
- `Sources/FineTune`: SwiftUI app, device/tap lifecycle, saved settings.
- `Tests/BassDSPTests`: standalone numerical and buffer-routing checks.
- `Tests/HotKeyChecks`: native registration, lifecycle, and event-delivery checks.
- `scripts`: build, local signing, icon generation, and verification.

The shelf equations follow the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/). Routing uses [Apple's Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
