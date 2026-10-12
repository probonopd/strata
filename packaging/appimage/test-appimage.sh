#!/usr/bin/env bash
# Portability test for the Strata AppImage. Run inside a stock distribution
# container that has neither GTK nor anything else Strata needs:
#   test-appimage.sh <path-to.AppImage> <output-dir>
# Only generic test infrastructure (X server, window manager, screenshot tools,
# a font), a stand-in for the host GPU driver (Mesa) and the two host programs
# the preview sandbox needs anyway (bubblewrap, util-linux's prlimit) are
# installed here; every library Strata needs must come out of the AppImage.
# HOSTILE_GTK=1 installs the host's own GTK 4 stack as well, to prove the
# bundle never loads it. The sandbox check needs user namespaces: run the
# container with --privileged.
set -euo pipefail

APPIMAGE="$(realpath "$1")"
OUT="$(realpath -m "${2:-.}")"
mkdir -p "$OUT"
cd "$(mktemp -d)"

. /etc/os-release
echo "::group::Container: $PRETTY_NAME, $(ldd --version 2>&1 | head -1)"
echo "::endgroup::"

echo "::group::Install test infrastructure"
case "${ID_LIKE:-} ${ID}" in
*debian* | *ubuntu*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        ca-certificates xvfb icewm x11-utils imagemagick fonts-dejavu-core gdb procps dbus \
        bubblewrap util-linux libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgl1 libegl1 >/dev/null
    if [ -n "${HOSTILE_GTK:-}" ]; then
        apt-get install -y -qq --no-install-recommends \
            libgtk-4-1 libgtksourceview-5-0 libpoppler-glib8 librsvg2-common \
            libgstreamer1.0-0 gstreamer1.0-plugins-base >/dev/null
    fi
    ;;
*fedora* | *rhel*)
    dnf install -y -q --setopt=install_weak_deps=False \
        xorg-x11-server-Xvfb icewm xwininfo ImageMagick dbus-daemon dejavu-sans-fonts gdb procps-ng \
        bubblewrap util-linux mesa-dri-drivers mesa-libGL mesa-libEGL >/dev/null
    ;;
*)
    echo "::error::unsupported test distribution: $PRETTY_NAME"
    exit 1
    ;;
esac
echo "::endgroup::"

# Make sure the container really does lack what the AppImage must bring along
# (unless it is meant to have it, to prove the bundle ignores it).
absent="libgtk-4.so.1 libgtksourceview-5.so.0 libpoppler-glib.so.8 libgstreamer-1.0.so.0"
[ -n "${HOSTILE_GTK:-}" ] && absent=""
for lib in $absent; do
    if ldconfig -p | grep -q "$lib"; then
        echo "::error::test container unexpectedly provides $lib"
        exit 1
    fi
done

chmod +x "$APPIMAGE"

echo "::group::The command line works through the AppImage runtime (no FUSE in containers)"
VERSION_OUT="$(APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" --version 2>&1)" || {
    echo "$VERSION_OUT"
    echo "::error::strata --version failed"
    exit 1
}
echo "$VERSION_OUT"
grep -qE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$VERSION_OUT" || { echo "::error::unexpected --version output"; exit 1; }
echo "::endgroup::"

"$APPIMAGE" --appimage-extract >/dev/null
APPDIR="$PWD/squashfs-root"
# Set up the bundled loader the way a real start does, without starting the app.
"$APPDIR/AppRun" --version >/dev/null
LOADER_DIR="$(dirname "$(sed -n 's/^LOADER="\(.*\)"$/\1/p' "$APPDIR/AppRun")")"
[ -d "$LOADER_DIR" ] || { echo "::error::AppRun did not create $LOADER_DIR"; exit 1; }

echo "::group::The preview sandbox can run the bundled helper"
# The same bubblewrap invocation src/sandbox.rs builds (runtime_command plus the
# extra roots AppRun names in STRATA_SANDBOX_EXTRA_ROOTS), run directly: inside
# it the helper must find its loader and libraries although /tmp is a fresh
# tmpfs and only the host's /usr is bound. Keep in step with runtime_command.
convert -size 64x64 xc:red input.png
convert -size 64x64 xc:blue input.pdf
mkdir -p output
sandbox() {
    bwrap --unshare-all --die-with-parent --new-session --clearenv \
        --setenv PATH /usr/bin --setenv HOME /nonexistent --setenv XDG_CACHE_HOME /tmp/cache \
        --proc /proc --dev /dev --size 536870912 --tmpfs /tmp --dir /app --dir /etc \
        --ro-bind /usr /usr --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 \
        --ro-bind-try /etc/fonts /etc/fonts --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache \
        --ro-bind "$APPDIR" "$APPDIR" --ro-bind "$LOADER_DIR" "$LOADER_DIR" \
        --setenv GDK_PIXBUF_MODULE_FILE "$LOADER_DIR/loaders.cache" \
        --setenv GCONV_PATH "$APPDIR/usr/lib/gconv" \
        --ro-bind "$PWD/$1" "/$1" --bind "$PWD/output" /output \
        -- "$APPDIR/usr/bin/strata" --preview-helper "$2" "/$1" "/output/$3" 64
}
SANDBOX_OK=1
for job in "input.png thumbnail-image thumb.png" "input.pdf thumbnail-pdf page.png"; do
    set -- $job
    rm -f "output/$3"
    if sandbox "$1" "$2" "$3" && [ -s "output/$3" ]; then
        echo "$2: ok ($(identify -format '%wx%h' "output/$3"))"
    else
        echo "::error::$2 failed inside the sandbox"
        SANDBOX_OK=0
    fi
