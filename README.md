# LowShelf

A small native macOS equalizer for adjustable, system-wide bass. SwiftUI interface; Core Audio process taps; no dependencies, kernel extensions, accounts, or network access. Requires macOS 14.2 or newer and a stereo output.

## Run

```sh
./scripts/build.sh
open dist/LowShelf.app
```

Apple's Command Line Tools with Swift 6 are sufficient; full Xcode is optional. The script produces an app for your Mac's architecture and signs it locally. To use a developer signing identity, set `CODESIGN_IDENTITY` when building. This local build is not notarized for public distribution.

Press **Start listening**. If macOS asks, allow LowShelf to capture system audio. This access is used only to process playback in memory; audio is never saved or uploaded. Permissions live in System Settings → Privacy & Security → Screen & System Audio Recording. An ad-hoc rebuild may require granting permission again.

## Controls

- **Bass boost:** 0–24 dB relative to mids and highs.
- **Shelf midpoint:** 20–500 Hz, the point at half the selected boost. Lower values emphasize deep bass; higher values add warmth.
- **Shelf steepness:** 10–100%. Lower values make a broader, gentler transition. 100% matches the original curve and is the steepest setting without a resonant bump. Presets restore 100%.
- **Automatic headroom:** reduces gain by the boost amount plus 1 dB. Boosting bass therefore makes mids and highs quieter. Raise your normal playback volume if desired.
- **Output trim:** an additional 0–18 dB reduction for unusually hot material or transients.
- **Bypass:** smoothly restores unprocessed audio at its original level, including bypassing headroom and trim. It may sound louder. Command-B toggles it.
- **Stop:** removes the tap and restores ordinary playback. Command-E starts or stops processing.

The curve shows the relative tonal shape, before headroom and trim. The meter shows processed sample peaks, not reconstructed true peaks. Presets and sliders are saved; processing never starts automatically. Closing the window leaves the menu-bar control running. Quit removes the audio route.

## Audio design

The filter is a monotonic RBJ low shelf (adjustable slope S=0.1–1), calculated and processed in 64-bit floating point. Core Audio input and output buffers remain 32-bit float. Left and right channels have independent state. There is no compression, limiting, saturation, or lossy encoding.

Controls ramp over approximately 50 ms rather than changing instantaneously. Settled bypass copies each float sample exactly. The callback uses no memory allocation, locks, Swift object management, file access, or logging. Settings and meters cross threads through lock-free atomics. No fast-math optimizations are enabled.

The app uses a private aggregate containing the selected output and one device-specific process tap. LowShelf's own process is excluded to prevent feedback, and hardware input streams are disabled. The physical output is the clock source; tap drift compensation uses Core Audio's highest quality. LowShelf does not request a different device sample rate or add its own sample-rate converter. Core Audio may still perform conversion or clock alignment, so this is not a claim of bit-perfect system routing.

The tap uses `mutedWhenTapped`: normal playback is suppressed only while the tap is being consumed. A device or sample-rate change pauses processing; press Start again. Sleep also pauses it. Mono Bluetooth call mode and multichannel/surround devices are unsupported and are rejected. Bluetooth stereo playback still uses the device's normal Bluetooth codec.

Headroom reduces clipping risk but does not guarantee protection from every transient or intersample peak. Reduce Output trim if the meter approaches full scale. Start/stop and device switching can briefly interrupt playback. The app processes the current default output, not apps explicitly routed to another device.

## Validation

```sh
./scripts/check.sh
```

The checks run without XCTest so they also work with Command Line Tools. They exercise actual DSP samples, shelf endpoints and midpoint across 44.1–192 kHz, monotonic response across steepness settings, transition width, live steepness changes, headroom and trim, silence, stereo separation, bit-exact settled bypass, rapid control changes, and Core Audio buffer routing. The build treats Swift warnings as errors and checks C with `-Wall -Wextra -Werror`.

Live routing, presets, bypass, and stop were exercised on macOS 15.1 with External Headphones at 48 kHz. Other hardware, Bluetooth switching, permission denial, sleep/wake, and OS versions still need hardware validation.

## Layout

- `Sources/BassDSP`: C audio callback, double-precision filter, atomic controls/meters.
- `Sources/LowShelf`: SwiftUI app, device/tap lifecycle, saved settings.
- `Tests/BassDSPTests`: standalone numerical and buffer-routing checks.
- `scripts`: build, local signing, icon generation, and verification.

The shelf equations follow the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/). Routing uses [Apple's Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
