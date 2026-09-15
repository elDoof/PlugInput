# PlugInput

A macOS menu bar app that puts audio plugins on your live microphone, so you can run a
compressor (or anything else) on your voice without opening a DAW — and have Zoom / Discord /
OBS see the processed signal as a microphone.

## Status: v0.9.0 released 2026-08-19; everything since is on `main` but **unreleased**

`main` is pushed and current as of 2026-09-03, but **no tag points past v0.9.0 and no installer
has been built from it**. Everything under "Recent changes" below is therefore visible in the
repository and in nobody's hands: users are still running v0.9.0, which still has all four of the
bugs the stability work fixes. Cutting v0.9.1 is the first open question a new session inherits,
not a detail — and it is now a packaging decision rather than a git one.

Shipped: <https://github.com/elDoof/PlugInput/releases/tag/v0.9.0>. The repository is public,
the `.pkg` is signed with a Developer ID and notarized, and the published asset was verified as
a user receives it — downloaded from the release URL, `spctl` reporting
`accepted / source=Notarized Developer ID`, the stapled ticket validating offline, and SHA-256
matching the local build.

The routing is measured, not assumed: **mic → effect chain → private aggregate → PlugInput**,
read from a separate process at **−31.3 dBFS broadband** through a UAD + SSL chain on the
notarized build, and again at **−34.1 dBFS** on 2026-08-21 through Nectar 4 Compressor → SSL
Native Vocalstrip 2 after the stability work, both against a −120.0 dBFS silence control, with
the app's own log line reading `virtual PlugInput`. Also verified: the unit
tests, `PlugInput.app` launching and staying resident, several hundred AU effects discovered, no
orphaned aggregates, a three-plugin chain wiring in the logged order (duplicates included), a
pre-chain `session.json` migrating with its state intact, the monitor toggle affecting only the
monitor leg, and the exception barrier catching a real double-tap raise.

