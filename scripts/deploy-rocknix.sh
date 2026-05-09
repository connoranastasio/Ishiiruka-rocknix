#!/usr/bin/env bash
# deploy-rocknix.sh — bundle Slippi Dolphin + ALL required libs for ROCKNIX
#
# Usage:
#   bash scripts/deploy-rocknix.sh [rocknix-ip]
#
# With no IP: builds a local bundle at dist/slippi-dolphin/
# With an IP:  also transfers it to root@<ip>:/storage/slippi-dolphin/
#
# Philosophy: bundle everything except the GPU/display stack and C runtime.
# ROCKNIX is a read-only squashfs that ships with broken gdk-pixbuf (loaders
# missing from the image). Full isolation means ROCKNIX updates can't break us.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES="$REPO_ROOT/build/Binaries"
DIST="$REPO_ROOT/dist/slippi-dolphin"
ROCKNIX_IP="${1:-}"
ROCKNIX_DEST="root@${ROCKNIX_IP}:/storage/slippi-dolphin"

die() { echo "error: $*" >&2; exit 1; }

# ---- Exclusion list: ONLY these libs come from the device --------------------
# Everything else is bundled so we're isolated from ROCKNIX updates.
SYSTEM_LIB_PATTERNS=(
    # C / C++ runtime — must match the running kernel ABI
    "libc.so"
    "libm.so"
    "libdl.so"
    "libpthread.so"
    "libresolv.so"
    "librt.so"
    "libstdc++.so"
    "libgcc_s.so"
    "ld-linux"
    # GPU / display — must come from the device's driver stack
    "libGL"
    "libGLX"
    "libGLdispatch"
    "libEGL"
    "libGLESv"
    "libdrm"
    "libvulkan"
    "libwayland"
    "libX11"
    "libXext"
    "libXau"
    "libXdmcp"
    "libxcb"
    "libxkbcommon"
    # Audio — must match device's PipeWire/ALSA stack; bundling causes version mismatch
    "libasound.so"
    "libpulse.so"
    "libpulsecommon"
    "libpipewire"
    # Kernel / device interface
    "libudev"
    "libdbus"
    "libsystemd"
    "libmount"
    "libblkid"
    "libuuid"
)

is_system_lib() {
    local lib="$1"
    for pat in "${SYSTEM_LIB_PATTERNS[@]}"; do
        [[ "$lib" == ${pat}* ]] && return 0
    done
    return 1
}

# ---- 1. sanity checks -------------------------------------------------------

[[ -f "$BINARIES/dolphin-emu" ]] \
    || die "binary not found — run 'bash build-linux.sh' first"

GDK_PIXBUF_SO="$REPO_ROOT/build/gdk-pixbuf/libgdk_pixbuf-2.0.so.0"
[[ -f "$GDK_PIXBUF_SO" ]] \
    || die "gdk-pixbuf build not found at build/gdk-pixbuf/ — run 'bash scripts/build-gdk-pixbuf.sh' first"

# ---- 2. fresh dist directory ------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST/libs" "$DIST/gdk-loaders"

# ---- 3. collect shared library dependencies ---------------------------------

echo "==> Collecting shared library dependencies..."

collect_libs() {
    local binary="$1"
    ldd "$binary" 2>/dev/null | awk '/=>/ { print $3 }' | grep -v '^$' | grep "^/"
}

SLIPPI_SO=$(find "$REPO_ROOT/build" -name "libslippi_rust_extensions.so" | head -1)
[[ -f "$SLIPPI_SO" ]] || die "libslippi_rust_extensions.so not found in build/"

ALL_LIBS=$(
    collect_libs "$BINARIES/dolphin-emu"
    collect_libs "$SLIPPI_SO"
)

BUNDLED=0
SKIPPED=0
while IFS= read -r libpath; do
    libname=$(basename "$libpath")
    if is_system_lib "$libname"; then
        (( SKIPPED++ )) || true
        continue
    fi
    # gdk-pixbuf is handled separately below — skip the system version
    [[ "$libname" == "libgdk_pixbuf-2.0.so.0" ]] && continue
    if [[ ! -f "$DIST/libs/$libname" ]]; then
        cp "$libpath" "$DIST/libs/$libname"
        (( BUNDLED++ )) || true
    fi
