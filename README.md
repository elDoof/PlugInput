# PlugInput

Run audio plugins on your live microphone, then use the processed signal as a microphone
in any other app.

PlugInput is a macOS menu bar utility. Load a compressor, de-esser, EQ, or gate onto your
voice without opening a DAW, and Zoom, Discord, Slack, Teams, and OBS will pick up the
processed signal directly.

```
microphone -> [ your effect chain ] -> PlugInput -> Zoom / Discord / OBS
                                            |
                                            +----> your headphones
```

## Features

* Chain up to 8 Audio Unit effects, in any order, with per-effect bypass.
* Pick which input channel your microphone is on, for interfaces with more than one.
* Each plugin opens its own vendor interface. Several can be open at once.
* Settings, chain order, and device selection are saved and restored on launch.
* Optional headphone monitoring, independent of what other apps receive.
* Latency readout, input level meter, and an activity log.
* Works alongside an existing BlackHole installation.

## Requirements

macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Installation

Download the latest `PlugInput-<version>.pkg` from [Releases](../../releases) and run it. The
installer places the app in `/Applications` and an audio driver in
`/Library/Audio/Plug-Ins/HAL`, then restarts CoreAudio so the device appears immediately.

On first launch, macOS will ask for microphone access. PlugInput cannot capture anything
until you grant it.

**If PlugInput becomes your system microphone.** macOS sometimes makes a newly installed audio
device the default input. If that happens, apps that follow the system default will hear
silence. PlugInput notices and offers a one-click fix in its menu; you can also set it back
yourself under System Settings > Sound > Input.

To remove everything later, run the uninstaller that ships inside the app:

```bash
/Applications/PlugInput.app/Contents/Resources/uninstall.sh          # app and driver
/Applications/PlugInput.app/Contents/Resources/uninstall.sh --all    # also delete settings
```

## Usage

1. Click the waveform icon in the menu bar.
2. Choose your **Input**: a microphone or audio interface. On an interface with several
   inputs, pick the **Channel** your microphone is plugged into.
3. Open the **Effect chain** and search your installed Audio Units. Click one to add it.
4. Press **Start**.
5. In Zoom, Discord, or OBS, select **PlugInput** as the microphone.

### Working with the chain

Effects process top to bottom. The same plugin can appear more than once.

| Control | Effect |
| --- | --- |
| Up / Down | Move the effect earlier or later in the chain |
| Bypass | Remove it from the signal, keeping its settings |
| Sliders | Open the plugin's own interface |
| Trash | Delete it from the chain |

Bypass takes effect instantly. Adding, removing, and reordering rebuild the audio graph
and cause a brief dropout.

### Monitoring

The **Monitor** checkbox controls whether you hear yourself. Turn it off when you are on
speakers rather than headphones, or the processed output will be picked back up by the
microphone and feed back. This is especially loud with a compressor in the chain.

Monitoring does not affect what other applications receive.

Turning it off does more than mute: PlugInput stops opening your output device altogether.
That matters if you use the same interface in a DAW — with monitoring off, PlugInput leaves it
entirely alone.

## Building from source

```bash
swift build && swift test     # library and unit tests
./make-driver.sh install      # build and install the audio driver (asks for sudo)
./make-app.sh release         # assemble PlugInput.app
open PlugInput.app
```

`make-app.sh` is required rather than cosmetic. A menu bar app needs `LSUIElement`, and
macOS grants microphone access only to a bundle whose `Info.plist` declares
`NSMicrophoneUsageDescription`. Running the raw SwiftPM binary produces a dock icon and
silence.

To build a distributable installer:

```bash
./make-pkg.sh              # unsigned, for local testing
./make-pkg.sh --notarize   # signed and notarized, needs Developer ID certificates
```

## Troubleshooting

**No sound reaching other apps.** The most common cause is microphone permission. macOS
returns silence rather than an error when access has not been granted, and every layer of
the stack reports success. Check System Settings > Privacy & Security > Microphone.

**Checking what the app is doing.** A menu bar app has no console, so PlugInput writes to
the unified log:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.pluginput.app"' --style compact
```

The Activity panel in the app window shows the same transcript.

**Resetting.** `~/Library/Application Support/PlugInput/session.json` records the chain
that loaded and whether the engine started. Delete it to return to defaults.

**Verifying the audio path directly.** A separate harness listens on the virtual device
from its own process, the same way another application would:

```bash
cd Spike && swift build
./.build/debug/PlugInputSpike listen 4 PlugInput
```

A broadband reading well above -120 dBFS means signal is arriving. Disregard the
`RESULT: FAIL` line, which looks for a 440 Hz test tone that a microphone does not emit.

## Limitations

* **Plugins load in process.** Out-of-process loading is AUv3 only, and most installed
  Audio Units are AUv2. A plugin that crashes will take the app down with it. Settings are
  autosaved partly for this reason.
* **Eight effects maximum.** Each adds latency. The window shows a running total and warns
  past roughly 5 ms, where talking over your own monitoring becomes difficult.
* **Audio Units only.** VST3 is not supported. See [ENGINEERING.md](ENGINEERING.md).

## How it works

The app builds a private CoreAudio aggregate device, binds an `AVAudioEngine` to it, and
inserts your chain between the input and output nodes. Processed audio is written to a
loopback driver that other applications open as an ordinary microphone.

That driver is what allows the device to appear under its own name. A CoreAudio device
name is a compile-time constant, and macOS keeps no user-level override for HAL devices,
so the name cannot be changed at runtime.

[ENGINEERING.md](ENGINEERING.md) documents the architecture in detail, along with the
failure modes encountered while building it. Nearly all of them are silent: the audio
stack reports success and delivers nothing. Read it before changing device or channel-map
code.

## Credits

PlugInput includes a modified build of
[BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio, used as
its loopback driver and renamed so the device is identifiable. **This is not the official
BlackHole binary and is not supported by Existential Audio.** Please direct any issues
with PlugInput here rather than to them.

BlackHole is licensed under GPL-3.0. The corresponding source is BlackHole v0.6.1 together
with the build flags recorded in [`make-driver.sh`](make-driver.sh).

## License

PlugInput is released under the MIT License. See [LICENSE](LICENSE).

The bundled audio driver is a separate work under GPL-3.0, distributed alongside the app
rather than linked into it. See [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) for the details,
including what was modified and where to get the corresponding source. Its full license text
also ships inside the driver bundle.
