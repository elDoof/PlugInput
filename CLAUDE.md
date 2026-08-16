# PlugInput

A macOS menu bar app that puts audio plugins on your live microphone, so you can run a
compressor (or anything else) on your voice without opening a DAW — and have Zoom / Discord /
OBS see the processed signal as a microphone.

## Status: working and in daily use

Last verified 2026-08-15: **mic → AnalogObsession LALA → private aggregate → BlackHole**,
measured from a separate process at **−34.0 dBFS broadband** against a −120.0 dBFS silence
control. Also verified: 50/50 tests, `PlugInput.app` launches and stays resident, 677 AU
effects discovered, no orphaned aggregates, plugin switching survives an engine restart, the
monitor toggle mutes only the monitor leg, and session persistence against a real Audio Unit.

Reproduce it with the app running and a plugin loaded:

```bash
cd Spike && ./.build/debug/PlugInputSpike listen 4 BlackHole
```

Broadband well above −120.0 dBFS is the proof. Two traps in reading that number: ignore the
harness's `RESULT: FAIL`, which looks for the Phase 0 440Hz tone that a microphone does not
emit; and **give the engine a few seconds after launch** — listening too early reads −120.0 and
looks exactly like a real failure.

### Version control

The project is a git repo, pushed to **`github.com/elDoof/PlugInput` (private)**, single branch
`main`. `.gitignore` keeps `.build/` (~650M), `PlugInput.app/`, and `.claude/settings.local.json`
out. `README.md` is the human-facing doc — what the app is, how to run it, known limitations.
**This file is the engineering companion to it**; keep the overlap thin and let README describe
*use* while this describes *why*.

### What the last session changed

Four user-visible fixes, all verified rather than assumed:

