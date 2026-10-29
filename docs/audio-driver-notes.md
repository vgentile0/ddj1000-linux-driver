# DDJ-1000 Audio Driver Notes

Working state from the live tests:

- The stock Linux binding sees `DDJ1000`, but exposes only MIDI/control, no playback PCM.
- `snd-usb-audio quirk_alias=2b730020:2b730029` exposes a DDJ-1000 PCM as `S24_3LE`, 6 channel, 44.1 kHz on interface `0`, alt `1`, endpoint `0x01`, with implicit feedback/input on `0x82`.
- That alias produces short, quiet Booth bursts on real hardware, but `speaker-test` then fails with `Input/output error`.
- The DDJ-800 alias hides the normal DDJ raw MIDI port, so we cannot run the Rekordbox-style MIDI/HID startup sequence after binding the playback quirk.
- Running the START_04 replay before rebinding to the alias makes the controller visually enter the Rekordbox preload state, but the later rebind still leaves the same short Booth burst and EIO.

The next kernel-side experiment was therefore a real DDJ-1000 entry instead of `quirk_alias`. It keeps the MIDI interface available while adding the fixed vendor audio endpoints.

Prepared local test workflow:

```bash
./scripts/dev/prepare-ddj1000-snd-usb-audio-module.sh
```

This downloads Ubuntu kernel source into `/tmp`, applies the original quirk patch (kept as `patches/linux/upstream-original-6.17-BROKEN.patch`; its last `endpoint.c` hunk is malformed and silently skipped by `patch`), builds `snd-usb-audio.ko` against the installed kernel headers, copies the result to ignored `build/ddj1000-driver/`, and signs it with a local MOK key.

With Secure Boot enabled, a fresh machine still needs one manual MOK enrollment before the locally built module can be loaded:

Manual enrollment step:

```bash
sudo mokutil --import build/ddj1000-driver/ddj1000-linux-driver-mok.der
```

Then reboot. In the blue MOK Manager screen select `Enroll MOK`, confirm, enter the password chosen during `mokutil --import`, and reboot again.

After enrollment:

```bash
./scripts/dev/load-ddj1000-snd-usb-audio-test-module.sh
```

Current validated state from the latest live test:

- `scripts/dev/prepare-ddj1000-snd-usb-audio-module.sh` rebuilds cleanly against the running kernel, and `scripts/dev/load-ddj1000-snd-usb-audio-test-module.sh` loads the signed test modules on this machine.
- The patched bind exposes `DDJ1000` again to ALSA and keeps the standard MIDI path available in the same bind.
- `QUIRK_FLAG_PLAYBACK_FIRST` is required for the DDJ-1000, matching the Pioneer implicit-feedback startup order seen in Windows captures.
- The decisive runtime fix is in `sound/usb/endpoint.c`: when sync endpoint `0x82` returns an empty implicit-feedback URB, the sink must keep going with nominal pacing instead of aborting playback setup.
- With that fallback in place, the same `speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE ...` repro no longer dies immediately with `Input/output error`, and live hardware produced audible tone again.
- The device still withholds real payload on `0x82` under Linux during this test window; the current working path is therefore a validated fallback, not yet a full explanation of the device's native feedback behavior.

What the current patch in this repository actually changes:

- `sound/usb/quirks-table.h` adds a real DDJ-1000 composite quirk for `0x2b73:0x0020` instead of relying on `quirk_alias`.
- That quirk binds the vendor-specific playback path on `interface 0 alt 1` as fixed `44.1 kHz`, `S24_3LE`, 6-channel playback on `ep0x01` with implicit feedback from `ep0x82`.
- The same quirk keeps the regular USB-MIDI path available through `QUIRK_DATA_STANDARD_MIDI(2)`, which is required for the startup and unlock flow.
- `sound/usb/quirks.c` adds `QUIRK_FLAG_PLAYBACK_FIRST` for the DDJ-1000.
- `sound/usb/endpoint.c` is patched so empty implicit-feedback packets on `ep0x82` no longer abort the output path immediately; the sink falls back to nominal pacing instead.

Current reload and repro loop:

```bash
bash scripts/dev/prepare-ddj1000-snd-usb-audio-module.sh
```

Then re-run:

```bash
bash scripts/dev/load-ddj1000-snd-usb-audio-test-module.sh
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t sine -f 440 -l 1 -b 20000 -p 10000 -S 60
```

The loader script now also corrects an earlier dependency mistake:

- `modprobe mc snd_ump snd_usbmidi_lib` was wrong for `modprobe`; it treated `snd_ump` and `snd_usbmidi_lib` as parameters for `mc`.
- The corrected order is to load them separately and to insert the locally built `snd-usbmidi-lib-test.ko` before `snd-usb-audio-ddj1000.ko`.

Current success condition is stricter than mere enumeration: `aplay -l` should show `DDJ1000` playback, `amidi -l` should still show `DDJ-1000 MIDI 1` in the same driver bind, and the first `speaker-test` run should complete without `Input/output error`.