done <<< "$ALL_LIBS"

cp "$SLIPPI_SO" "$DIST/libs/"

echo "    Bundled $BUNDLED libs, skipped $SKIPPED system libs"

# ---- 4. gdk-pixbuf: our own build with no builtins --------------------------
# ROCKNIX ships gdk-pixbuf with a stale loaders.cache that lists PNG/JPEG as
# external .so files that don't exist on the squashfs — breaking all GTK apps.
# We bundle a fresh build compiled with builtin_loaders=none so every format
# is an explicit .so in gdk-loaders/, fully under our control.

echo "==> Installing self-built gdk-pixbuf (no builtins)..."
cp "$GDK_PIXBUF_SO" "$DIST/libs/libgdk_pixbuf-2.0.so.0"

LOADERS_SRC="$REPO_ROOT/build/gdk-pixbuf/loaders"
cp "$LOADERS_SRC/"*.so "$DIST/gdk-loaders/"

# SVG loader needs librsvg — include it and its non-GTK deps
for lib in librsvg-2.so.2 libcairo-gobject.so.2; do
    src=$(find /usr /lib -name "$lib" 2>/dev/null | head -1)
    [[ -n "$src" && ! -f "$DIST/libs/$lib" ]] && cp "$src" "$DIST/libs/$lib"
done

# Re-run ldd on the loaders to catch any deps we might have missed
for loader in "$DIST/gdk-loaders/"*.so; do
    while IFS= read -r libpath; do
        libname=$(basename "$libpath")
        is_system_lib "$libname" && continue
        [[ "$libname" == "libgdk_pixbuf-2.0.so.0" ]] && continue
        [[ -f "$DIST/libs/$libname" ]] && continue
        [[ -f "$DIST/gdk-loaders/$libname" ]] && continue
        cp "$libpath" "$DIST/libs/$libname"
    done < <(ldd "$loader" 2>/dev/null | awk '/=>/ { print $3 }' | grep "^/")
done

# Generate loaders.cache with absolute paths for the Thor install location
QUERY_TOOL="/usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
GDK_PIXBUF_MODULEDIR="$DIST/gdk-loaders" \
    "$QUERY_TOOL" "$DIST/gdk-loaders/"*.so > "$DIST/gdk-loaders/loaders.cache"
sed -i "s|$DIST/gdk-loaders/|/storage/slippi-dolphin/gdk-loaders/|g" \
    "$DIST/gdk-loaders/loaders.cache"

echo "    gdk-loaders: $(ls "$DIST/gdk-loaders/"*.so | wc -l) loaders"

# ---- 5. copy binary + data --------------------------------------------------

echo "==> Copying binary and data files..."
cp "$BINARIES/dolphin-emu" "$DIST/dolphin-emu"

for dir in Sys Shaders Slippi Config GC GameSettings Resources Themes; do
    [[ -d "$BINARIES/$dir" ]] && cp -r "$BINARIES/$dir" "$DIST/$dir"
done

for f in bootloader.gct codehandler.bin totaldb.dsy; do
    [[ -f "$BINARIES/$f" ]] && cp "$BINARIES/$f" "$DIST/$f"
done

# portable.txt: store user data in ./User/ next to the binary
cp "$BINARIES/portable.txt" "$DIST/portable.txt"

# ---- 5b. write configs — based on ROCKNIX native Dolphin's working config ----
# GFX.ini is copied verbatim from /storage/.config/dolphin-emu/GFX.ini on the
# device (the ROCKNIX Dolphin has no texture issues with Melee).
# Dolphin.ini keeps ROCKNIX's Core/DSP settings but overrides:
#   GFXBackend = Vulkan    — force Vulkan (ROCKNIX config leaves it blank/auto)
#   Fullscreen = True      — always fullscreen on the handheld
#   SIDevice0/1 = 12       — GC USB adapter (ROCKNIX uses 6=standard pad)
#   SlotA = 255            — managed by Slippi launcher
#   MemcardAPath/B         — managed by Slippi launcher

