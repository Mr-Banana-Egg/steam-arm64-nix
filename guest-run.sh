#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# buildFHSEnv writes its profile to /etc/profile, which only a login shell reads.
if [ -e /usr/lib64/locale/locale-archive ]; then
  export LOCALE_ARCHIVE=/usr/lib64/locale/locale-archive
fi

# The loader enumerates every ICD it finds, so the drivers for hardware this
# machine does not have each fail aloud. Name the ones that can apply instead.
icd=/run/opengl-driver/share/vulkan/icd.d
if [ -d "$icd" ]; then
  drivers=""
  for f in "$icd"/*.json; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
    radeon_* | intel_* | nouveau_* | panfrost_* | broadcom_* | freedreno_* | powervr_* | dzn_*) continue ;;
    esac
    drivers="${drivers:+$drivers:}$f"
  done
  if [ -n "$drivers" ]; then
    export VK_DRIVER_FILES="$drivers"
  fi
fi

mkdir -p /run/systemd/userdb
i=0
for s in /run/muvm-host/run/systemd/userdb/*; do
  [ -S "$s" ] || continue
  setsid socat "UNIX-LISTEN:/run/systemd/userdb/$(basename "$s"),fork,mode=0666" \
    "VSOCK-CONNECT:2:$((50199 - i))" </dev/null >/dev/null 2>&1 &
  i=$((i + 1))
done

steam_root="${STEAM_ARM64_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/Steam}"

# muvm keeps one guest per user and a launch into a running guest keeps that
# guest's mounts, so a guest another command started has no FEX rootfs and the
# graphics provider named for Valve's FEX tool points at nothing.
if [ -n "${STEAM_COMPAT_GRAPHICS_PROVIDER:-}" ] && [ ! -f "$STEAM_COMPAT_GRAPHICS_PROVIDER" ]; then
  echo "steam-arm64: $STEAM_COMPAT_GRAPHICS_PROVIDER is not in this guest; x86 games will not start until the running muvm guest exits and Steam starts one of its own" >&2
fi

# The guest has no session bus of its own and the client's launcher service
# exits without one. A bus that will not start must never stop the client, so
# this is best effort and the client runs either way.
# The desktop's own bus is what the tray needs: an indicator that finds no
# StatusNotifierWatcher falls back to an XEmbed icon, and an XEmbed icon has no
# menu. The host's socket is on the shared filesystem, so try it and prove it
# answers before trusting it; a bus of our own is the fallback.
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    / org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    echo "steam-arm64: the desktop bus is not reachable from the guest" >&2
    unset DBUS_SESSION_BUS_ADDRESS
  fi
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if address=$(dbus-daemon --config-file=@dbusConf@ --fork --print-address 2>/dev/null); then
    export DBUS_SESSION_BUS_ADDRESS="$address"
  else
    echo "steam-arm64: no session bus; the launcher service will stay off" >&2
  fi
fi

# steam-arm64 --doctor runs here, inside the guest and the sandbox the client
# gets, and reports each thing an x86 game needs, so the stack can be checked
# without launching a game.
if [ "${1:-}" = "--doctor" ]; then
  status=0
  check() {
    name=$1
    shift
    if "$@" >/dev/null 2>&1; then
      printf 'ok    %s\n' "$name"
    else
      printf 'FAIL  %s\n' "$name"
      status=1
    fi
  }
  tools="$steam_root/steamapps/common"
  check "guest runs on 4K pages" test "$(getconf PAGESIZE)" = 4096
  check "x86-64 binfmt handler registered in the guest" test -f /proc/sys/fs/binfmt_misc/FEX-x86_64
  check "FEX rootfs mounted" test -d /run/fex-emu/rootfs/usr/lib64
  check "graphics provider named and present" test -f "${STEAM_COMPAT_GRAPHICS_PROVIDER:-/nonexistent}"
  check "an x86-64 binary runs through the rootfs" env FEX_ROOTFS=/run/fex-emu/rootfs /run/fex-emu/rootfs/usr/bin/true
  check "python3 for Valve's FEX tool" command -v python3
  check "cursor theme path handed in" test -n "${XCURSOR_PATH:-}"
  check "session bus answers" dbus-send --session --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames
  check "launcher service on PATH" command -v steam-runtime-launcher-service
  check "Valve's FEX tool installed (Steam app 3127680)" test -x "$tools/FEX-Emu/fex-compat-tool"
  check "Valve's FEX tool starts" env STEAM_COMPAT_DATA_PATH=/tmp "$tools/FEX-Emu/fex-compat-tool" --help
  check "Steam Linux Runtime 4.0 arm64 installed (app 4185400)" test -x "$tools/SteamLinuxRuntime_4-arm64/pressure-vessel/bin/pressure-vessel-wrap"
  check "Proton (ARM64) installed" sh -c 'ls -d "$1"/Proton*ARM64*/proton >/dev/null 2>&1' sh "$tools"
  check "GPU render node in the guest" test -e /dev/dri/renderD128
  check "audio server socket shared into the guest" test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0"
  check "aarch64 overlay library installed" test -f "$steam_root/steamrtarm64/gameoverlayrenderer.so"
  check "x86-64 overlay library for FEX games installed" test -f "$steam_root/ubuntu12_64/gameoverlayrenderer.so"
  gamepads=$(find /dev/input -maxdepth 1 -name 'event*' 2>/dev/null | wc -l)
  printf 'info  gamepads forwarded by muvm into the guest: %s (attach one on the host and it appears here)\n' "$gamepads"
  if grep -q binder /proc/filesystems 2>/dev/null; then
    printf 'info  guest kernel offers binder, the Android layer could be tried\n'
  else
    printf 'info  guest kernel has no binder, so the Android layer (Lepton) cannot run here\n'
  fi
  if [ -s "$steam_root/package/beta" ]; then
    printf 'info  client channel: %s, from package/beta, which the client owns after the first install\n' "$(head -1 "$steam_root/package/beta")"
  else
    printf 'info  client channel: stable, no package/beta\n'
  fi
  if [ -n "${STEAM_EXTRA_COMPAT_TOOLS_PATHS:-}" ]; then
    for dir in ${STEAM_EXTRA_COMPAT_TOOLS_PATHS//:/ }; do
      check "extra tool ${dir##*/} complete" test -f "$dir/toolmanifest.vdf" -a -f "$dir/compatibilitytool.vdf" -a -x "$dir/proton"
    done
  else
    printf 'none  extra compatibility tools handed in\n'
  fi
  exit "$status"
fi

exec "$steam_root/steamrtarm64/steam" "$@"
