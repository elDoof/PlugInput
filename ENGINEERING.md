# PlugInput

A macOS menu bar app that puts audio plugins on your live microphone, so you can run a
compressor (or anything else) on your voice without opening a DAW — and have Zoom / Discord /
OBS see the processed signal as a microphone.

## Status: working and in daily use

The routing is measured, not assumed: **mic → effect chain → private aggregate → PlugInput**,
read from a separate process at **−33.4 dBFS broadband** against a −120.0 dBFS silence control,
with the app's own log line reading `virtual PlugInput`. The renamed HAL driver measures
**−14.0 dBFS bit-exact** on the two-process tone test (gotcha #22). Also verified: the unit
tests, `PlugInput.app` launching and staying resident, several hundred AU effects discovered, no
orphaned aggregates, a three-plugin chain wiring in the logged order (duplicates included), a
pre-chain `session.json` migrating with its state intact, the monitor toggle affecting only the
monitor leg, and the exception barrier catching a real double-tap raise.

The **graph/hardware sample-rate mismatch is fixed** (gotcha #27): all six format numbers now
agree at the hardware rate, and the full UAD + SSL chain measures **−30.9 dBFS broadband** from
a separate process against a −120.0 dBFS control.

**Not verified from here:** the click-level chain UI — adding, reordering with ↑/↓, toggling
bypass, opening several plugin windows. The engine below it is verified; the buttons are not.
That pass is still worth doing; see "Working on the audio path".

Reproduce it with the app running and a plugin loaded:

```bash
cd Spike && ./.build/debug/PlugInputSpike listen 4 PlugInput
```

Broadband well above −120.0 dBFS is the proof. Two traps in reading that number: ignore the
harness's `RESULT: FAIL`, which looks for the Phase 0 440Hz tone that a microphone does not
emit; and **give the engine a few seconds after launch** — listening too early reads −120.0 and
looks exactly like a real failure.

### Version control

Single branch `main`. `.gitignore` keeps `.build/` (~650M), `PlugInput.app/`, and built
installers out. `README.md` is the user-facing doc: what the app is, how to install it, known
limitations. **This file is the engineering companion to it**; keep the overlap thin and let
README describe *use* while this describes *why*.

### Recent changes

Two features, in this order — the first exists to make the second safe:

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
swift build && swift test     # library + 63 unit tests
./make-driver.sh install      # builds + installs the PlugInput HAL driver (sudo, once)
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
  Engine/      EngineDeviceBinding, AudioEngineController, PeakLevel, ObjCExceptionBarrier
  Plugins/     PluginCatalog, PluginDescriptor, PluginState, PluginSearch, PluginChain
  Persistence/ SessionSnapshot, SessionStore
  Diagnostics/ EngineLog, EngineLogReader, AudioLevel
Sources/ObjCExceptionBridge/  the only Objective-C in the project — @try/@catch, see gotcha #21
Sources/PlugInput/       AppModel, PlugInputApp, MenuBarContentView, PluginWindowController,
                         LoginItem
  Views/       ConsoleView (window: routing, meter, activity), ChainEditorView (reorder,
               bypass, remove), PluginBrowserView (search, adds to the chain)
Tests/AudioCoreTests/    71 tests
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

−14.0 dBFS is bit-exact against the emitted amplitude. Re-run this if routing ever regresses;
it isolates the audio path from the UI completely.

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

- **Distribution is settled, and two of the decisions are not worth relitigating.**
  Direct distribution with a notarized `.pkg`, and the driver bundled under GPL-3.0
  compliance. The second forces the first: GPL-3.0's anti-Tivoization terms conflict with
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
- **Confirm the chain UI by hand.** The engine below it is measured; the buttons are not. Worth
  one pass: add two or three effects, reorder with ↑/↓, toggle bypass while running (should be
  seamless — it is the one edit that does not cycle the engine), open two plugin windows at
  once, remove one. `chain: added` / `chain: removed` / `chain: reordered to …` lines in the log
  are the readout.
- **Chain presets.** The chain is already one `Codable` value, so saving named chains is close to
  free: a directory of `PluginChain` JSON beside `session.json`, and a picker. The invariant that
  each slot's state travels with its own plugin is what makes a preset portable.
- **Remaining UI polish:** an explicit monitor/output device picker — monitoring currently
  follows the system default output. The searchable browser, dB meter, routing summary, chain
  editor, latency badge, monitor toggle, input-channel picker, and activity log are done.
- **Still missing for a confident v1:** an app icon, crash reporting (with in-process plugin
  hosting, crash reports are the only way to learn which plugin broke someone's setup), and an
  update mechanism. Retrofitting updates onto already-installed copies is painful, so it is
  worth deciding before 1.0.

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

Quit with `osascript -e 'quit app "PlugInput"'` rather than `killall` when testing teardown.
`killall` skips `willTerminate`, so it neither destroys the aggregate (gotcha #7) nor exercises
the path that matters (gotcha #20).

## Conventions

Immutability (return new values, never mutate), small focused files, explicit error handling,
AAA-structured tests with descriptive names. `AudioCore` must never import a UI framework —
that boundary is what keeps the model layer testable, since the CoreAudio and `AVAudioEngine`
binding code is not meaningfully unit-testable and is covered by the Phase 0 spike instead.
