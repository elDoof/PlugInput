# PlugInput

A macOS menu bar app that puts audio plugins on your live microphone.

Run a compressor — or a de-esser, an EQ, a reverb — on your voice without opening a DAW, and
have Zoom, Discord, Slack, or OBS receive the processed signal as a microphone.

```
mic → [Audio Unit effects] → private aggregate device → headphones + PlugInput
                                                                    ↑
                                          other apps select this as their microphone
```

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 6)

PlugInput ships its own audio driver: `./make-driver.sh install` builds it and installs it to
`/Library/Audio/Plug-Ins/HAL`, which needs an administrator password once. It is a renamed build
of [BlackHole](https://github.com/ExistentialAudio/BlackHole) — that is what lets the device
appear under our own name, since a CoreAudio device name is fixed at compile time. If you
already run BlackHole, the two coexist: different name, bundle id, and UID.

## Build and run

```bash
swift build && swift test     # library + 63 unit tests
./make-app.sh release         # assembles PlugInput.app
open PlugInput.app            # a waveform icon appears in the menu bar
```

`make-app.sh` is not optional packaging. A menu bar app needs `LSUIElement`, and macOS only
grants microphone access to a bundle whose `Info.plist` carries `NSMicrophoneUsageDescription`
— running the bare SwiftPM binary gets you a dock icon and silence.

To stop it: `killall PlugInput`, or Quit from the menu.

## Using it

1. Click the waveform icon in the menu bar.
2. Pick your **Input** — your microphone or audio interface.
3. Click the **Effect chain** row to open the window, and search the Audio Units you have
   installed (677 on the development machine). Click one to add it to the chain.
4. Press **Start**.
5. In Zoom / Discord / OBS, select **PlugInput** as the microphone.

### The chain

Effects run top to bottom, in the order shown. Up to 8 of them, and the same plugin may appear
more than once. Each row in the window has:

- **↑ / ↓** — move the effect earlier or later in the chain.
- **Bypass** — take it out of the signal without removing it or losing its settings. This one is
  instant; adding, removing, and reordering rebuild the audio graph and cost a brief dropout.
- **Sliders icon** — open that plugin's own interface, drawn by its vendor. Several can be open
  at once.
- **Trash** — remove it from the chain.

Knob positions are saved automatically for every plugin and restored on the next launch, along
with your device, the chain order, and which effects were bypassed.

### Monitoring

The **Monitor** checkbox controls whether you also hear yourself through your speakers or
headphones. Turn it **off** when you are on speakers — otherwise the processed output is picked
back up by the microphone and the loop will howl, especially with a compressor in the chain.

Turning it off does not affect what other apps receive; they still get the processed signal.

## When something seems wrong

Every interesting failure in this kind of app is *silent* — you get plausible-looking success
and inaudible output — so the app reports through the unified log:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.pluginput.app"' --style compact
```

Use the absolute path: a shell function named `log` shadows `/usr/bin/log` in some setups and
prints nothing.

The **Activity** panel in the window shows the same transcript, and the level meter reads an
exact `−∞ dBFS` when macOS is feeding the app digital silence.

Most common cause of silence: **microphone permission**. A microphone macOS has not authorized
returns silence rather than an error, and every layer reports success. Check System Settings →
Privacy & Security → Microphone.

`~/Library/Application Support/PlugInput/session.json` records the chain that loaded and whether
the engine actually started. Delete it to reset the app to defaults.

To verify the audio path itself, independently of the UI, the Phase 0 harness listens on the
virtual device from a separate process — exactly as another app would:

```bash
cd Spike && swift build
./.build/debug/PlugInputSpike listen 4 PlugInput
```

Broadband well above −120.0 dBFS means signal is arriving. Ignore the harness's `RESULT: FAIL`
line — it looks for a 440 Hz test tone, which a microphone does not emit; read the broadband
number.

## Known limitations

- **The driver must be installed separately, with sudo.** Other apps see "PlugInput" only
  after `./make-driver.sh install`. Presenting a device under our own name is not achievable
  with CoreAudio aggregates — two approaches were built and measured, and both failed (gotchas
  #17 and #19 in [CLAUDE.md](CLAUDE.md)), so the name comes from a real HAL driver instead.
- **The driver is GPL-3.0.** It is a renamed build of BlackHole, so redistributing PlugInput
  with it attached carries a source-offer obligation, and BlackHole's authors ask distributors
  to contact them. Unresolved; it does not affect local use.
- **Eight effects maximum.** Each one is loaded in-process and adds latency; the window shows
  the running total, and warns above ~5 ms because that is where talking over it gets hard.
- **Plugins load in-process.** `.loadOutOfProcess` is AUv3-only and most installed Audio Units
  are AUv2, so a crashing plugin takes the app down with it. A deliberate compatibility
  tradeoff; session state is autosaved partly because of it.
- **Ad-hoc signing re-prompts for the microphone on every rebuild.** `make-app.sh` uses a stable
  self-signed identity when one exists and falls back to ad-hoc with a warning when it does not.
  The recipe for creating that identity is in the script's header comment.

## Architecture

```
Sources/AudioCore/       no UI imports — the testable half
  Devices/     CoreAudioProperties, DeviceEnumerator, AggregateDeviceBuilder,
               InputSelection, DeviceDiscovery, VirtualMicrophone
  Engine/      EngineDeviceBinding, AudioEngineController, PeakLevel, ObjCExceptionBarrier
  Plugins/     PluginCatalog, PluginDescriptor, PluginState, PluginSearch, PluginChain
  Persistence/ SessionSnapshot, SessionStore
  Diagnostics/ EngineLog, EngineLogReader, AudioLevel
Sources/ObjCExceptionBridge/  @try/@catch around AVAudioEngine's raising graph calls
Sources/PlugInput/       AppModel, PlugInputApp, MenuBarContentView, PluginWindowController
  Views/       ConsoleView, ChainEditorView, PluginBrowserView
Tests/AudioCoreTests/    63 tests
Spike/                   Phase 0 verification harness — separate package
```

`AudioCore` never imports a UI framework. That boundary is what keeps the model layer testable:
the CoreAudio and `AVAudioEngine` binding code is not meaningfully unit-testable and is covered
by the Phase 0 spike's two-process tone test instead, so the parts that *are* testable need
somewhere to live that SwiftUI cannot reach into.

The private aggregate device is load-bearing. Binding an output engine straight at the
loopback renders audio but delivers nothing, and the input channel map is what stops the
loopback's own input channels — which carry whatever was just written to it — from closing a
feedback loop.

**[CLAUDE.md](CLAUDE.md) is the engineering companion to this file**: the decisions that are
settled, and twenty-one gotchas that each cost real debugging time. Every one of them fails
silently. Read it before changing the device or channel-map code.

## Why Audio Units rather than VST3

This machine has 710 AU components against 366 VST3 bundles, and every vendor in the library
ships both. AU hosting is native to `AVAudioEngine`, gets real plugin GUIs for free via
`requestViewController`, and avoids JUCE along with its licensing question entirely.
