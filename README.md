# Slippi Dolphin for ROCKNIX (aarch64)

A port of [Slippi Ishiiruka](https://github.com/project-slippi/Ishiiruka) to ROCKNIX on aarch64 devices. Tested on the **AYN Thor Max** (Snapdragon 8 Gen 2, Adreno 740). The AYN Odin2 shares the same SoC and should work but has not been tested yet. I don't have any other devices to test on.

> **ROCKNIX compatibility note:** [ROCKNIX](https://github.com/ROCKNIX/distribution-nightly) is itself still in prerelease and its features change frequently. This port was developed with **ROCKNIX nightly-20260508**. Newer nightly builds may change the display server, audio stack, or system library paths in ways that break compatibility. If something stops working after a ROCKNIX update, check the known issues section and open an issue with your nightly version.

---

## What's fixed

The initial build had several issues on aarch64 + Adreno GPUs that needed to be addressed:

- **Colored rectangles at hit contact points** — Adreno 740 uses ASTC, not BC/DXT compression. Ishiiruka unconditionally claimed DXT support, causing CMPR textures to be uploaded as `VK_FORMAT_BC2_UNORM_BLOCK` and rendering as solid colored squares. Fixed by gating on `features.textureCompressionBC`.
- **Effect/fire textures wrong color or square** — Fixed by enabling GPU texture decoding in the Vulkan backend, which decodes all textures natively on the GPU bypassing the CPU path that had R↔B channel swaps on ARM.
- **No audio on ROCKNIX nightly (Sway/PipeWire)** — Fixed by using the Cubeb audio backend and pinning `PULSE_SERVER` to ROCKNIX's non-standard socket path (`/run/pulse/native`).
- **Crash when launching from Sway terminal** — ROCKNIX nightly switched to Sway (Wayland). Terminals inherit `WAYLAND_DISPLAY`, causing GTK to pick Wayland and crash on X11-specific API calls. Fixed by forcing `GDK_BACKEND=x11` and `QT_QPA_PLATFORM=xcb` through XWayland.
- **Sluggish emulation / audio underruns** — ROCKNIX nightly defaults to the `ondemand` CPU governor, leaving cores at ~1 GHz. The launcher pins all cores to `performance` for the session and restores the original governor on exit. This unfortunately drains the battery faster than necessary, and will hopefully be fixed at some point.

---

## Known issues

The following issues are known and not yet fixed:

- ~~**Launch and exit must be done over SSH.** There is no in-game button combo to quit yet, and no EmulationStation integration. You must SSH into the device to launch and kill the process. See [Usage](#usage) below.~~ Can now launch through the ports menu in ES, and quit by pressing start+select on the handheld.
- ~~**~10-15 second boot delay before the game starts.** The Vulkan backend pre-compiles all cached shader pipelines synchronously before launching the game. Fix in progress (maybe async compilation after boot, during matchmaking window?).~~ Fixed. This wasn't the problem at all, I'm dumb
- **GTK warnings on startup** (`gtk_box_gadget_distribute`, `Could not load a pixbuf from bullet-symbolic.svg`). These are cosmetic — settings dialogs render slightly incorrectly but function normally. Does not affect gameplay.
- **"Desync risk" warning during gameplay** Triggered by `EnableGPUTextureDecoding = True`, which we require on Adreno to fix texture artifacts. This setting only affects rendering, not game state, and should not be able to cause a desync. Warning is a very likely a false positive, and I've had no issues so far.
- ~~**Settings changed in the GUI may not persist correctly.** All important settings are managed via the deploy script and written directly to ini files. Use the deploy script to change settings rather than the in-game GUI.~~ Fixed.
- **Official GameCube controller adapter support verified yet.** Not really an issue, but I just haven't tested it yet. The udev rule is deployed so it might work, idk. Played using an Input Integrity adapter. GCPocket+ should also work. 
- **Half-Rate Polling** Input Integrity adapter polls at 500hz instead of 1000hz. Will troubleshoot after first release.

  
---

## Requirements

- ROCKNIX on an aarch64 device with Adreno 740 (AYN Odin2 / Thor Max)
- Melee NTSC 1.02 ISO (`md5: 0e63d4223b01d9aba596259dc155a174`)
- SSH access to the device (enabled in ROCKNIX → Settings → Services)

---

## To Do:
- Installer with instructions
- Fix controller polling rate



## Build from source

Tested on Debian 12 (Bookworm) aarch64. Should work on any aarch64 Linux with equivalent packages.

### 1. Install dependencies

```sh
apt-get install -y \
  cmake ninja-build pkg-config \
  libwxgtk3.2-dev libgtk-3-dev \
  libgl-dev libglvnd-dev \
  libsfml-dev \
  libpulse-dev libasound2-dev \
  libcurl4-openssl-dev \
  libmbedtls-dev libminiupnpc-dev \
  libenet-dev libusb-1.0-0-dev \
  libudev-dev libevdev-dev \
  libxi-dev libxinerama-dev \
  libglib2.0-dev
```

Install Rust (1.70+):

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

### 2. Build Dolphin

```sh
bash build-linux.sh
```

### 3. Build gdk-pixbuf loaders (one-time)

ROCKNIX ships a broken gdk-pixbuf where the loaders cache references files that don't exist on the read-only squashfs. This builds a clean replacement:

```sh
apt-get install -y meson libpng-dev libjpeg62-turbo-dev
bash scripts/build-gdk-pixbuf.sh
```
Likely not needed on other distros.

### 4. Deploy to device

```sh
bash scripts/deploy-rocknix.sh <device-ip>
```

With no IP argument, builds a local bundle at `dist/slippi-dolphin/` without transferring.

---

## Credits

Built on [Slippi Ishiiruka](https://github.com/project-slippi/Ishiiruka) by the [Project Slippi](https://slippi.gg) team.

Thanks to the [ROCKNIX](https://github.com/ROCKNIX/distribution-nightly) team for their ongoing work on open source handheld Linux gaming.