The **graph/hardware sample-rate mismatch is fixed** (gotcha #27) — all six format numbers now
agree at the hardware rate. It was the last release blocker.

**The capture path was rebuilt on 2026-09-13 and is confirmed working in a real call.** On
macOS 26.6.2 the input node meters correctly and delivers exact digital silence to anything
connected below it, so capture now runs through the tap and a ring (gotcha #36); the tap was
then losing a constant 15% of the signal, which was the crunch (gotcha #37). Confirmed by the
user through **Discord** — monitor audio clear, the input gate holding solid — and not only by
instrument, which matters here because the instrument has been wrong before. This is the first
time this app has been verified doing the thing it exists to do, by the person using it.

**Two things remain open, and they are the honest state of the app:**

- **The click-level chain UI has never been clicked** — adding, reordering with ↑/↓, toggling
  bypass, opening several plugin windows. The engine below it is verified; the buttons are not.
  See "Working on the audio path".
- **The driver goes silent after repeated app restarts, and does not self-heal.** This is the
  live bug, and it is at the driver level rather than in the app. Symptom: `input peak` and
  `output peak` both moving in the log while a separate process reads **exact −120.0 dBFS**
  from the PlugInput device. Confirmed against a known-loud control rather than inferred — the
  `PLUGINPUT_TEST_TONE=1` leg measured −14.0 dBFS on a freshly restarted `coreaudiod` and
  −120.0 after roughly five app restart cycles, with no code change in between. `sudo killall
  coreaudiod` clears it every time; waiting 90s does not. Gotcha #22 documents a transient
  re-sync of this shape, but this form persists, so it is either a worse case of it or
  something else. **Do not trust any device-level measurement taken after several restarts
  without re-checking the tone leg first.**
  It is also the best current explanation of the original report — a user whose app shows a
  working meter while Zoom or Discord receives silence.
- **The freeze is unexplained, and the watchdog's four hits were false.** Crashes on the switch
  path are fixed and measured (gotchas #29–#31, #33), but the reported *freeze* has never
  reproduced here. The leading hypothesis — per-edit plugin state capture — was measured at
  7–9 ms and ruled out (gotcha #32). The `MainThreadWatchdog` then fired four times on
  2026-09-14, up to 17 minutes, which looked like the first hard evidence in the project's
  history; **it was the watchdog measuring system sleep as a freeze**, and the fix plus the
  telltale signature are in gotcha #34. The watchdog is now suspension-aware, so the next hit
  means something. The first thing to do with a fresh freeze report is:

  ```bash
  /usr/bin/log show --last 30m --info --predicate 'subsystem == "com.pluginput.app"' \
    --style compact | grep -i 'unresponsive\|responding again'
  ```

Reproduce it with the app running and a plugin loaded:

```bash
cd Spike && ./.build/debug/PlugInputSpike listen 4 PlugInput
```

Broadband well above −120.0 dBFS is the proof. Three traps in reading that number. Ignore the
harness's `RESULT: FAIL`, which looks for the Phase 0 440Hz tone that a microphone does not
emit. **Give the engine a few seconds after launch** — listening too early reads −120.0 and
looks exactly like a real failure. And **do not read it back-to-back**: opening and closing the
virtual device repeatedly leaves later readers on exact digital silence for tens of seconds
before it recovers on its own, which is the driver's "is anything writing?" re-sync (gotcha #22)
and not a fault in the app. A run of −120.0 readings that ends in signal with nothing changed is
this, every time. Cross-check against the app's own `input peak` line before believing a
failure: peak non-zero plus listener silent means the *reader* is out of sync.

### Version control

Single branch `main`. `.gitignore` keeps `.build/` (~650M), `PlugInput.app/`, and built
installers out. `README.md` is the user-facing doc: what the app is, how to install it, known
limitations. **This file is the engineering companion to it**; keep the overlap thin and let
README describe *use* while this describes *why*.

### Recent changes

**The microphone reaches other apps again, and cleanly** (2026-09-13). Two defects, one on top
of the other; see gotchas #36 and #37.

- **Capture moved off the input node's own downstream connection** (#36). It meters correctly
  and delivers exact digital silence to anything connected below it on macOS 26.6.2, so the tap
  is the capture path now, with `InputRingBuffer` between it and an `AVAudioSourceNode` at the
  head of the chain.
- **The tap was losing a constant 15% of the signal**, which is what the crunch was (#37). The
  tap will not call back more often than every 100ms, so a buffer holding less than 100ms of
  audio silently drops the remainder every cycle — measured at 41,015 frames/sec against 48,058
  requested, which is 4096/4800 exactly. The size is now derived from the sample rate rather
  than hardcoded, and measures **48,000 frames/sec with starvation flat at zero**.
- **There is an output meter**, because capture and the route out to the virtual device fail
  identically and one meter could not tell them apart. `PLUGINPUT_TEST_TONE=1` proves the whole
  output leg without a microphone, and is what identified the driver problem above as not being
  the app's fault.


**An app icon, a version readout, and one more window-lifetime fix** (2026-09-03). The icon is the
last of the three things "still missing for a confident v1" that could be done without a
decision; crash reporting and updates both remain.

- **`Resources/AppIcon.icns` is drawn in code** — `Tools/render-icon.swift`, rendered by
  `./make-icon.sh`, committed as an artifact so `make-app.sh` needs no toolchain beyond the
  compiler to assemble a bundle. Five bars, cyan to indigo, on a dark plate: input entering the
  chain and leaving it changed. Each size is rendered natively rather than downscaled from
  1024, because at 16pt a bar is under two pixels wide and a scaled one smears. Both scripts
  now **refuse to build without it** — `make-app.sh` because the icon has to be inside the
  bundle before `codesign` (gotcha #28), `make-pkg.sh` because an app with no icon installs and
  runs perfectly and nothing downstream would ever report it.
- **The running version is now stated in two places** — first line of every log transcript
  (`PlugInput 0.9.0 (28) starting`) and beside the title in the menu, selectable so it can be
  pasted into a bug report. This app is diagnosed entirely from its log and `session.json`, and
  neither said which build produced them. With fixes sitting behind a release, "it still
  freezes" is not actionable without knowing whether the reporter has the build that fixed it.
  `AppVersion` reads the bundle rather than a compiled-in constant, so it cannot disagree with
  what the installer shipped, and it says "unbundled development build" rather than inventing a
  number when there is no Info.plist.
- **`requestViewController`'s completion could outlive what it was requested for** (gotcha #35),
  which is a real defect on the chain UI path nobody has clicked. Found by reading, not by a
  crash report.
- **`./make-app.sh debug` never ran**, on any machine, since `set -u` was added: macOS ships
  bash 3.2, where an empty array expansion is an *unbound variable* rather than an empty list.
  Release builds fill that array, so the one configuration that leaves it empty was the one
  nobody exercised. 84 unit tests pass; the app was relaunched from the rebuilt bundle and its
  first log line read the version above.

**Post-v0.9.0 stability work** (three commits, gotchas #29–#34). Switching plugins
crashed and froze; none of the crashes turned out to be the third-party plugins' fault, and the
one that was is now handled anyway.

- The engine queue was performing the **last release of an `AVAudioUnit`**, so the vendor's
  teardown — including AppKit window closes — ran off the main thread. Confirmed from a crash
  report, not inferred. Fixed by `releaseOnMainThread`.
- Plugin windows **did not retain the vendor's view controller**, leaving a live view wired to a
  deallocated owner. Fixed by `contentViewController`.
- The `isTransportBusy` flag **discarded** overlapping transport requests instead of serialising
  them, so a fast second chain edit could leave the engine a cycle behind the editor. Replaced by
  a queue.
- `prepareForQuit` now ends in **`_exit`**, so no plugin gets an exit-time turn. The SSL
  Vocalstrip quit crash lands *four seconds after* teardown finishes, from the plugin's own JUCE
  timer thread racing its globals' destruction — nothing here is on that stack, and the disposal
  fix above did **not** cover it (it reproduced on that build).
- `stop()` serialised every plugin's `fullState` on the main thread, and every chain edit goes
  through `stop()`. Removed from that path; the autosave and quit still capture.

**Two claims in this section were wrong before they were measured, and both are recorded rather
than quietly corrected.** The state capture was called "the freeze" and measured at 7–9 ms across
four heavy plugins (#32). The disposal fix was called a probable fix for the SSL quit crash, and
that crash then reproduced on it (#33). **The freeze itself remains unexplained** — what the work
bought is `MainThreadWatchdog` (#34), so the next one carries its own evidence.

Measured after the change: Nectar 4 Compressor → SSL Native Vocalstrip 2 at **−34.1 dBFS
broadband** on the two-process listener; **ten** launch/quit cycles on a four-plugin UAD + Nectar
+ SSL chain, all ten starting the engine, with no crash report and no orphaned aggregate; the
watchdog silent through 75s of ordinary running and reporting an induced 5.2s stall exactly once.
80 unit tests pass. The click-level chain UI is still unclicked — see the two open items under
"Status" above.

Two features before that, in this order — the first exists to make the second safe:

- **An Objective-C exception barrier around graph mutation** (gotcha #21). `installTap`,
  `attach`, `connect`, `detach`, `prepare` and `mainMixerNode` *raise* rather than throw, and an
  `NSException` unwinds past every Swift `do/catch` and aborts the process. `withGraphBarrier`
  converts the family into caught errors that flow into the existing failure path.
- **An ordered effect chain of up to 8 plugins**, each with its own settings and bypass,
  reorderable from the console window. `PluginChain` is an immutable value; slots carry a UUID
  so the same plugin can appear twice and a reorder carries settings and windows with it.

Two standing non-deliveries, both deliberate:

- **Naming the virtual mic "PlugInput"** (gotchas #17, #19). Both aggregate routes were built,
  measured, and reverted. Do not start a third attempt without reading those entries — the
  remaining route is a real HAL driver.
- **A live graph differ.** The chain rebuilds the engine on every add/remove/reorder, because
  rewiring a running `AVAudioEngine` is the fragility gotcha #14 came out of. A dropout per edit
  is the accepted cost. Bypass is the exception: it is a live property, so it is seamless.

## Build and run

```bash
swift build && swift test     # library + 93 unit tests
./make-driver.sh install      # builds + installs the PlugInput HAL driver (sudo, once)
./make-icon.sh                # only when the artwork changes — the .icns is committed
./make-app.sh release         # assembles PlugInput.app
open PlugInput.app            # waveform icon appears in the menu bar
killall PlugInput
```

A `.app` bundle is mandatory, not cosmetic: menu bar apps need `LSUIElement`, and macOS only
grants microphone permission to a bundle whose Info.plist carries
`NSMicrophoneUsageDescription`. Running the bare SwiftPM binary gets a dock icon and silence.

## Seeing inside a running menu bar app

There is no console to print to, and the UI cannot be clicked from a terminal session, so the
app reports through the unified log (`EngineLog`) — device selection, channel maps, start
failures, and input peak once a second:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.pluginput.app"' --style compact
```

Use the **absolute path**: a shell function named `log` shadows `/usr/bin/log` in this
environment and swallows the query, printing nothing and looking like "no output".

`~/Library/Application Support/PlugInput/session.json` is the other readout — it records which
plugin loaded and whether `start()` actually succeeded. Between those two, most questions can
be answered without touching the menu bar. When the app is wedged rather than wrong,
`sample $(pgrep PlugInput) 3` names the blocking frame outright.

## Architecture

```
Sources/AudioCore/       no UI imports — the testable half
  Devices/     CoreAudioProperties, DeviceEnumerator, AggregateDeviceBuilder, InputSelection,
               DeviceDiscovery, VirtualMicrophone (naming constants — see gotchas #17, #19)
  Engine/      EngineDeviceBinding, AudioEngineController, PeakLevel, ObjCExceptionBarrier,
               MainThreadRelease (gotcha #29), InputRingBuffer (gotcha #36)
  Plugins/     PluginCatalog, PluginDescriptor, PluginState, PluginSearch, PluginChain
  Persistence/ SessionSnapshot, SessionStore
  Diagnostics/ EngineLog, EngineLogReader, AudioLevel, AppVersion, MainThreadWatchdog +
               MainThreadStallDetector (gotcha #34)
Sources/ObjCExceptionBridge/  the only Objective-C in the project — @try/@catch, see gotcha #21
Sources/PlugInput/       AppModel, PlugInputApp, MenuBarContentView, PluginWindowController,
                         LoginItem
  Views/       ConsoleView (window: routing, meter, activity), ChainEditorView (reorder,
               bypass, remove), PluginBrowserView (search, adds to the chain)
Tests/AudioCoreTests/    93 tests
Tools/render-icon.swift  the app icon, as CoreGraphics drawing code — ./make-icon.sh renders it
Resources/AppIcon.icns   committed build artifact; make-app.sh and make-pkg.sh both require it
Spike/                 Phase 0 verification harness — separate package, kept as reference
```

Signal path: **mic → [effect chain] → private aggregate device → headphones + PlugInput**.
Other apps select **PlugInput** as their microphone — a CoreAudio HAL driver this project builds
and installs via `make-driver.sh` (gotcha #22). An existing BlackHole installation keeps
working alongside it — verified — because the driver carries its own name, bundle id, and UID.

## Settled decisions

- **Audio Units, not VST3.** VST3 was the starting assumption, and surveying a well-stocked
  library overturned it: there were roughly twice as many AU components as VST3 bundles, and
  *every* vendor shipped both (iZotope's AU bundles are named things like
  `iZOzone12AUHook.component`, which is what made the VST3 list look exclusive). AU hosting is
  native `AVAudioEngine`, gets real plugin GUIs free via
  `requestViewController`, and avoids JUCE and its GPL/commercial licensing question entirely.
- **Both monitoring and virtual mic**, not one or the other.
- **Menu bar utility** (`MenuBarExtra`), not a windowed app.
- **An ordered chain of up to 8 effects**, each with its own settings and bypass. v1 shipped
  one slot as a deliberate scope cut; the chain replaced it without touching the device or
  channel-map logic, exactly as that cut predicted.

## Phase 0: the routing is proven

`Spike/` is a working harness that verified the core assumption with a 440Hz probe tone, a
Goertzel single-bin detector, and **two separate processes**:

```bash
cd Spike && swift build
./.build/debug/PlugInputSpike listen 5              # control: expect -120 dBFS silence
./.build/debug/PlugInputSpike tone 14 &             # route tone through the aggregate
./.build/debug/PlugInputSpike listen 6              # expect PASS at -14.0 dBFS
```

**`tone` mode ignores a device argument, and will tell you the driver is broken when it is
not.** `listen 6 PlugInput` honours the name and reads that device; `tone 20 PlugInput` does
**not** — it emits into an aggregate built around *BlackHole 2ch* regardless, and the FAIL line
it prints names BlackHole even when you asked for PlugInput. Run the two together and the
result looks like a clean controlled comparison: BlackHole passes, PlugInput reads −120.0, and
the obvious conclusion is that the renamed driver carries silence (which gotcha #22 makes
entirely plausible). It is an artefact — nothing was ever writing to PlugInput. This cost a
wrong conclusion on 2026-09-13, reported to the user before it was caught.
The way to drive the *app's* virtual device is the app. `PLUGINPUT_TEST_TONE=1` exists for
exactly this: a known −14.0 dBFS through the real output leg, with no microphone involved.

**The −14.0 dBFS figure does not hold for `tone` mode, and chasing the discrepancy wastes a
session.** The tone is mono at 0.2 amplitude (−13.98 dBFS) and `tone` mode feeds it through
`mainMixerNode`, which equal-power pans mono to stereo: −3.01 dB, so the honest expectation is
**−17.0 dBFS**. −14.0 is bit-exact only where no mixer sits in the path. The `tone` emitter is
also **intermittent** — the identical graph configuration was measured delivering −17.0 and
−120.0 on consecutive runs — so a single silent result from it proves nothing. It is Phase 0
scaffolding and is not on the release path; the check that actually settles things is the
`listen` mode against the running app.

Re-run this if routing ever regresses; it isolates the audio path from the UI completely.

## Gotchas that cost real debugging time

These are load-bearing. Each one fails **silently** — producing plausible audio or plain
silence rather than an error.

1. **Setting `CurrentDevice` on the output node does NOT rebind the input node.** A listener
   bound that way kept capturing the built-in mic, whose room noise passed a broadband
   threshold and produced a **false PASS**. Always read the binding back and assert it.
   `EngineDeviceBinding.Sides` exists for this: bind only the side you use.
2. **Binding a side the device lacks kills the engine** (e.g. the built-in mic has 0 output
   channels).
3. **The input channel map is mandatory, not cosmetic.** The aggregate also exposes BlackHole's
   *input* channels, which carry whatever was just written to BlackHole. Passing them through
   closes a feedback loop.
4. **Connect the mixer explicitly at the device format**, or `mainMixerNode` silently defaults
   to 44.1kHz and resamples between a 48kHz input and a 48kHz output.
5. **A `noErr` write is not proof.** Channel maps and device bindings are verified by read-back
   after `engine.start()`.
6. **Do not "simplify" to binding an output engine straight at BlackHole with no aggregate.**
   That path renders (tone confirmed at −14 dBFS) but delivers nothing. The aggregate is
   load-bearing.
7. **Always destroy the aggregate on every exit path** (`AggregateRegistry`). Orphans outlive
   the process and clutter the user's audio settings. Verify with
   `system_profiler SPAudioDataType | grep -i pluginput`.
8. Plugins load **in-process** — `.loadOutOfProcess` is AUv3-only and most of this library is
   AUv2, so a crashing plugin takes the app down. Deliberate compatibility tradeoff.
9. Buffer floor on the aggregate is 15 frames; 128 ≈ 2.7 ms. Latency is not a concern — which
   is why the app no longer *asks* for a buffer size at all. See gotcha #24.
10. **The input tap must not capture main-actor state.** AVFAudio calls the tap on
    `RealtimeMessenger.mServiceQueue`. Touching main-actor state
    from there trips Swift's executor check and kills the process with `EXC_BREAKPOINT` on the
    **first audio buffer** — so the app dies the instant audio starts moving, not at launch,
    which is how it survived every build-and-launch check. `PeakLevel` exists to be the only
    thing that closure captures. Found the hard way, from a crash report in
    `~/Library/Logs/DiagnosticReports/`.
11. **A microphone macOS has not authorized returns silence, not an error.** Every layer
    reports success and BlackHole receives exact digital silence. If the listener shows
    −120.0 dBFS while the app claims to be running, suspect permission before the audio graph.
12. **Never call CoreAudio from the main thread. Fixed — keep it that way.**
    `AudioEngineController` used to be `@MainActor`, so `AudioDeviceCreateIOProcID` ran on the
    main thread. When TCC needed a decision, coreaudiod waited on TCC, TCC waited on the user,
    and the main thread sat in `mach_msg` inside `_TellServerAboutStreamUsage` — the app hung
    with no crash, no error, and an unresponsive menu bar icon. Deferring to
    `didFinishLaunching` did **not** help; the problem was the thread, not the timing.
    The class now owns a serial `com.pluginput.engine` queue, `start()` is `async`, and
    `state`/`effectLatencySeconds` are published out under a lock so the UI never reaches into
    the queue — a `queue.sync` from the main thread would reintroduce the whole problem.
    `stop()` stays synchronous *only* for `willTerminate` (gotcha #7); UI paths use
    `stopAsync()`, because the queue is not free while a start awaits a permission decision.
13. **Ad-hoc signing invalidated the microphone grant on every rebuild. Fixed — keep it that
    way.** TCC pins the grant to a *code requirement*, and ad-hoc (`--sign -`) derives it from
    the cdhash, which changes every build. `tccd` then logged `Failed to match existing code
    requirement for subject com.pluginput.app and service kTCCServiceMicrophone` and re-prompted,
    and until the dialog was answered the app captured exact digital silence while every layer
    reported success. `make-app.sh` now signs with a stable self-signed leaf, `PlugInput Local
    Signing`, so the requirement is `identifier "com.pluginput.app" and certificate leaf =
    H"1c6df3b8…"` — verified byte-identical across two consecutive rebuilds. The script falls
    back to ad-hoc when that identity is missing and says so; the header comment has the
    `openssl`/`security` recipe to recreate it. Symptom to recognise if it regresses: the app is
    listed and enabled under Privacy & Security → Microphone and *still* gets silence.
14. **A tap outlives the engine that was running when it was installed.** `stopOnQueue()` used
    to remove the input tap only `if engine.isRunning`, but `AVAudioEngine` stops *itself* on
    some device reconfigurations, and the tap survives that. The next `installTap` then raised
    `required condition is false: nullptr == Tap()` — an **Objective-C exception**, which no
    Swift `do/catch` in `AudioEngineController` can catch, so the process aborted instead of
    reporting an error. It fired on plugin switches, because `selectPlugin` cycles the engine.
    Removal is now unconditional and tracked by `isTapInstalled`. Three separate crash reports
    in one morning were this exact failure. General lesson: `engine.connect`,
    `engine.attach`, and `installTap` signal misuse by *raising*, not by throwing — every one
    of them is a potential abort rather than a caught error.
15. **The system default input is regularly BlackHole itself.** Pointing other apps at the
    virtual device is the whole purpose of this app, and macOS often makes it the default input
    as a result. `selectableInputs` excludes it (capturing it would close a feedback loop), but
    the old fallback in `refresh()` was `defaultInputDevice() ?? inputDevices.first`, which
    happily resolved to the one UID guaranteed to be absent from the list. `start()` then found
    no matching device and refused with "No input device selected" — no audio, and a message
    that blamed the user's selection. `InputSelection.resolve` now guarantees the result is
    always in `available`, and is covered by seven tests including an exhaustive one.
16. **`List(selection:)` rows take a non-optional tag.** The binding is
    `Binding<SelectionValue?>`, so rows tag `SelectionValue` — tagging `Optional(value)`, which
    is exactly what `Picker` requires, makes the types disagree and SwiftUI then discards every
    click with no error and no warning. This cost a full build-and-ask cycle. The plugin
    browser now uses plain buttons instead, which also gives "No effect" somewhere to live: a
    selection binding cannot express nil as a row.
17. **A public aggregate wrapping BlackHole is created happily and carries silence.** The
    obvious way to show other apps a device called "PlugInput" rather than "BlackHole 2ch" —
    BlackHole's own name is not settable, `kAudioObjectPropertyName` reports
    `settable = false` — is a *public* aggregate whose only subdevice is BlackHole. It creates
    cleanly and reports the right 2 in / 2 out. It then delivers **exact digital silence**.
    Measured from a separate process while the engine ran: BlackHole −34.6 dBFS, the wrapper
    −120.0 dBFS, same moment. CoreAudio will not relay a subdevice's loopback into a second
    aggregate while the first holds it — and *direct* concurrent access to BlackHole works fine,
    which is exactly what makes this look like it should work. **Creatability is not signal
    flow.** `VirtualMicrophone` carries this note. It is emphatically *not* dead code — it now
    holds the driver UID, the aggregate UID, and the device name that routing is matched on.
18. **`OSLogStore.getEntries` on the main thread is a UI freeze that grows over time.** The
    Activity panel called `EngineLogReader.recent()` from a `.task`, which inherits main-actor
    isolation, every two seconds — and an unbounded `getEntries` walks the process's whole log
    from launch while the meter writes an entry every second. The hitch therefore got worse the
    longer the app stayed open, which is what "freezing every so often" actually was. Fixed on
    both sides: the query is bounded to a 15-minute window and excludes the high-volume `level`
    category *in the predicate*, and the call runs on a detached task. The same reasoning
    applies to `DeviceDiscovery` — every CoreAudio query is a round trip to `coreaudiod`, so
    `refresh()` is `async` and scans off the main actor.
19. **The aggregate cannot be reordered to put the virtual device first — so "PlugInput" as a
    selectable microphone name is closed off.** With gotcha #17 ruling out a second aggregate,
    the remaining route was to lead the engine's own aggregate with BlackHole (putting its
    loopback on input channels 0–1) and publish that. It fails, and not because of publishing:
    the same failure occurs with `isPrivate: true`, so the reorder alone is the cause.
    `engine.start()` throws `-10875 IsFormatSampleRateAndChannelCountValid(outputHWFormat)`.
    The mechanism, from the `formats before start` log line: the aggregate genuinely exposes
    **7 input channels** (probed directly: `in=7 out=6 rate=48000`, identical across private,
    public, reordered and original variants), but **`AVAudioEngine`'s input node only ever
    reports 2**. With the input device first its offset is 0 and the map `[0]` is in range;
    moved behind BlackHole its offset becomes 2, and a map of `[2]` is *accepted* by
    `AudioUnitSetProperty` and *reads back correctly* — then zeroes the output HW format
    (`outputNode.output 0ch` versus `2ch` when working) and the start fails. Another instance of
    gotcha #5: the write succeeding and the read-back matching still proved nothing.
    Any route to the name needs a real virtual driver, not an aggregate — which is what
    `make-driver.sh` now ships. See gotcha #22.
20. **A stale aggregate blocks every future start.** An exit that skips teardown — crash, force
    quit, `killall` — leaves the aggregate behind, and `AudioHardwareCreateAggregateDevice` then
    refuses the same UID with `OSStatus 1852797029 ('nope')`, failing *every* subsequent start
    until it is deleted by hand. `AggregateDevice.init` now destroys any device already holding
    the UID first, which makes launch self-healing; the log line is `reclaimed stale aggregate`.
    This bit hard while the device was briefly public, but it applies to the private one too.
21. **Graph mutation is now barriered — and a catch is not a recovery.** `installTap`, `attach`,
    `connect`, `detach`, `prepare` and `mainMixerNode` all signal misuse by *raising* an
    `NSException`, which unwinds past every Swift `do/catch` and aborts the process; gotcha #14
    was one instance of the family. `Sources/ObjCExceptionBridge` is a ~25-line Objective-C
    `@try/@catch` — the only ObjC in the project, because Swift cannot `@catch` — and
    `withGraphBarrier(_:_:)` turns a raise into an `ObjCExceptionError` naming the step that
    failed. All 12 call sites in `AudioEngineController` go through it.
    **The contract is teardown, never resume.** A raise happens part-way through `AVAudioEngine`
    mutating itself, and nothing promises what it left behind, so every catch site must tear the
    graph down — which is what `startOnQueue`'s existing `catch` already did, and why this
    dropped in without new error handling. Teardown itself uses `ignoringObjCException`, because
    `stopOnQueue` runs from `willTerminate` and `aggregate?.destroy()` must survive a raise above
    it (gotcha #7). Two honest limits: it catches `NSException`, so a C++ exception from inside
    CoreAudio would still terminate; and unwinding past Swift frames skips their ARC cleanup, so
    each catch leaks a little. Both beat dying. Verified against the real thing — a test installs
    a second tap on an occupied bus and asserts the resulting
    `required condition is false: nullptr == Tap()` arrives as a catchable Swift error.
22. **The renamed driver must be built from BlackHole v0.6.1. v0.7.1 enumerates perfectly and
    carries silence.** Same trap as #17, one layer lower. A v0.7.1 build gets the right name, the
    right UID, opens at 2ch/48kHz, and `coreaudiod` even spawns its driver process — then a
    two-process test reads **−120.0 dBFS** while the identical test against stock BlackHole reads
    −14.0. The mechanism is in `BlackHole.c`: the input path zero-fills whenever
    `gMute_Master_Value || lastOutputSampleTime - inIOBufferFrameSize < mInputTime.mSampleTime`,
    and 0.7.1 fails that second clause. Defaults are volume 1.0 / mute false, so it is the
    "is anything writing?" test failing, not a mute. Renamed **v0.6.1 measures −14.0 dBFS,
    bit-exact**, which is why `make-driver.sh` pins it. The 0.7.1 root cause was never chased —
    pinning was cheaper. Do not bump the tag without re-running `Spike/` and reading a number.
    Two further facts worth keeping: a **self-signed, un-notarized HAL driver loads fine** (this
    was the open question before building anything), and the driver's UID is derived from its
    name — `kDevice_UID = kDriver_Name + "%ich" + "_UID"` → `PlugInput2ch_UID` — so renaming the
    driver silently changes what `VirtualMicrophone.driverUID` must match.
23. **Copy-protected plugins need `allow-unsigned-executable-memory`, or they SIGKILL the host.**
    UAD, Waves, Slate — anything wrapped in PACE/iLok — decrypt their own code into memory at
    load time and execute it. Under the hardened runtime the kernel hashes executable pages on
    fault-in, finds the rewritten page does not match the signature, and kills **the app**, not
    the plugin: `EXC_BAD_ACCESS`, `SIGKILL (Code Signature Invalid)`, termination namespace
    `CODESIGNING` / "Invalid Page", with the faulting frame inside
    `PaceProtectionWrapper…handleWrapEvent` under `dlopen`. It is a kernel decision, so no
    `do/catch` and no `withGraphBarrier` sees it — gotcha #21's barrier catches `NSException`,
    and this is not one.
    **`disable-library-validation` does not cover it.** That entitlement governs *who signed*
    the library; this is about whether its pages may be rewritten after mapping. Both are
    required, and having only the first is what made this look like a plugin bug.
    The failure compounds through persistence: the plugin loads far enough to be saved, so
    `AppModel.restore()` reinstantiates it on the next launch and the app dies again before the
    menu bar icon appears. Most of the crashes observed while diagnosing this were the relaunch
    loop rather than the original click; the escape hatch is the one `SessionStore` already
    documents, deleting `session.json`.
    Diagnosed against a control rather than by guessing: Ableton Live 12, which hosts these same
    plugins successfully, carries exactly `disable-library-validation` +
    `allow-unsigned-executable-memory` and no other `cs.*` entitlement. Verified after the fix
    with the saved UAD chain intact — app resident, `chain UADx LA-2A Gray Compressor →
    Nectar 4` in the log, and **−33.8 dBFS broadband** on the two-process listener.

24. **An aggregate reaches through to its subdevices, so PlugInput was re-sizing other apps'
    audio hardware.** Two mistakes compounded, and together they made PlugInput actively
    disturb a DAW sharing the same interface.
    First, the monitor device was **always** a subdevice of the engine's aggregate. Turning
    monitoring off only wrote `-1` into its channels — the aggregate still *opened* the user's
    output interface. The rationale recorded at the time was that a constant subdevice list
    keeps the virtual device's channel offsets stable across a toggle, which bought nothing:
    `setMonitorEnabled` cycles the engine, so the aggregate is destroyed and rebuilt and every
    offset recomputed regardless.
    Second, `startOnQueue` wrote a preferred **128-frame buffer** onto the aggregate. A CoreAudio
    aggregate pushes its IO buffer size down onto its subdevices, so that write reached straight
    through to the user's own interface and re-sized it underneath whatever else was using it.
    Nothing restored the previous value on teardown, so it outlived the session. It was a `try?`
    with no read-back, against the explicit advice on `BufferSize.set` and gotcha #5.
    Symptom: crackle, dropouts, or a device error in a DAW, appearing while PlugInput ran and
    persisting after it stopped — with nothing pointing at PlugInput as the cause.
    Fixed both ways round. The monitor is now **absent** from the aggregate when monitoring is
    off, not muted in it, and `BufferSize` has no setter any longer — the app reads whatever the
    aggregate inherits and logs it. General lesson: **an aggregate is not a sandbox.** Anything
    written to it is written to the user's real hardware.
25. **`queue.sync` in `willTerminate` is a deadlock, however innocent the body looks.**
    `stop()` was a `queue.sync`, justified on the grounds that teardown negotiates no
    permissions. True of the *body*, irrelevant to the *queue*: the queue is held for the whole
    of a start, and a start blocks inside `AudioDeviceCreateIOProcID` until the user answers the
    microphone dialog. First run, click Start, then Quit before answering, and the main thread
    blocked forever on a queue waiting for a dialog the now-frozen app could no longer show.
    Force quit was the only way out, and it orphaned the aggregate on the way (gotcha #7, then
    #20 for what the survivor costs the next launch).
    `stopForTermination(timeout:)` replaces it: ask the queue, wait two seconds, and if it does
    not answer destroy the devices directly through `AggregateRegistry`, which holds raw IDs
    behind a lock precisely so cleanup is reachable without the queue.
    The ordering in `AppModel.prepareForQuit` matters for the same reason. Teardown now runs
    **before** the session save, because the save asks up to eight third-party plugins to
    serialise their entire state on the main thread inside a bounded termination window — one
    slow vendor and the process dies before the aggregate is destroyed. Lost knob positions are
    much cheaper than an orphaned device.
26. **Capturing the input device's first channel is wrong on most interfaces.** The input
    channel map was `[offset]`, where `offset` is where the device's channels start inside the
    aggregate — so it always selected the device's *first* channel. Correct for a built-in
    microphone, and exact digital silence for anyone whose mic is in input 2 of an interface,
    with `start()` succeeding, the meter reading 0.0, and the UI blaming microphone permissions
    it had never checked. There is now an input-channel picker, persisted per device.
    Two things to know before changing it. The map value must stay inside the range
    `AVAudioEngine`'s input node believes the device has — indexing past it is *accepted* by
    `AudioUnitSetProperty`, *reads back correctly*, and then fails `engine.start()` with
    `-10875` (gotcha #19), so the read-back proves less here than it appears to. And a channel
    index only means something on the device it was chosen on: `settingInput` resets it, and
    `refresh()` clamps it, or a saved channel outlives its interface and refuses every start.
27. **A node's graph-side format is frozen at materialisation, so "the device format" has to be
    read from the *hardware* face.** This is gotcha #4 again, and following it in name while
    breaking it in fact cost a release cycle. `buildGraph` read `outputNode.inputFormat` and
    `inputNode.outputFormat` — the **graph** faces — and called one of them `deviceFormat`.
    An `AVAudioEngine` node configures itself against whatever device is current the moment it
    materialises, which is the *system default*, and pointing
    `kAudioOutputUnitProperty_CurrentDevice` at the aggregate afterwards moves only the hardware
    face. So on a machine whose default output ran at 44.1kHz while the microphone ran at 48kHz,
    the whole graph ran at 44.1kHz and the input arrived as **exact digital silence** — with
    `engine.start()` returning success, the meter reading 0.0, and the microphone coming back
    only when the user switched input devices and back, which rebuilds the graph and lands on
    the right rate by accident.
    Measured, from a standalone program outside the app so the app could not be the cause:

    ```
    after binding to a 48kHz device        after connecting at the hardware format
      inputNode.input   2ch @ 48000          inputNode.input   2ch @ 48000
      inputNode.output  2ch @ 44100  <-      inputNode.output  2ch @ 48000
      outputNode.input  2ch @ 44100  <-      outputNode.input  2ch @ 48000
      outputNode.output 2ch @ 48000          outputNode.output 2ch @ 48000
    ```

    **Connecting at the hardware format is the only thing that moves the graph face.** Spinning
    the runloop so the configuration-change notification is delivered, `engine.reset()`, writing
    `CurrentDevice` a second time, and replacing the whole `AVAudioEngine` were each measured to
    change nothing. A tap installed at the stale rate reads −120.0 dBFS where the same signal at
    the hardware rate reads −19.0.
    Two consequences worth keeping. The chain is now wired at the microphone's real channel
    count, so a mono mic runs a mono chain — the old graph face claimed 2 channels for a
    1-channel device. And `Spike/`'s listener had the identical bug, which made the project's
    own verification tool report silence for a working app; it now taps at
    `inputNode.inputFormat`. **The instrument was wrong at the same time as the thing it
    measured** — when a measurement disagrees with the app's own log, suspect both.
28. **Two notarization failures that every local check passes.** Both were found only by Apple
    rejecting an upload, which is the slowest possible feedback loop, so they are written down
    rather than left to be rediscovered.
    **Anything added to the bundle after signing breaks the seal.** `make-pkg.sh` used to copy
    `uninstall.sh` into `Contents/Resources` of an app `make-app.sh` had already signed. Dropping
    a file into a signed bundle invalidates its `_CodeSignature/CodeResources` seal — but
    `codesign -vvv --strict` verifies *the bundle on disk*, which was untouched and passed, as
    did `spctl`. Apple returned "The signature of the binary is invalid" for both architectures.
    The uninstaller is now installed by `make-app.sh` before its `codesign`, and `make-pkg.sh`
    refuses to build if the staged bundle does not already carry it. **Add nothing to the bundle
    after signing.**
    **`xcodebuild` does not add a secure timestamp.** The driver signed cleanly, verified
    locally, carried the hardened runtime, and was rejected with "The signature does not include
    a secure timestamp". It needs `OTHER_CODE_SIGN_FLAGS="--timestamp"`, and only for a real
    identity — an ad-hoc signature has nowhere to put one. The app passes `--timestamp`
    explicitly for the same reason rather than relying on a default.
    **And `notarytool submit --wait` exits 0 on a rejected submission** — it reports that the
    *upload* succeeded, not that Apple accepted the build. Without an explicit status check the
    first symptom is `stapler` failing with "Record not found", which names neither the cause nor
    the file. `make-pkg.sh` now reads the status and prints `notarytool log` on rejection, which
    is where the two errors above actually came from.
29. **Whichever queue lets go of an Audio Unit runs the vendor's teardown on that thread.**
    Releasing the last reference to an `AVAudioUnit` is not bookkeeping: it runs
    `-[AVAudioNode dealloc]` → `AudioComponentInstanceDispose` → the plugin's own teardown, on
    whatever thread happened to drop it. Plugins tear down their *interface* in there. iZotope's
    Nectar 4 calls `-[NSWindow close]`; AppKit off the main thread traps with "Must only be used
    from the main thread" and the process aborts. JUCE plugins want the message thread — which on
    macOS is the main thread — for the same work, by a different name.
    `stopOnQueue` did `effectNodes = []` on `com.pluginput.engine`, so the engine queue was doing
    exactly that. Confirmed from a crash report rather than inferred: faulting thread
    `com.pluginput.engine`, stack reading `stopOnQueue` → `swift_arrayDestroy` →
    `-[AVAudioNode dealloc]` → `AudioComponentInstanceDispose` → `iZNectar4Core` → `NSWindow
    _close` → trap.
    **It only fires on remove, which is why it looked like "crashes when switching plugins".**
    `AppModel.removeSlot` drops its own reference first, so the engine's array is holding the only
    one left by the time the restart tears the graph down. Add and reorder keep the unit in
    `loadedUnits` throughout, so the queue's release is never the last one and nothing happens.
    `releaseOnMainThread` (`Sources/AudioCore/Engine/MainThreadRelease.swift`) is the fix: empty
    the array into an `@unchecked Sendable` box and let the box die on the main queue. It is
    covered by a test *and its control* — asserting "released on main" proves nothing unless the
    same probe demonstrably reports a background thread with the hop removed.
    At termination the main queue never drains again, so units handed over during quit are simply
    never disposed. That is the intended outcome: the OS reclaims the memory, `persistSession` has
    already captured every plugin's settings, and a vendor's exit-time teardown is what has been
    taking this app down on quit. Four launch/quit cycles with SSL Native Vocalstrip 2 and Nectar 4
    loaded and the engine running produced no crash report, where that plugin had reproduced one
    twice the day before — suggestive, not proof, since the original was a race.
30. **An `NSViewController` is not retained by its own view, and an AU's editor is a view
    controller.** `requestViewController` hands back the vendor's controller; the window took
    `viewController.view` and let the controller go at the end of the method. The view stayed on
    screen, drawn correctly, wired through bindings, target/action, `AUAudioUnit` KVO and redraw
    timers to an owner that had already been deallocated — so a plugin window opened fine and died
    on the next interaction or on close, with a stack in vendor code and nothing pointing here.
    `window.contentViewController = viewController` is the whole fix: the window owns the
    controller and its lifetime becomes the window's.
    One consequence worth knowing before editing that method: assigning `contentViewController`
    **resizes the window to the view**, and assigning `contentView` does not. The "no custom
    interface" fallback therefore needs a content rect that was right when the window was built,
    which is what `placeholderSize` is for.
31. **A busy flag that makes an overlapping request return early does not serialise it — it
    discards it.** `isTransportBusy` guarded `start()` and `stop()`, and every route into transport
    is an `await` from an unstructured `Task` (`toggle`, `selectInput`, `setMonitorEnabled`, and
    each chain edit). A second edit arriving during the first edit's restart therefore found the
    flag set, returned from *both* its stop and its start, and never rebuilt the graph — leaving
    the engine running the previous chain while the editor displayed the new one. Audible order
    silently disagreeing with displayed order, from clicking ↑ twice quickly. `serialized(_:)`
    queues the work behind whatever is in flight instead; the body re-reads `isRunning` and
    `orderedUnits` when it *runs*, not when it was submitted, so a request queued behind a restart
    acts on what that restart left behind. `restartIfRunning` is one queued unit rather than two,
    or another edit could slot its own cycle between the stop and the start.
32. **`stop()` was capturing every plugin's `fullState` on the main thread inside every chain
    edit — and that was *not* the freeze, which is worth recording because it was claimed here
    first and measured second.** `persistSession` asks each loaded unit to serialise its entire
    state, an unbounded call into vendor code, and `restartIfRunning` goes through `stop()`, so
    add, remove, reorder, device change and channel change each paid a full-chain capture on the
    main thread. Removing it from that path is still right — an unbounded vendor call has no
    business inside a per-edit path, and the autosave already covered it — but the entry
    originally asserted it was "precisely the freeze people report", on nothing but the shape of
    the code.
    Then it was instrumented, and a four-plugin chain of UADx LA-2A Gray Compressor →
    Nectar 4 Compressor → Nectar 4 Equalizer → SSL Native Vocalstrip 2 measured **7–9 ms for the
    whole chain**, worst single plugin 7 ms. Applying saved state on relaunch was 0–5 ms per
    plugin. Neither is a freeze at any chain size this app allows.
    So **the freeze is still unexplained**, and the plausible remaining mechanism is gotcha #29's
    off-main disposal rather than anything about persistence: an `AudioComponentInstanceDispose`
    running on `com.pluginput.engine` can block there, and the old `isTransportBusy` flag then
    made every later start and stop return instantly without doing anything, so the app stayed
    wedged rather than recovering. Both halves of that are now fixed, which may be enough — but
    nothing here has reproduced a freeze, so treat that as the next thing to confirm, not as a
    conclusion.
    What the instrumentation buys is that a future freeze names its own cause. `capturedStates`
    and `instantiate` log their timings, and a capture over 100 ms logs at **error** level naming
    the plugin responsible. What plugin loading costs is worth knowing too: 130–1027 ms per
    plugin, off the main actor but sequential, so a four-plugin chain adds ~2.7 s to launch.
33. **A plugin's static teardown runs *after* your app has finished quitting, and it can still
    take the process down.** SSL Native Vocalstrip 2 segfaults on a null `pthread_mutex_lock`
    from its own `JUCE v8.0.10: Timer` thread. The timing is the tell: `prepareForQuit` completed
    at 23:16:12 — aggregate destroyed, session written, engine down — and the crash landed at
    **23:16:16**, four seconds later, while the process was running static destructors and
    tearing down JUCE's globals underneath a timer thread that was still ticking. Nothing in this
    app is on that stack, and gotcha #29 does not help: it reproduced on the build that fixed the
    disposal thread, which is worth stating because this entry previously guessed it might be
    fixed and was wrong.
    Nothing here can order those two events. What it can do is not give them a chance to race:
    `prepareForQuit` now ends in **`_exit(EXIT_SUCCESS)`**, so the kernel tears the process down
    immediately with no atexit handlers and no static destructors, and no vendor gets an exit-time
    turn. `exit` would not do — running atexit handlers is precisely what crashes. It is the same
    reasoning as gotcha #29's decision not to dispose units at termination, carried to the end of
    the process, and it generalises past this one plugin, which matters because the next report
    will come from a user whose plugins nobody here owns.
    Two things to know before touching it. Everything the app owns must be flushed *above* that
    line — `persistSession` is, and `UserDefaults.standard.synchronize()` is called for the
    console window frame SwiftUI keeps there. And the Quit button's `NSApplication.terminate`
    is now unreachable, which is fine but means `prepareForQuit` is the only exit path there is.
    Why this is worth doing for a crash that costs the user nothing: it happens *after* a
    successful quit, so no state is lost — but macOS shows a crash dialog every time, for an app
    that had already shut down correctly.
34. **The freeze had to be made self-reporting, because it has never reproduced here.** A frozen
    menu bar app is uniquely undiagnosable: no window to show an error in, no log line — the
    thread that would write it is the stuck one — and the only way out is Activity Monitor, which
    leaves no record. `sample $(pgrep PlugInput)` is the right tool and needs somebody at a
    terminal *during* the freeze, which is nobody.
    `MainThreadWatchdog` pings the main queue twice a second from a private queue and logs at
    **error** level when a ping takes longer than 2s to come back, then again with the peak
    duration when it clears. It does not name the blocking frame, but it timestamps the stall,
    and the engine transcript around that timestamp says what the app was doing.
    **It reports and never intervenes.** Whatever is blocking the main thread is generally inside
    third-party plugin code, there is no safe way to interrupt it, and a watchdog that tried would
    turn a freeze into a crash.
    The decision logic is a separate value type, `MainThreadStallDetector`, with six tests: what
    could be *wrong* about a stall report is reporting one stall repeatedly (burying the
    transcript that explains it), missing the recovery, or reporting the duration seen at recovery
    — which is near zero, since the main thread has just answered, and would understate every
    stall to nothing. Verified end to end against the real app with `kill -STOP`: 75 seconds of
    ordinary running including a four-plugin load produced no report, and an induced 5.2s stall
    produced exactly one, plus its recovery.

    **CORRECTED 2026-09-14: the watchdog reported four freezes that never happened, and the
    verification above is why it shipped.** `kill -STOP` does not block the main thread — it
    suspends the *whole process*. The watchdog measured with a `ContinuousClock`, which keeps
    counting while the machine sleeps, so the first poll after any gap measured the entire gap
    and blamed the main thread for it. The end-to-end check therefore exercised precisely the
    false-positive path and called it a pass.
    The field readings: four stalls of 285.4s, 529.5s, 917.2s and 1014.2s on 2026-09-14, the
    longest 17 minutes. **The tell is in the transcript, and it is unmissable once seen — each
    stall is followed by its own recovery 0.46–0.56s later**, one poll interval. A genuine
    1014s block puts 1014s between those two lines; the main thread here answered the first
    ping it was actually asked. The app was fine every time; the Mac had been asleep.
    Fixed on both sides. The clock is now a `SuspendingClock`, which stops with the machine. And
    because a clock cannot see the machine *awake* with this process descheduled (App Nap), each
    poll now also reports **how late it is itself**: `MainThreadStallDetector` takes
    `sincePreviousPoll`, and a poll that missed its slot by more than 4× the interval yields
    `.suspended` — logged at notice level, since nothing is wrong — instead of a stall. Only a
    poller that kept its 0.5s cadence while the main thread went quiet reports a freeze. Ten
    tests, including the control that a real 1014.2s block *is* still reported.
    **So the freeze remains unreproduced**, and those four events are not evidence of it. Do not
    use `kill -STOP` to test this again: it now correctly reads as suspension. Induce a real
    stall by blocking the main queue itself.
35. **An asynchronous vendor callback outlives the thing it was asked for, and `close` cannot
    reach a window that does not exist yet.** `requestViewController` is asynchronous, and for a
    heavy plugin it is hundreds of milliseconds of the vendor building its whole interface. For
    that whole time the slot has a request in flight and *nothing to show for it* — a state
    neither `windows` nor `presentedUnits` could represent, so `close(id)` had nothing to clear
    and the completion ran regardless of what had happened in between.
    Two ways that goes wrong, both on the chain UI path nobody has clicked. Open a plugin's
    interface and remove the slot before it appears, and the late callback opens a window for a
    plugin the user has just deleted, wired to a unit the engine has already detached and the
    model has already released — the exact failure this class is keyed by slot id to avoid,
    arriving through the one path that outruns `close`. Or click the button twice: the second
    click does not take the "already open" early return, because there is still no window, so
    two requests land, `present` overwrites `windows[id]` with the second, and the first window
    is left on screen with nothing holding it — `close` and `closeAll` can no longer reach it.
    Fixed by **numbering the requests**: `pendingRequests[id]` holds the current one, `close`
    clears it, and a completion whose number no longer matches drops its view controller and
    returns. Unit identity cannot do this job — two requests for the same slot name the same
    unit, which is precisely the double-click case. `closeAll` now iterates the union of the two
    dictionaries, or a request in flight could open an interface *during* teardown.
    The unit is also carried into the completion in an `@unchecked Sendable` box, on the same
    terms as `ReleaseBox`: a vendor building a view against a unit that the model and the engine
    have both let go of is a use-after-free in code nothing here can see into. Swift's
    concurrency checking is what surfaced this — capturing the `AVAudioUnit` directly is a
    `sending 'effect' risks causing data races` error, not a warning.
    **Found by reading the code, not from a crash report** — worth saying, because this file is
    otherwise a list of things that were only understood after they broke something.
36. **`AVAudioEngine`'s input node captures audio it will not deliver downstream, so the tap is
    the capture path now.** Measured on macOS 26.6.2: a tap on the input node reported a real
    peak while the aggregate the graph fed read **exact digital silence** from a separate
    process, and a tone injected into that same mixer at that same moment read −14.0 dBFS. The
    tap works and the render path works; only `engine.connect(inputNode, to:)` carries nothing.
    So `installTap` became the capture, `InputRingBuffer` carries the frames, and an
    `AVAudioSourceNode` is the chain's head. `inputSinkNode` is still connected to the input
    node at zero volume — not because anything consumes it, but because *connecting* is what
    drags the input node's graph face onto the hardware rate (gotcha #27), and reading
    `outputFormat` before any connection returns the system default's rate instead. Silent
    rather than absent, so an OS that starts delivering input again cannot leak an unprocessed
    dry path around the chain.
    **The chain runs mono, and it has to.** The input channel map has already picked one of the
    device's channels (gotcha #26) and delivers it as channel 0, so a wider chain carries the
    interface's other inputs as passengers — thirteen of them on a 14-input Apollo. It is also
    the difference between working and silent: an `AVAudioMixerNode` fed 14 channels with no
    channel layout to downmix by emits silence, which is what the first version of this fix
    measured, while mono into the stereo mixer measured −14.0 dBFS on the same graph.
    **There is now an output meter, and it exists because of this.** Capture and the route out
    to the virtual device fail identically — exact digital silence with every layer reporting
    success — so one meter left "no audio in Discord" ambiguous between them. `input peak` and
    `output peak` are logged together: input moving with output at zero is the graph losing it,
    both at zero is capture. `PLUGINPUT_TEST_TONE=1` swaps the chain's head for a 440Hz tone of
    known amplitude, which proves the whole output leg without a microphone.

37. **An input tap will not call back more often than every 100ms, so a buffer holding less
    than 100ms of audio loses the difference — silently, and at a constant rate.** Asking for
    512 frames at 48kHz produced 4096-frame buffers *still arriving every 100ms*. 4096 frames is
    85ms of audio, so the ~704 frames the hardware produced beyond each buffer were gone before
    the tap saw them. Measured at **41,015 frames/sec supplied against 48,058 requested** over
    74 seconds — 4096/4800 to three decimal places, and rock steady, which is what distinguishes
    it from jitter.
    **It sounds like crunch, not like dropouts**, because `InputRingBuffer` zero-fills a short
    read rather than stalling: the shortfall is spread across every cycle as short gaps. The
    counters name it outright — `starved` climbing while `dropped` stays at zero is a supply
    shortfall, and the reverse is a consumer that has stopped.
    So the tap size has to come from the **sample rate**, since the floor is fixed in *time*:
    `inputTapSeconds` is 0.125, giving 25% of margin over the floor and measuring 48,000
    frames/sec with starvation flat at zero. Do not replace it with a constant — a constant that
    works at 48kHz is short at 96kHz. Do not lower it below 0.1 for latency, either; that is the
    cliff, and the whole failure is silent.
    The ring was also **exactly one tap buffer deep**, which is the worst available size: the
    render emptied it before each next callback landed, so every scheduling jitter became
    another gap. It is several buffers deep now.

## Persistence

`~/Library/Application Support/PlugInput/session.json` holds one `SessionSnapshot`:
`inputUID`, `chain`, `isRunning`, and `isMonitorEnabled`. `chain` is an ordered list of slots,
each carrying an `id`, its `plugin` (the component triple, not the display name), `state`
(base64 of a binary plist of `auAudioUnit.fullState`), and `isBypassed`.

**Both older shapes still decode**, through a hand-written `init(from:)`. That is load-bearing
twice over. A synthesised `Codable` treats a missing key for a non-optional property as a
decoding *failure*, and `AppModel` answers a failed load by discarding the whole session — so
`isMonitorEnabled` decodes with `decodeIfPresent ?? true`, and adding any field without that
would silently wipe a user's saved setup. And a pre-chain file carries `plugin` + `pluginState`
instead of `chain`; those migrate into a **one-slot chain with the state intact** rather than
being dropped, because the point of saving dial positions is that upgrading does not cost them.
Three tests cover it, and it was verified against a real pre-chain file: Pro-L 2 and its 604-byte
state blob came through.

Written on every user choice, on a 30-second autosave while any plugin is loaded, and on quit;
read once at launch by `AppModel.restore()`, which reinstates the whole chain in order and
resumes the engine if it was running. A slot whose plugin no longer instantiates is **dropped**
from the chain and logged, rather than left as a gap — a chain that reads as four effects while
three are audible is exactly the silent discrepancy this app exists to avoid.

Two invariants are load-bearing. `SessionSnapshot` drops `pluginState` whenever `plugin`
changes — a state blob means nothing to a different plugin, and feeding it to one in-process
is a way to crash the host. And a failed `start()` writes `isRunning: false`, or a launch that
cannot start keeps retrying forever.

That file is also the readout when the UI cannot be clicked: it says which plugin loaded and
whether the engine actually started. Delete it to reset the app.

## Next steps

- **Cut v0.9.1 — the first decision, because everything in it is already written and pushed.**
  `main` carries four real bug fixes (gotchas #29–#34) plus the icon and version readout, and
  no tag points past v0.9.0. Every user is on v0.9.0 and still has all four bugs. The whole
  release is `./make-pkg.sh --notarize`; the credentials are in place and unchanged. Bump
  `./VERSION` first — it still reads 0.9.0, and macOS refuses to upgrade to a package whose
  version is not greater than the installed one. The one thing worth doing *before* that is the
  chain-UI pass below, since a release is the natural moment to have clicked the buttons at
  least once.
- **Confirm the chain UI by hand — still nobody's clicked it.** It shipped in v0.9.0 unclicked,
  the release notes say so, and a first user reaches it before anyone here does. The engine below
  it is measured; the buttons are not. One pass: add two or three effects, reorder with ↑/↓,
  toggle bypass while running (should be seamless — it is the one edit that does not cycle the
  engine), open two plugin windows at once, remove one. `chain: added` / `chain: removed` /
  `chain: reordered to …` in the log are the readout.
  **Two of the recent fixes are only provable here.** Removing a slot is what triggered the
  disposal crash (gotcha #29), and a plugin window surviving interaction and close is what the
  view-controller fix (gotcha #30) is for. Both are proven at the mechanism level and neither has
  been proven by clicking.

- **Distribution is DONE and two of the decisions are not worth relitigating.**
  Direct distribution with a notarized `.pkg`, and the driver bundled under GPL-3.0
  compliance. Both are executed as of v0.9.0. The second forces the first: GPL-3.0's anti-Tivoization terms conflict with
  App Store terms, so **the Mac App Store is closed off** for as long as the driver ships
  inside the installer. The fallback, if that ever inverts, is to unbundle the driver and have
  users install BlackHole themselves — which costs the "PlugInput" device name.
  `make-pkg.sh` refuses to build if the driver's `LICENSE` is missing, because that is the one
  packaging mistake a later build cannot correct.

- **Naming the mic "PlugInput" is DONE — via a driver, not an aggregate.** `make-driver.sh`
  builds a renamed BlackHole (`kDriver_Name` / `kDevice_Name`, pinned to v0.6.1) and installs it
  to `/Library/Audio/Plug-Ins/HAL`. Other apps now select **PlugInput**. The aggregate routes
  stay closed — do not revisit #17 or #19 — but the conclusion drawn from them was wrong: it
  said the remaining route was "a substantially larger piece of work", when BlackHole
  *documents* renaming as a supported build-time customization. It is one `xcodebuild`.
  **GPL-3.0 obligations, and how they are met.** A renamed build is a derivative work, so
  recipients are owed the corresponding source. Since the rename is entirely build flags with no
  source edit, the corresponding source is BlackHole v0.6.1 plus `make-driver.sh` — which pins
  the tag and records every flag — so a public repository *is* the offer, with nothing extra to
  maintain. The license text ships inside the bundle, and README states plainly that this is a
  modified build, not the official binary, and not supported by Existential Audio. Contacting
  Existential Audio is a courtesy their README asks for, not a license term.
- **Chain presets.** The chain is already one `Codable` value, so saving named chains is close to
  free: a directory of `PluginChain` JSON beside `session.json`, and a picker. The invariant that
  each slot's state travels with its own plugin is what makes a preset portable.
- **Remaining UI polish:** an explicit monitor/output device picker — monitoring currently
  follows the system default output. The searchable browser, dB meter, routing summary, chain
  editor, latency badge, monitor toggle, input-channel picker, and activity log are done.
- **SSL Native Vocalstrip 2 crashed the app on quit — addressed at the process level, see gotcha
  #33.** It is a third-party exit-time race: the plugin's own JUCE timer thread segfaults on a
  null `pthread_mutex_lock` seconds *after* teardown finished, while static destructors tear down
  JUCE's globals underneath it. Gotcha #29 did **not** fix it — it reproduced on that build, which
  is recorded because an earlier note here guessed it might have. `prepareForQuit` now ends in
  `_exit`, so no vendor gets an exit-time turn at all. Reports are in
  `~/Library/Logs/DiagnosticReports/PlugInput-*.ips`.
- **The freeze is open and now instrumented.** It has never reproduced here, and the leading
  hypothesis was measured and ruled out (gotcha #32). `MainThreadWatchdog` logs any stall over
  2s at error level, so the next report should carry its own evidence — ask for
  `main thread unresponsive` lines from the unified log before theorising. Do not guess at a
  cause again without a number; that mistake is recorded in #32 precisely so it is not repeated.
- **Still missing for a confident v1:** crash reporting (with in-process plugin hosting, crash
  reports are the only way to learn which plugin broke someone's setup), and an update
  mechanism. Now that v0.9.0 is installed on other machines, retrofitting updates is the
  painful one — it is the next decision worth making, not a later one. The cheap version of it
  was costed and not built: read the GitHub releases API at launch, compare against
  `CFBundleShortVersionString`, and offer a link — no Sparkle, no signing keys, no auto-install,
  and the app is not sandboxed so it needs no new entitlement. **The app icon is done** — drawn
  in `Tools/render-icon.swift`, see "Recent changes".

Persistence and the login item are built — see "Persistence" above.

## Working on the audio path

Verify, do not assume. Every layer of this app reports success while producing silence, so
"it compiles", "the write returned `noErr`", and "the device was created" have each been wrong
here in a way that cost hours. The check that settles it is the two-process listener in
`Spike/`, because it stands outside the app entirely.

Four failures from this project's history, as calibration:

- A channel-map write returned `noErr` **and read back correctly** and still killed the start
  (#19).
- A device was created with the right channel counts and carried exact digital silence (#17).
- A tap was removed on every path that looked like it mattered, and leaked on the one that
  did (#14).
- A plugin GUI reopened cleanly and was wired to a unit the engine had already detached — the
  reason plugin windows are keyed by slot id rather than by unit or index.

UI paths have to be exercised by hand, and a click-level path nobody has clicked should not
be recorded as verified. Where a case can be reached without the mouse, `session.json` can be
edited directly to drive a restart-and-observe loop: that is how the monitor toggle was checked
in both positions, and how a three-plugin chain was checked end to end. A running app rewrites
that file on its 30-second autosave, so quit it before editing, and back it up first since it
holds a real setup.

**Getting that order wrong produces a green result, not an error.** A ten-cycle quit-crash test
was seeded while the app was still running; the app overwrote the seed with its own empty chain
on quit, every cycle then launched with no plugins at all, and the run reported zero crashes —
which is exactly what a fix looks like. It was caught only by counting `engine started` lines and
finding ten launches and zero starts. Assert that the seeded setup actually loaded before
believing what a scripted run tells you.

Quit with `osascript -e 'quit app "PlugInput"'` rather than `killall` when testing teardown.
`killall` skips `willTerminate`, so it neither destroys the aggregate (gotcha #7) nor exercises
the path that matters (gotcha #20).

## Conventions

Immutability (return new values, never mutate), small focused files, explicit error handling,
AAA-structured tests with descriptive names. `AudioCore` must never import a UI framework —
that boundary is what keeps the model layer testable, since the CoreAudio and `AVAudioEngine`
binding code is not meaningfully unit-testable and is covered by the Phase 0 spike instead.
