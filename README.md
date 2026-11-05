# LowShelf

A small native macOS equalizer for adjustable, system-wide bass. SwiftUI interface; Core Audio process taps; no dependencies, kernel extensions, accounts, or network access. Requires macOS 14.2 or newer and a stereo output.

## Run

```sh
./scripts/build.sh
open dist/LowShelf.app
```

Apple's Command Line Tools with Swift 6 are sufficient; full Xcode is optional. The script produces an app for your Mac's architecture and signs it locally. To use a developer signing identity, set `CODESIGN_IDENTITY` when building. This local build is not notarized for public distribution.

Press **Enable bass boost**. If macOS asks, allow LowShelf to capture system audio. This access is used only to process playback in memory; audio is never saved or uploaded. Permissions live in System Settings → Privacy & Security → Screen & System Audio Recording. An ad-hoc rebuild may require granting permission again.

## Controls

- **Bass boost:** 0–24 dB relative to mids and highs.
- **Shelf midpoint:** 20–500 Hz, the point at half the selected boost. Lower values emphasize deep bass; higher values add warmth.
- **Shelf steepness:** 10–100%. Lower values make a broader, gentler transition. 100% matches the original curve and is the steepest setting without a resonant bump. Presets restore 100%.
- **Automatic headroom:** reduces gain by the boost amount plus 1 dB. Boosting bass therefore makes mids and highs quieter. Raise your normal playback volume if desired.
- **Output trim:** an additional 0–18 dB reduction for unusually hot material or transients.
- **Enable / Disable bass boost:** starts or stops processing. Disabling removes the audio route and restores ordinary playback at its original volume, which may sound louder. **Control–Option–Command–B (⌃⌥⌘B)** toggles it globally while LowShelf is running, including when its window is closed. Command-E also works inside LowShelf.
- **Launch at Login:** a menu-bar checkbox that registers LowShelf with macOS Login Items. If macOS requires approval, use **Approve Launch at Login…** in the same menu. Uncheck it to unregister.
- **Automatic Bass Boost for Headphones:** a menu-bar checkbox that starts bass boost when headphones become the default output and stops it when the output switches away. It also applies at launch and after waking if headphones are already selected. Detection uses Core Audio's headphone terminal type; devices that do not identify themselves as headphones remain manual. Manually disabling bass boost keeps it off until the output changes again. With this option off, output changes preserve your manual on/off setting. Both options default to off.
- **Menu-bar icon:** a filled waveform circle means enabled; an outlined waveform circle means disabled. The icon follows actual processing state, including automatic stops and failed starts.

The curve shows the relative tonal shape, before headroom and trim. The meter shows processed sample peaks, not reconstructed true peaks. Presets, sliders, and the headphone automation preference are saved. Processing starts automatically only when the headphone option is enabled and headphones are the current output. Closing the window leaves the menu-bar control running. Quit removes the audio route.

## Global keyboard shortcut

LowShelf registers ⌃⌥⌘B with macOS's native hotkey API. It does not need Accessibility or Input Monitoring access. The shortcut toggles once per key press, ignores held-key repeats, and does not bring LowShelf to the foreground. Quit releases the shortcut.

At launch, LowShelf checks enabled macOS symbolic shortcuts and requests exclusive registration. If registration fails, the window displays a persistent message and the on-screen controls remain usable. This detects registered global hotkeys, not every app-specific menu shortcut or key remapper. The chosen combination is not configured as a system shortcut on the development Mac; applications may still assign it locally (for example, Xcode has used it for an Analyze command).

The original ⌃⌥B candidate was avoided because Apple uses it for backward word navigation and a VoiceOver reading command. See [Apple's Pages shortcuts](https://support.apple.com/en-au/guide/pages/-tanc0ffef022/mac) and [VoiceOver web commands](https://support.apple.com/en-ae/guide/voiceover/vo27972/10/mac/27).

## Audio design

The filter is a monotonic RBJ low shelf (adjustable slope S=0.1–1), calculated and processed in 64-bit floating point. Core Audio input and output buffers remain 32-bit float. Left and right channels have independent state. There is no compression, limiting, saturation, or lossy encoding.

Controls ramp over approximately 50 ms rather than changing instantaneously. The callback uses no memory allocation, locks, Swift object management, file access, or logging. Settings and meters cross threads through lock-free atomics. No fast-math optimizations are enabled.

The app uses a private aggregate containing the selected output and one device-specific process tap. LowShelf's own process is excluded to prevent feedback, and hardware input streams are disabled. The physical output is the clock source; tap drift compensation uses Core Audio's highest quality. LowShelf does not request a different device sample rate or add its own sample-rate converter. Core Audio may still perform conversion or clock alignment, so this is not a claim of bit-perfect system routing.

The tap uses `mutedWhenTapped`: normal playback is suppressed only while the tap is being consumed. A device or sample-rate change reconnects processing to the new output, preserving the manual on/off setting. With headphone automation enabled, switching away from headphones stops processing instead. Sleep also pauses processing. Mono Bluetooth call mode and multichannel/surround devices are unsupported and are rejected. Bluetooth stereo playback still uses the device's normal Bluetooth codec.

Headroom reduces clipping risk but does not guarantee protection from every transient or intersample peak. Reduce Output trim if the meter approaches full scale. Start/stop and device switching can briefly interrupt playback. The app processes the current default output, not apps explicitly routed to another device.

## Validation

```sh
./scripts/check.sh
```

The checks run without XCTest so they also work with Command Line Tools. They exercise actual DSP samples, shelf endpoints and midpoint across 44.1–192 kHz, monotonic response across steepness settings, transition width, live steepness changes, headroom and trim, silence, stereo separation, rapid control changes, and Core Audio buffer routing. Additional native hotkey checks verify conflict detection, registration cleanup, event delivery, and held-key repeat suppression. Automation checks cover headphone insertion/removal, shared device IDs, manual overrides, route and sample-rate changes, and avoiding repeated failed starts. The build treats Swift warnings as errors and checks C with `-Wall -Wextra -Werror`.

Live routing, presets, and enable/disable controls were exercised on macOS 15.1 with External Headphones at 48 kHz. Other hardware, Bluetooth switching, permission denial, sleep/wake, and OS versions still need hardware validation.

## Layout

- `Sources/BassDSP`: C audio callback, double-precision filter, atomic controls/meters.
- `Sources/HotKeySupport`: native global shortcut registration and keyboard handling.
- `Sources/AutomationSupport`: headphone route decisions and native login registration.
- `Sources/LowShelf`: SwiftUI app, device/tap lifecycle, saved settings.
- `Tests/BassDSPTests`: standalone numerical and buffer-routing checks.
- `Tests/AutomationChecks`: headphone automation and terminal classification checks.
- `Tests/HotKeyChecks`: native registration, lifecycle, and event-delivery checks.
- `scripts`: build, local signing, icon generation, and verification.

The shelf equations follow the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/). Routing uses [Apple's Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