mkdir -p "$DIST/User/Config"

cat > "$DIST/User/Config/Dolphin.ini" <<'DLINI'
[Display]
FullscreenResolution = Auto
Fullscreen = True
RenderToMain = False
[Core]
GFXBackend = Vulkan
HLE_BS2 = True
TimingVariance = 40
CPUCore = 4
Fastmem = True
CPUThread = True
DSPHLE = True
SkipIdle = True
SyncOnSkipIdle = False
SyncGPU = False
FPRF = False
AccurateNaNs = False
SelectedLanguage = 0
OverrideGCLang = False
DPL2Decoder = False
Latency = 2
SlotA = 255
SerialPort1 = 255
SIDevice0 = 12
AdapterRumble0 = False
SimulateKonga0 = False
SIDevice1 = 12
AdapterRumble1 = False
SimulateKonga1 = False
SIDevice2 = 0
SIDevice3 = 0
EmulationSpeed = 1.00000000
FrameSkip = 0x00000000
Overclock = 1.0
OverclockEnable = False
AutoDiscChange = True
[DSP]
EnableJIT = True
DumpAudio = False
Backend = Cubeb
Volume = 100
DSPThread = True
DLINI

cat > "$DIST/User/Config/GFX.ini" <<'GFXINI'
[Hardware]
VSync = False
Adapter = 0
[Settings]
AspectRatio = 5
InternalResolution = 2
Crop = False
wideScreenHack = False
UseXFB = False
UseRealXFB = False
SafeTextureCacheColorSamples = 128
ShowFPS = True
ShowNetPlayPing = True
LogRenderTimeToFile = False
OverlayStats = False
OverlayProjStats = False
DumpTextures = False
HiresTextures = False
ConvertHiresTextures = False
CacheHiresTextures = False
DumpEFBTarget = False
FreeLook = False
UseFFV1 = False
EnablePixelLighting = False
FastDepthCalc = True
MSAA = 0
SSAA = False
EFBScale = 2
TexFmtOverlayEnable = False
TexFmtOverlayCenter = False
Wireframe = False
DisableFog = False
BorderlessFullscreen = False
SWZComploc = True
SWZFreeze = True
ShaderCompilationMode = 0
WaitForShadersBeforeStarting = True
BackendMultithreading = True
[Enhancements]
ForceTextureFiltering = False
MaxAnisotropy = 0
PostProcessingShader =
[Stereoscopy]
StereoMode = 0
StereoDepth = 20
StereoConvergencePercentage = 100
StereoSwapEyes = False
[Hacks]
EFBAccessEnable = False
BBoxEnable = False
ForceProgressive = True
EFBToTextureEnable = True
EFBScaledCopy = False
EFBEmulateFormatChanges = False
SkipDuplicateXFBs = True
XFBToTextureEnable = True
FullAsyncShaderCompilation = False
WaitForShaderCompilation = True
EnableGPUTextureDecoding = True
GFXINI

echo "==> Wrote configs mirroring ROCKNIX native Dolphin (GPU texture decode, Pulse audio)"

# ---- 6. write kill-monitor + launcher wrapper --------------------------------

echo "==> Writing kill-monitor..."
cat > "$DIST/kill-monitor" <<'KILLMON'
#!/usr/bin/env python3
"""Inject ESC (graceful Stop) into Dolphin when Start+Select held 3 seconds."""
import struct, time, os, select, glob, fcntl

EVENT_FMT  = 'QQHHi'
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY     = 0x01
BTN_SELECT = 314
BTN_START  = 315
HOLD_SECS  = 3.0

def find_device():
    try:
        content = open('/proc/bus/input/devices').read()
        for devpath in sorted(glob.glob('/dev/input/event*')):
            name = os.path.basename(devpath)
            idx  = content.find(name)
            if idx == -1:
                continue
            block = content[content.rfind('\n\n', 0, idx):content.find('\n\n', idx)]
            if 'Xbox' in block or 'Odin' in block:
                return devpath
    except Exception:
        pass
    return '/dev/input/event8'