Known runtime signature of the current working fallback:

- Kernel log repeatedly prints `implicit fb sync urb on EP 0x82 carried no payload, using nominal pacing`.
- No matching `XRUN at starting EP` or immediate `speaker-test` `EIO` occurs in the same repro.
- This means the DDJ-1000 audio path is presently usable even though the Linux driver still is not receiving non-empty feedback payload from `0x82`.

Current playback-bus interpretation on the stable fallback path:

- The early `Booth left/right` and `Headphones left/right` reading came from a weaker first sweep and should no longer be treated as the current mapping.
- The stronger later live test with long 6-channel playback, real DDJ monitoring controls, and an analog cross-check supports a hybrid mixer reading instead.
- `1/2` is the currently confirmed `Master/Program` bus. It moves the Master meter, is audible on the connected Booth speakers, and reaches the headphones only when `Master Cue` is enabled.
- `3/4` is the currently confirmed software-fed `Cue/Monitor` bus. It stays silent with the headphone mix on `Master`, but becomes audible on headphones with the mix knob on `Cue` even without pressing `Master Cue`.
- `5/6` is still a real playback pair on the host-to-DDJ stream, but its role remains unresolved. `Sampler/Aux` is the current working hypothesis, not a confirmed fact.
- The ALSA slot labels from `speaker-test` should therefore not be treated as the physical DDJ-1000 routing map.
- In practice, the validated Linux fallback behaves like one 6-channel mixer-output PCM carrying three stereo software destinations, not four direct deck outputs.
- For higher-level software integration, the pragmatic working model remains: build at least `Master`, `Cue`, and potentially `Sampler/Aux` in software, then derive DDJ LEDs, meters, and other state from that software mixer state.

Important correction from the newer Windows ASIO captures:

- That 6-channel interpretation is still valid for the current Linux quirk, but it is no longer strong enough as a protocol conclusion about the native Windows path.
- In the newer controlled play captures, `ep0x01` is not permanently zero. Later in the stream it carries nonzero payload, but not as straightforward packed `S24_3LE` across six always-active slots.
- Under a simple 24-bit stereo view, later `ep0x01` packets show a repeated pattern of one active stereo pair followed by two zero stereo pairs. For `792`-byte packets this gives `44` nonzero stereo pairs out of `132`, and for `810`-byte packets `45` out of `135`.
- `ep0x82` also looks more structured than a plain six-channel linear stream: most packets fit a `36`-byte block view with four strongly active slots and two almost-empty tail slots.
- So the current best reading is: the Linux 6-channel quirk is a practical fallback that makes the observed transport usable, but the native Rekordbox ASIO mode may still use a vendor-specific packed layout that we have not decoded yet.

Why this repository stays at 6 playback channels:

- The current patch intentionally implements only the validated `6`-channel fallback on `interface 0 alt 1` with `ep0x01` OUT and `ep0x82` IN.
- There is no current evidence in this repository for a real `10`-channel Linux playback mode, so widening `.channels` to `10` would be speculative.
- The Windows capture work still leaves room for a more complex native transport, but it does not currently justify changing the working Linux quirk.
- Revisit a wider channel count only if a second transport mode, another output path, or clearly `10`-channel-sized payload behavior is actually confirmed.

Broad capture scan across the currently stored Windows captures:

- Startup, startup-plus-functions, idle baseline, deck load, play, tempo and key-change captures all show the same vendor-iso shape on interface `0 alt 1`.
- Across those captures, `ep0x01` only appears with the already known lengths `792`, `810`, plus the one-time activation outliers `828` and `864`.
- The matching `ep0x82` input side stays on `3168`, `3204`, plus the one-time activation outlier `3384`.
- No current capture shows a second `SET_INTERFACE` for another DDJ audio altsetting, and no later playback capture introduces a new `ep0x01` payload family that would fit a distinct 4-channel or 10-channel streaming mode.
- The explicit no-audio comparison capture now sharpens the boundary condition: HID and MIDI traffic still run, but `SET_INTERFACE if=0 alt=1` and the whole `ep0x01`/`ep0x82` vendor-iso pair never appear.
- The reusable scan for this question is not part of this repository.
- The newer iso-payload inspection adds one more nuance: even without a second altsetting, the active ASIO path may still encode more structured deck/mixer data inside the same `792/810` and `3168/3204` packet families than our current linear-PCM fallback assumes.

Minimal per-channel verification commands:

```bash
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t sine -f 440 -s 1 -l 1 -b 20000 -p 10000 -S 60
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t sine -f 440 -s 3 -l 1 -b 20000 -p 10000 -S 60
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t sine -f 440 -s 5 -l 1 -b 20000 -p 10000 -S 60
speaker-test -D hw:DDJ1000,0 -c 6 -r 44100 -F S24_3LE -t sine -f 440 -s 4 -l 1 -b 20000 -p 10000 -S 60
```
