# ddj1000-linux-driver

> **Fork notes (Debian 13 / MX Linux 25, kernel 6.12)**
>
> This fork changes how the audio driver is built and installed:
>
> - **DKMS package** (`dkms/`): the patched `snd-usb-audio` and
>   `snd-usbmidi-lib` are rebuilt automatically for every new kernel.
>   Sources come from Debian's `linux-source-X.Y` package instead of a
>   hard-coded Ubuntu `linux-hwe-6.17` download.
> - **Fixed kernel patch** (`patches/linux/snd-usb-audio-ddj1000-6.12.patch`):
>   the last `endpoint.c` hunk of the original patch (the empty
>   implicit-feedback fallback that the notes call the decisive fix) was
>   malformed and silently skipped by `patch`. It is rebuilt here, limited to
>   the DDJ-1000 USB ID, with per-URB logging moved to debug level.
>   The original is kept as `patches/linux/upstream-original-6.17-BROKEN.patch`.
> - Install with `bash scripts/install-ddj1000-linux-stack.sh install`
>   (needs Internet the first time for `dkms`, headers and `linux-source`).
> - Italian install guide for an offline MX Linux PC: `INSTALL-MX.md`.

## Supported versions (read this first)

This fork has been built and tested on **one exact setup only**. Other
versions may work, but are not supported.

| Component | Tested version |
|---|---|
| Distribution | **MX Linux 25.3 "Infinity", Xfce, x64** (standard edition, **not AHS**) |
| Debian base | Debian 13.7 "trixie" |
| Init system | **systemd** (required: the stack uses systemd units) |
| Kernel | **6.12.113+deb13-amd64** (Debian package `6.12.113-1`) |
| Kernel sources | `linux-source-6.12` **6.12.113-1** (must match the kernel) |
| Controller | Pioneer DJ / AlphaTheta DDJ-1000, USB ID `2b73:0020` |

Why so strict:

- The kernel patch exists only for the **6.12** series
  (`patches/linux/snd-usb-audio-ddj1000-6.12.patch`). It was verified to apply
  on 6.12.107 and 6.12.113. Other series (6.13+, backports kernels) need a new
  patch.
- DKMS builds from Debian's `linux-source-6.12` package, which must have the
  **same version** as the running `linux-image`. A mismatch is reported with a
  warning and may produce a module that does not load.
- **MX Linux AHS** uses a Liquorix kernel: not supported.
- **sysvinit** (the default boot entry on MX) is not supported.

### How to get exactly this setup

1. **ISO**: download *MX-25.3 Xfce x64* (the standard one, not "AHS") from the
   official site <https://mxlinux.org/download-links/> and check its SHA256
   against the `.sha256` file published next to it.
2. **Install** normally. In the boot menu (live and installed system) choose
   the entry ending in **(systemd)**. Check with `ps -p 1 -o comm=` → `systemd`.
3. **Kernel 6.12.113**: update and install the exact packages
   ```
   sudo apt update
   sudo apt install linux-image-6.12.113+deb13-amd64 \
                    linux-headers-6.12.113+deb13-amd64 \
                    linux-source-6.12=6.12.113-1
   sudo reboot
   uname -r            # must print 6.12.113+deb13-amd64
   ```
4. **Freeze the kernel** so updates cannot replace it:
   ```
   sudo apt-mark hold linux-image-amd64 linux-headers-amd64 \
     linux-image-$(uname -r) linux-headers-$(uname -r) linux-source-6.12
   ```
5. Install the stack: `bash scripts/install-ddj1000-linux-stack.sh install`,
   then reboot once so the patched module replaces the one already in memory.

**If 6.12.113-1 is no longer in the Debian repositories** (Debian keeps only
the newest security build), fetch it from the official Debian snapshot archive
of the day it was current:

```
echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20261029T130000Z/ trixie-security main' \
  | sudo tee /etc/apt/sources.list.d/snapshot-6.12.113.list
sudo apt update
sudo apt install linux-image-6.12.113+deb13-amd64 \
                 linux-headers-6.12.113+deb13-amd64 \
                 linux-source-6.12=6.12.113-1
sudo rm /etc/apt/sources.list.d/snapshot-6.12.113.list
sudo apt update
```

