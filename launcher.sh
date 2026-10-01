#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

steam_root="${STEAM_ARM64_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/Steam}"

if [ ! -x "$steam_root/steamrtarm64/steam" ]; then
  echo "steam-arm64: installing the pinned client into $steam_root" >&2
  mkdir -p -- "$steam_root"
  cp --archive --no-target-directory -- "@client@" "$steam_root"
  chmod -R u+rwX -- "$steam_root"
  if [ "@channel@" != stable ]; then
    mkdir -p -- "$steam_root/package"
    printf '%s\n' "@channel@" >"$steam_root/package/beta"
  fi
fi

mkdir -p -- "$HOME/.steam" "$steam_root/package"
ln -sfn -- "$steam_root" "$HOME/.steam/root"
ln -sfn -- "$steam_root" "$HOME/.steam/steam"
ln -sfn -- "$steam_root/linuxarm64" "$HOME/.steam/sdkarm64"
# Steam preloads the overlay through .steam/bin64/../steamrtarm64/, so bin64 must resolve.
ln -sfn -- "$steam_root/steamrtarm64" "$HOME/.steam/bin64"

# The desktop publishes the cursor it wants in the X resource database, which is
# where every other X client reads it, so the client follows the desktop rather
# than carrying a size and a theme name of its own. The directories that hold
# the theme come from XCURSOR_PATH in the session: the Xcursor library here is
# built with no system directory of its own, so without it no theme resolves and
# the client draws the X server's built-in bitmap, which is tiny on a scaled
# display.
resources=$("@xrdb@" -query 2>/dev/null || true)
xresource() {
  printf '%s\n' "$resources" | sed -n "s/^$1:[[:space:]]*\(.*\)\$/\1/p" | head -1
}

if [ -z "${XCURSOR_SIZE:-}" ]; then
  size=$(xresource 'Xcursor\.size')
  case "${size:-}" in
  '' | *[!0-9]*) ;;
  *) export XCURSOR_SIZE="$size" ;;
  esac
fi

if [ -z "${XCURSOR_THEME:-}" ]; then
  theme=$(xresource 'Xcursor\.theme')
  if [ -n "${theme:-}" ]; then
    export XCURSOR_THEME="$theme"
  fi
fi

# muvm gives the guest its own environment, so what it must inherit is named here.
# Valve's FEX compatibility tool, which the client puts in front of every x86
# tool and game, takes its x86 Mesa from the graphics provider named here; the
# FEX rootfs mounted below carries one, and without it an x86 game inside the
# container has no driver.
guest_env=(
  -e "STEAM_ARM64_ROOT=$steam_root"
  -e "MESA_SHADER_CACHE_MAX_SIZE=50G"
  -e "STEAM_COMPAT_GRAPHICS_PROVIDER=/run/fex-emu/rootfs/graphics_provider.json"
)
for var in XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH DBUS_SESSION_BUS_ADDRESS STEAM_EXTRA_COMPAT_TOOLS_PATHS LOCALE_ARCHIVE; do
  if [ -n "${!var:-}" ]; then
    guest_env+=(-e "$var=${!var}")
  fi
done

# muvm registers FEX as the guest's x86 binfmt handler by looking up
# FEXInterpreter on the PATH it inherits, a name FEX no longer installs.
export PATH="@fexbin@:$PATH"

# A launch into a guest that is already running has muvm register its own
# stdin with epoll, which refuses a device or a regular file, so a launch from
# a desktop entry or a link, whose stdin is /dev/null, dies after the request
# went out. A pipe at end of file reads the same and is accepted.
if [ ! -t 0 ] && { [ -c /dev/stdin ] || [ -f /dev/stdin ]; }; then
  exec < <(:)
fi

# Valve exits 42 to ask for a restart, which is how the client hands control
# back after it updates itself.
while :; do
  # A guest numbers its processes from one, so the pid file the last client
  # left names a live process in the next guest and the client exits believing
  # it is already running. With no guest holding muvm's lock the file is stale.
  if "@flock@" -n "${XDG_RUNTIME_DIR:?}/muvm.lock" true 2>/dev/null; then
    rm -f -- "$HOME/.steam/steam.pid"
  fi
  set +o errexit
  "@muvm@" \
    -f "@rootfs@" \
    --gpu-mode=drm \
    -p 27031:27031/udp \
    -p 27036:27036/udp \
    -p 27036:27036 \
    -p 27037:27037 \
    --interactive \
    "${guest_env[@]}" \
    -- \
    "@fhs@/bin/steam-arm64-fhs" "$@"
  status=$?
  set -o errexit

  if [ "$status" -ne 42 ]; then
    exit "$status"
  fi
  echo "steam-arm64: Steam asked to restart" >&2
done
