{
  lib,
  buildFHSEnv,
  replaceVars,
  glibcLocales,
  steam-runtime-arm64,
  libappindicator-gtk2,
  runCommand,
}:
let
  locales = glibcLocales.override {
    allLocales = false;
    locales = [
      "en_US.UTF-8/UTF-8"
      "de_DE.UTF-8/UTF-8"
    ];
  };
  guestRun = runCommand "steam-arm64-guest-run" { } ''
    install -Dm755 ${replaceVars ./guest-run.sh { dbusConf = "${./session-bus.conf}"; }} "$out"
  '';
in
buildFHSEnv {
  name = "steam-arm64-fhs";

  multiArch = false;

  targetPkgs =
    pkgs: with pkgs; [
      bash
      coreutils
      file
      lsb-release
      lsof
      pciutils
      python3
      usbutils
      xdg-utils
      socat
      xz
      zenity

      glibc
      libxcrypt
      libGL
      libdrm
      libgbm
      libva
      vulkan-loader
      udev
      libudev0-shim
      libcap
      networkmanager

      libasyncns
      bzip2
      glib
      gtk2
      ibus
      libogg
      libvorbis
      libvpx
      libsndfile
      openal
      libvdpau
      pipewire
      libopus
      flac
      libsamplerate

      SDL2

      libx11
      libice
      libsm
      libxcomposite
      libxdamage
      libxinerama
      libxtst
      libxext
      libxfixes
      libxi
      libxrandr
      libxrender
      libxscrnsaver
      libxcb
      libxkbcommon
      libxcursor
      libxau
      libxdmcp
      libxshmfence
      libxft
      libxt
      libxmu
      libxpm
      libxxf86vm
      xcbutil
      xcbutilimage
      xcbutilkeysyms
      xcbutilrenderutil
      xcbutilwm
      wayland
      libdecor

      libpng
      libjpeg_turbo
      libtiff
      libwebp
      pixman
      harfbuzz
      fribidi
      libthai
      libdatrie
      graphite2
      icu

      curl
      openssl
      gnutls
      nettle
      libidn2
      libpsl
      libssh2

      zlib
      zstd
      lz4
      brotli

      libusb1
      libevdev
      libinput
      libwacom
      libgudev

      alsa-lib
      libpulseaudio
      nss
      nspr
      at-spi2-atk
      cairo
      pango
      gtk3
      gdk-pixbuf
      cups
      dbus
      expat
      fontconfig
      freetype
      libnotify
      libsecret
      sqlite
      dconf
      libxml2
      json-glib
      libepoxy
      glew
      libbsd
      fuse3
      libappindicator-gtk2

      ffmpeg_7
      nghttp2
      speechd
    ];
  profile = ''
    unset GIO_EXTRA_MODULES
    export SDL_JOYSTICK_DISABLE_UDEV=1
    export PATH="${steam-runtime-arm64}/bin:$PATH"
    export FUSERMOUNT_PROG=/usr/bin/fusermount3
    export GTK_IM_MODULE=xim
    export LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri
    export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
    export LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri
    export VDPAU_DRIVER_PATH=/run/opengl-driver/lib/vdpau
    export LOCALE_ARCHIVE=${locales}/lib/locale/locale-archive

    if [ -z ''${TZ+x} ]; then
      if new_TZ=$(readlink -f /etc/localtime | grep -P -o '(?<=/zoneinfo/).*$'); then
        export TZ="$new_TZ"
      fi
    fi
  '';

  runScript = "${guestRun}";

  meta = {
    description = "The filesystem layout Valve's aarch64 client expects, with its loader and libraries";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-linux" ];
  };
}