Verify that kernel and sources match before installing the driver:

```
dpkg-query -W -f='${Version}\n' linux-source-6.12 linux-image-$(uname -r)
# both lines must read 6.12.113-1
```

Experimental Linux audio-driver and host-stack work for the AlphaTheta / Pioneer DJ DDJ-1000.

This repository contains standalone Linux-facing DDJ-1000 transport, install flow, and validation work for discussion, testing, and publication.

## What This Repo Does

- installs a patched `snd-usb-audio` plus `snd-usbmidi-lib` override for DDJ-1000 Linux bring-up
- installs udev rules for `hidraw` and vendor USB access
- exposes named ALSA PCMs for the currently validated playback buses
- runs a user-session unlock keepalive plus a system rebind helper so the controller clears `NO AUDIO DRIVER`
- keeps the Linux-specific driver, patch, and runtime integration work isolated in a dedicated repository

## Current Status

- installable as an experimental bring-up stack
- this fork: tested only on MX Linux 25.3 / kernel 6.12.113 (see "Supported versions")
- still hardware-dependent and not yet a polished end-user package
- only the `Master` desktop sink is exported through `pactl`; `Cue` and `Aux` remain ALSA-only today
- licensed as `GPL-2.0-only` for kernel-adjacent patching and redistribution clarity
- static validation exists through `scripts/validate-repo.py` and `.github/workflows/static-checks.yml`

## Quick Start

Install base Linux dependencies and udev rules:

```bash
bash scripts/setup-linux.sh all
```

Run the repository validation check:

```bash
python3 scripts/validate-repo.py
```

Install the full stack:

```bash
bash scripts/install-ddj1000-linux-stack.sh install
```

Check the current state:

```bash
bash scripts/install-ddj1000-linux-stack.sh status
```

Remove it again:

```bash
bash scripts/install-ddj1000-linux-stack.sh uninstall
```

## Current Limits

- this is not an upstream-quality kernel driver package yet
- DKMS packaging exists for kernel series 6.12 only (add a patch per series)
- Secure Boot still requires a manual local MOK enrollment step
- the module build flow is still tailored to Debian or Ubuntu style kernel-source packaging
- there is no proven cross-distro reproducibility yet
- the `5/6` playback bus is still not conclusively named
- end-to-end runtime validation still depends on real DDJ-1000 hardware and a Linux machine with audio, MIDI, and USB access

## Repository Layout

- `scripts/` contains the main user-facing setup and install entry points
- `scripts/runtime/` contains the installed host-stack runtime helpers
- `scripts/dev/` contains developer-only kernel-module prep and test-load helpers
- `config/` contains ALSA, udev, systemd, and runtime assets
- `patches/` contains the Linux kernel patch for the DDJ-1000 composite audio quirk
- `docs/` contains install, audio-driver, and validation notes

## Validation

Run the repository validation check without hardware:

```bash
python3 scripts/validate-repo.py
```

This verifies required files, repo-local references, systemd `ExecStart` targets, and Python shebang consistency.

For real-hardware validation by other Linux developers, use the checklist in `docs/validation.md` so test reports come back in a comparable format.

## Legal And Trademark Notice

This project is an independent interoperability effort. It is not affiliated with, endorsed by, or sponsored by AlphaTheta Corporation, Pioneer DJ, or rekordbox.

`AlphaTheta`, `Pioneer DJ`, `DDJ-1000`, and `rekordbox` are referenced only to identify compatible hardware, software environments, and observed protocol behavior. All third-party product names, logos, and trademarks remain the property of their respective owners.

The implementation in this repository is based on original Linux integration work, protocol observation, device-capture review, and reverse engineering for interoperability and compatibility. This repository is not intended to ship vendor source code, copied rekordbox application code, or proprietary Pioneer / AlphaTheta driver binaries.

## Maintainer

- recommended copyright line: `Copyright (C) 2026 Jan Kaup`
- maintained by `Jan Kaup` / `Kaup Audio Labs`
- this repository stands on its own as a Linux interoperability and bring-up project for the DDJ-1000

## Documents

- `docs/install.md`
- `docs/audio-driver-notes.md`
- `docs/validation.md`

## Support

- support / updates: `https://ko-fi.com/fourfourmusic`