- **Crash on plugin switch** — a leaked input tap (gotcha #14).
- **Silent microphone** — two independent causes: the input resolver could pick BlackHole
  (gotcha #15), and ad-hoc signing dropped the TCC grant every rebuild (gotcha #13).
- **Intermittent UI freeze** — `OSLogStore` and CoreAudio queries on the main actor
  (gotcha #18).
- **Monitor on/off checkbox** — mutes the monitor leg of the output channel map without
  touching what other apps receive.

And one deliberate non-delivery: naming the virtual mic "PlugInput" (gotchas #17, #19). Both
aggregate routes were built, measured, and reverted. Do not start a third attempt without
reading those two entries — the remaining route is a real HAL driver.

## Build and run

```bash
swift build && swift test     # library + 50 unit tests
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
  Plugins/     PluginCatalog, PluginDescriptor, PluginState, PluginSearch
  Persistence/ SessionSnapshot, SessionStore
  Diagnostics/ EngineLog, EngineLogReader, AudioLevel
Sources/ObjCExceptionBridge/  the only Objective-C in the project — @try/@catch, see gotcha #21
Sources/PlugInput/       AppModel, PlugInputApp, MenuBarContentView, PluginWindowController,
                         LoginItem
  Views/       ConsoleView (window: chain, meter, activity), PluginBrowserView (search)
Tests/AudioCoreTests/    50 tests
Spike/                 Phase 0 verification harness — separate package, kept as reference
```

Signal path: **mic → [effect] → private aggregate device → headphones + BlackHole 2ch**.
Other apps select BlackHole as their microphone. BlackHole was already installed on this
machine; the app does not ship a driver.

## Decisions already made — do not relitigate

- **Audio Units, not VST3.** The user asked for VST originally. This machine has 710 AU
  components vs 366 VST3 bundles, and *every* vendor in the library ships both (iZotope's AU
  bundles are just named `iZOzone12AUHook.component`, which is what made the VST3 list look
  exclusive). AU hosting is native `AVAudioEngine`, gets real plugin GUIs free via
  `requestViewController`, and avoids JUCE and its GPL/commercial licensing question entirely.
- **Both monitoring and virtual mic**, not one or the other.
- **Menu bar utility** (`MenuBarExtra`), not a windowed app.
- **One effect slot in v1**, not a chain — a deliberate scope cut, not an oversight.

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
9. Buffer floor on the aggregate is 15 frames; 128 ≈ 2.7 ms. Latency is not a concern.
10. **The input tap must not capture `self`.** `AudioEngineController` is `@MainActor`, and
    AVFAudio calls the tap on `RealtimeMessenger.mServiceQueue`. Touching main-actor state
    from there trips Swift's executor check and kills the process with `EXC_BREAKPOINT` on the
    **first audio buffer** — so the app dies the instant audio starts moving, not at launch,
    which is how it survived every build-and-launch check. `PeakLevel` exists to be the only
    thing that closure captures. This one was found the hard way; see the crash report at
    `~/Library/Logs/DiagnosticReports/PlugInput-2026-08-14-085048.ips`.
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
    Removal is now unconditional and tracked by `isTapInstalled`. Three `.ips` files on
    2026-08-14 (09:54, 10:21, 10:22) are this exact crash. General lesson: `engine.connect`,
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
    flow.** `VirtualMicrophone` is kept, unused, with this written on it; the route that avoids
    a second aggregate is in "Next steps".
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
    **Users select BlackHole.** Any future attempt needs a real virtual driver, not an
    aggregate.
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

## Persistence

`~/Library/Application Support/PlugInput/session.json` holds one `SessionSnapshot`:
`inputUID`, `plugin` (the component triple, not the display name), `pluginState` (base64 of a
binary plist of `auAudioUnit.fullState`), `isRunning`, and `isMonitorEnabled`.

`isMonitorEnabled` decodes with `decodeIfPresent ?? true` through a hand-written `init(from:)`.
That is load-bearing: a synthesised `Codable` treats a missing key for a non-optional property
as a decoding *failure*, and `AppModel` answers a failed load by discarding the whole session —
so adding any field to this struct without that would silently wipe a user's saved plugin and
device on the next launch. Covered by a test that decodes a pre-toggle session file.

Written on every user choice, on a
30-second autosave while a plugin is loaded, and on quit; read once at launch by
`AppModel.restore()`, which reinstates the plugin and resumes the engine if it was running.

Two invariants are load-bearing. `SessionSnapshot` drops `pluginState` whenever `plugin`
changes — a state blob means nothing to a different plugin, and feeding it to one in-process
is a way to crash the host. And a failed `start()` writes `isRunning: false`, or a launch that
cannot start keeps retrying forever.

That file is also the readout when the UI cannot be clicked: it says which plugin loaded and
whether the engine actually started. Delete it to reset the app.

## Next steps

- **#5 Chain:** immutable `PluginChain` (`adding`/`removing`/`moving`/`settingBypass` returning
  new values), with `AudioEngineController` diffing and rewiring `buildGraph`. `SessionSnapshot`
  grows from one `plugin` + `pluginState` to an ordered list; the invariant that state travels
  with its own plugin is what keeps that small. Touches `AppModel` and `buildGraph` only — not
  the device or channel-map logic.
- **Naming the mic "PlugInput" is closed off with aggregates — do not try a third time.**
  Both routes were built and measured, and both failed: a second public aggregate wrapping
  BlackHole delivers silence (gotcha #17), and reordering the engine's own aggregate to lead
  with BlackHole breaks `engine.start()` outright (gotcha #19). Renaming BlackHole is not
  possible either — `kAudioObjectPropertyName` is not settable. The only remaining route is
  **shipping an actual virtual audio driver** (a CoreAudio HAL plugin, i.e. what BlackHole
  itself is) under our own name, which is a substantially larger piece of work and would mean
  the app installs a system driver. Until then, users select BlackHole, and
  `VirtualMicrophone` holds only the naming constants plus the write-up of why.
- **Remaining UI polish:** monitor/output device pickers, and a latency badge. The searchable
  browser, dB meter, signal chain, monitor toggle, and activity log are done.

Presets, persistence, and the login item are built — see "Persistence" above.

## Working on this

Verify, do not assume. Every layer of this app reports success while producing silence, so
"it compiles", "the write returned `noErr`", and "the device was created" have each been wrong
here in a way that cost hours. The check that settles it is the two-process listener in
`Spike/`, because it stands outside the app entirely.

Three failures from the last session, as calibration:

- A channel-map write returned `noErr` **and read back correctly** and still killed the start
  (#19).
- A device was created with the right channel counts and carried exact digital silence (#17).
- A tap was removed on every path that looked like it mattered, and leaked on the one that
  did (#14).

The app cannot be clicked from a terminal session, so when a question needs a human — "does
switching plugins still work?" — ask rather than infer. `session.json` can be edited directly
to drive a restart-and-observe loop without clicking, which is how the monitor toggle was
verified in both positions; note that a running app rewrites that file on its 30-second
autosave, so kill it before editing.

## Conventions

Immutability (return new values, never mutate), small focused files, explicit error handling,
AAA-structured tests with descriptive names. `AudioCore` must never import a UI framework —
that boundary is what keeps the model layer testable, since the CoreAudio and `AVAudioEngine`
binding code is not meaningfully unit-testable and is covered by the Phase 0 spike instead.