def send_esc():
    UI_SET_EVBIT   = 0x40045564
    UI_SET_KEYBIT  = 0x40045565
    UI_DEV_CREATE  = 0x5501
    UI_DEV_DESTROY = 0x5502
    EV_SYN = 0x00
    KEY_ESC = 1
    FMT = 'QQHHi'
    try:
        fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_ESC)
        os.write(fd, struct.pack('80sHHHHi256i', b'slippi-exit', 0, 0, 0, 0, 0, *([0]*256)))
        fcntl.ioctl(fd, UI_DEV_CREATE)
        time.sleep(0.05)
        t = int(time.time())
        os.write(fd, struct.pack(FMT, t, 0, EV_KEY, KEY_ESC, 1))
        os.write(fd, struct.pack(FMT, t, 0, EV_SYN, 0, 0))
        os.write(fd, struct.pack(FMT, t, 0, EV_KEY, KEY_ESC, 0))
        os.write(fd, struct.pack(FMT, t, 0, EV_SYN, 0, 0))
        time.sleep(0.05)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
    except Exception:
        os.system('killall dolphin-emu')

held       = set()
hold_start = None

try:
    with open(find_device(), 'rb') as f:
        while True:
            r, _, _ = select.select([f], [], [], 0.1)
            if r:
                data = f.read(EVENT_SIZE)
                if not data or len(data) < EVENT_SIZE:
                    break
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
                if etype == EV_KEY:
                    if value == 1:
                        held.add(code)
                    elif value == 0:
                        held.discard(code)
                    if BTN_SELECT in held and BTN_START in held:
                        if hold_start is None:
                            hold_start = time.time()
                    else:
                        hold_start = None
            if hold_start and BTN_SELECT in held and BTN_START in held:
                if time.time() - hold_start >= HOLD_SECS:
                    send_esc()
                    break
except Exception:
    pass
KILLMON
chmod +x "$DIST/kill-monitor"

echo "==> Writing launcher wrapper..."
cat > "$DIST/slippi-dolphin" <<'WRAPPER'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export LD_LIBRARY_PATH="$SCRIPT_DIR/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GDK_PIXBUF_MODULE_FILE="$SCRIPT_DIR/gdk-loaders/loaders.cache"
export GDK_PIXBUF_MODULEDIR="$SCRIPT_DIR/gdk-loaders"
export ALSA_PLUGIN_DIR="/usr/lib/alsa-lib"
# ROCKNIX puts the PulseAudio socket at /run/pulse/native instead of the
# default /run/user/0/pulse/native — libpulse won't find it without this.
export PULSE_SERVER="unix:/run/pulse/native"
# ROCKNIX nightly (20260508+) switched to Sway (Wayland). Terminals opened inside
# the Sway session inherit WAYLAND_DISPLAY, which causes GTK to pick Wayland and
# crash because Dolphin calls X11-specific GTK/Qt APIs. Force X11 through XWayland.
export DISPLAY=":0.0"
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
unset WAYLAND_DISPLAY
# Suppress AT-SPI accessibility bridge — connecting to it on startup adds latency
# and spams DBus errors when running outside a full desktop session.
export NO_AT_BRIDGE=1
export DBUS_SESSION_BUS_ADDRESS=invalid:

# Pin all CPU cores to performance for the duration of the game.
# ROCKNIX nightly defaults to ondemand which leaves cores at ~1 GHz, causing
# audio underruns and sluggish emulation. Restore on exit.
PREV_GOVS=""
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    PREV_GOVS="$PREV_GOVS $cpu=$(cat $cpu 2>/dev/null)"
    echo performance > "$cpu" 2>/dev/null || true
done

# Start+Select held 3s sends ESC to gracefully stop emulation
"$SCRIPT_DIR/kill-monitor" &
MONITOR_PID=$!