done
echo "::endgroup::"

Xvfb "${XVFB_DISPLAY:-:99}" -screen 0 1280x800x24 &
XVFB_PID=$!
sleep 2
export DISPLAY="${XVFB_DISPLAY:-:99}"
icewm >/dev/null 2>&1 &
WM_PID=$!
sleep 2

export HOME="$PWD/home"
mkdir -p "$HOME/Documents"
cp input.png input.pdf "$HOME/Documents/"
# Behave like a real desktop session: a session bus, and an LD_LIBRARY_PATH full of host
# libraries (GNUstep/Nix/vendor-driver sessions export one). The AppImage must not let
# it change which libraries it uses.
HOSTILE_LD=/usr/lib:/usr/lib64:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU in CI; Mesa llvmpipe from the host stands in for the driver
export GDK_BACKEND=x11 GTK_A11Y=none NO_AT_BRIDGE=1

LD_LIBRARY_PATH="$HOSTILE_LD" dbus-run-session -- "$APPDIR/AppRun" "$HOME/Documents" >"$OUT/strata-stdout.log" 2>&1 &
APP_PID=$!

WINDOW_FOUND=0
RENDERED=0
for _ in $(seq 1 15); do
    sleep 2
    kill -0 "$APP_PID" 2>/dev/null || break
    # (capture first: `grep -q` closing the pipe early fails the pipeline under pipefail)
    WINDOWS="$(xwininfo -tree -root 2>/dev/null || true)"
    if grep -qiE 'io.github.lgse.Strata|"strata"' <<<"$WINDOWS"; then
        WINDOW_FOUND=1
        import -window root "$OUT/screenshot.png"
        STDDEV="$(identify -format '%[fx:standard_deviation]' "$OUT/screenshot.png")"
        echo "Strata window found, frame stddev: $STDDEV"
        if awk -v v="$STDDEV" 'BEGIN{exit !(v > 0.02)}'; then
            RENDERED=1
            break
        fi
    fi
done

echo "::group::Diagnostics"
xwininfo -tree -root 2>&1 | head -40 || true
PID="$(pgrep -x strata | head -1 || true)" # APP_PID is only the dbus-run-session wrapper
MISSING=0
if [ -n "$PID" ]; then
    echo "Libraries mapped from outside the AppImage (only the GPU stack is allowed):"
    grep -o '/[^ ]*\.so[^ ]*' "/proc/$PID/maps" | sort -u | grep -v "$APPDIR" | grep -v "$LOADER_DIR" || true
    for lib in libc.so.6 libgtk-4.so.1 libgtksourceview-5.so.0 libpoppler-glib.so.8 libglib-2.0.so.0 \
        libcairo.so.2 libpango-1.0.so.0 libgdk_pixbuf-2.0.so.0 libpixbufloader-svg.so librsvg-2.so.2 libX11.so.6; do
        if ! grep -o '/[^ ]*' "/proc/$PID/maps" | grep "/$lib" | grep -q "$APPDIR"; then
            echo "::error::$lib was not loaded from inside the AppImage"
            MISSING=1
        fi
    done
    # The host may only contribute libraries the bundle does not have (its GPU
    # stack and what that pulls in); a host copy of a bundled one is the failure.
    SHADOWED=0
    for lib in $(grep -o '/[^ ]*\.so[^ ]*' "/proc/$PID/maps" | sort -u | grep -v "$APPDIR" | grep -v "$LOADER_DIR"); do
        base="$(basename "$lib")"
        if ls "$APPDIR/usr/lib/${base%%.so*}".so* >/dev/null 2>&1; then
            echo "::error::$lib was loaded from the host although the AppImage bundles it"
            SHADOWED=1
        fi
    done
    [ "$SHADOWED" -eq 0 ] || MISSING=1
else
    echo "Strata has already exited"
    MISSING=1
fi
echo "::endgroup::"

echo "::group::Strata stdout/stderr"
cat "$OUT/strata-stdout.log"
echo "::endgroup::"

if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
fi
kill "$WM_PID" "$XVFB_PID" 2>/dev/null || true

[ "$WINDOW_FOUND" -eq 1 ] || { echo "::error::no Strata window ever appeared"; exit 1; }
[ "$RENDERED" -eq 1 ] || { echo "::error::Strata window exists but the screen stayed blank"; exit 1; }
[ "$MISSING" -eq 0 ] || exit 1
[ "$SANDBOX_OK" -eq 1 ] || exit 1
if grep -qiE 'Settings schema .* is not installed|Failed to load module|symbol lookup error|GLIBC_' "$OUT/strata-stdout.log"; then
    echo "::error::Strata reported a loading problem (see its output above)"
    exit 1
fi
echo "Strata AppImage passed on $PRETTY_NAME"