mkdir -p "$SCRIPT_DIR/User/Logs"
"$SCRIPT_DIR/dolphin-emu" "$@" 2>>"$SCRIPT_DIR/User/Logs/launcher.log"
STATUS=$?

kill "$MONITOR_PID" 2>/dev/null

# Restore CPU governors
for entry in $PREV_GOVS; do
    echo "${entry##*=}" > "${entry%%=*}" 2>/dev/null || true
done

exit $STATUS
WRAPPER
chmod +x "$DIST/slippi-dolphin"

# ---- 7. bundle slippi-account tool ------------------------------------------

echo "==> Bundling slippi-account..."
# Copy the full script as slippi-account-impl; write a thin wrapper as
# slippi-account that pins the user dir to our portable User/Slippi/ directory.
cp "$REPO_ROOT/scripts/slippi-account" "$DIST/slippi-account-impl"
chmod +x "$DIST/slippi-account-impl"

cat > "$DIST/slippi-account" <<'ACCT'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SLIPPI_USER_DIR="$SCRIPT_DIR/User/Slippi"
exec "$SCRIPT_DIR/slippi-account-impl" "$@"
ACCT
chmod +x "$DIST/slippi-account"

# ---- 8. udev rule for GC adapters ------------------------------------------

cat > "$DIST/51-gcadapter.rules" <<'UDEV'
# GameCube USB Adapter — install to /storage/.config/udev.rules.d/
# Then: udevadm control --reload && udevadm trigger
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0337", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="0e8f", ATTRS{idProduct}=="3013", MODE="0666"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{bInterfaceClass}=="03", ATTRS{bInterfaceSubClass}=="00", MODE="0666"
UDEV

# ---- 9. summary + optional transfer -----------------------------------------

echo ""
echo "Bundle ready: $DIST"
echo ""
du -sh "$DIST"/* | sort -h
echo ""

if [[ -n "$ROCKNIX_IP" ]]; then
    ROCKNIX_PASS="${ROCKNIX_PASS:-rocknix}"
    echo "==> Transferring to $ROCKNIX_DEST ..."
    sshpass -p "$ROCKNIX_PASS" ssh -o StrictHostKeyChecking=no "root@${ROCKNIX_IP}" \
        "rm -rf /storage/slippi-dolphin && mkdir -p /storage/slippi-dolphin"
    cd "$(dirname "$DIST")" && \
        tar -cf - "$(basename "$DIST")" | \
        sshpass -p "$ROCKNIX_PASS" ssh -o StrictHostKeyChecking=no "root@${ROCKNIX_IP}" \
            "tar -xf - -C /storage/"
    echo ""
    echo "==> Installing udev rule..."
    sshpass -p "$ROCKNIX_PASS" ssh -o StrictHostKeyChecking=no "root@${ROCKNIX_IP}" "
        mkdir -p /storage/.config/udev.rules.d &&
        cp /storage/slippi-dolphin/51-gcadapter.rules /storage/.config/udev.rules.d/ &&
        udevadm control --reload 2>/dev/null || true &&
        udevadm trigger 2>/dev/null || true
    "
    echo ""
    echo "==> Restoring user.json..."
    sshpass -p "$ROCKNIX_PASS" ssh -o StrictHostKeyChecking=no "root@${ROCKNIX_IP}" "
        if [[ -f /storage/slippi-userdata/user.json ]]; then
            mkdir -p /storage/slippi-dolphin/User/Slippi &&
            cp /storage/slippi-userdata/user.json /storage/slippi-dolphin/User/Slippi/user.json &&
            echo '    user.json restored from /storage/slippi-userdata/'
        else
            echo '    WARNING: /storage/slippi-userdata/user.json not found — login required on first launch'
        fi
    "
    echo ""
    echo "Done. Test with:"
    echo "  /storage/slippi-dolphin/slippi-dolphin /path/to/GALE01.iso"
else
    echo "To deploy to your Thor (SSH must be enabled in ROCKNIX settings):"
    echo "  bash scripts/deploy-rocknix.sh <thor-ip>"
fi
