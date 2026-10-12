#!/usr/bin/env bash
# Build a self-contained AppDir around a release build of Strata: the binary
# laid out like the release archive, GTK's runtime data (pixbuf loaders,
# compiled GSettings schemas, Adwaita icons, GtkSourceView and Poppler data,
# GStreamer plugins, a fallback font) and every shared library it needs,
# glibc and its dynamic loader included, so the result runs on distributions
# older and newer than the one that built it. Only the GPU stack (Mesa,
# NVIDIA, Vulkan ICDs, VA-API) is left to the host; so are bubblewrap and
# prlimit, which the preview sandbox executes from the host's trusted
# directories.
#
# Usage: build-appdir.sh <strata binary> <AppDir>    (run from the repository root)
set -euo pipefail

BIN="$(realpath "$1")"
APPDIR="$(realpath -m "$2")"
HERE="$(dirname "$(realpath "$0")")"
ROOT="$(cd "$HERE/../.." && pwd)"
ID=io.github.lgse.Strata
LIBDIR="$APPDIR/usr/lib"
MULTIARCH="$(gcc -print-multiarch)"
SYSLIB="/usr/lib/$MULTIARCH"

[ -x "$BIN" ] || { echo "::error::$BIN is not an executable" >&2; exit 1; }

# Libraries that must come from the host because they are tied to its kernel
# driver or hardware: the OpenGL/EGL/Vulkan stack GTK renders with and VA-API
# decodes with. Everything else is bundled.
EXCLUDE='^(linux-vdso|libcuda|libnvidia|libGL\.so|libGLX|libEGL|libGLdispatch|libOpenGL|libgbm|libgallium|libvulkan_|libdrm|libva\.so|libva-)'

rm -rf "${APPDIR:?}"
mkdir -p "$LIBDIR" "$APPDIR/usr/bin" "$APPDIR/usr/libexec" "$APPDIR/usr/share"

# --- the application, as the release archive lays it out --------------------
install -Dm755 "$BIN" "$APPDIR/usr/bin/strata"
install -Dm644 "$ROOT/data/$ID.desktop" "$APPDIR/usr/share/applications/$ID.desktop"
install -Dm644 "$ROOT/data/icons/scalable/apps/$ID.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/$ID.svg"
install -Dm644 "$ROOT/LICENSE" "$APPDIR/usr/share/licenses/strata/LICENSE"
install -Dm644 "$ROOT/THIRD_PARTY_LICENSES.md" "$APPDIR/usr/share/licenses/strata/THIRD_PARTY_LICENSES.md"
install -Dm644 "$ROOT/data/licenses/UnRAR.txt" "$APPDIR/usr/share/licenses/strata/UnRAR.txt"
install -Dm644 "$HERE/README.md" "$APPDIR/usr/share/doc/strata/appimage.md"

# --- GTK runtime data that lives outside the libraries -----------------------
# gdk-pixbuf loaders. The cache has to name the modules by absolute path, and
# the mount point of an AppImage is only known when it runs, so this is a
# template that AppRun fills in at start.
PIXBUF_LOADERS="$SYSLIB/gdk-pixbuf-2.0/2.10.0/loaders"
mkdir -p "$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders"
cp -aL "$PIXBUF_LOADERS"/*.so "$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/"
[ -e "$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so" ] ||
    { echo "::error::libpixbufloader-svg.so not found (librsvg2-common)" >&2; exit 1; }
"$SYSLIB/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders" "$LIBDIR"/gdk-pixbuf-2.0/2.10.0/loaders/*.so |
    sed -E 's|^"/.*/(libpixbufloader-[^/"]+\.so)"|"@LOADERS@/\1"|' >"$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders.cache.in"

# GSettings schemas: GTK aborts when it asks for a schema that is not installed
# (the file chooser, for one). Found through XDG_DATA_DIRS.
SCHEMAS="$APPDIR/usr/share/glib-2.0/schemas"
mkdir -p "$SCHEMAS"
for schema in org.gtk.gtk4.Settings.FileChooser.gschema.xml org.gnome.desktop.enums.xml \
    org.gnome.desktop.interface.gschema.xml; do
    [ -e "/usr/share/glib-2.0/schemas/$schema" ] || { echo "::error::$schema not found (gtk4, gsettings-desktop-schemas)" >&2; exit 1; }
done
cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.xml /usr/share/glib-2.0/schemas/org.gnome.desktop.enums.xml \
    /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml "$SCHEMAS/"
glib-compile-schemas "$SCHEMAS"
rm "${SCHEMAS:?}"/*.xml

# Icons: Strata's own are compiled in; GTK's standard names come from Adwaita.
mkdir -p "$APPDIR/usr/share/icons/Adwaita"
cp -a /usr/share/icons/Adwaita/index.theme /usr/share/icons/Adwaita/symbolic /usr/share/icons/Adwaita/scalable "$APPDIR/usr/share/icons/Adwaita/"
for d in symbolic-up-to-32 16x16; do
    [ -d "/usr/share/icons/Adwaita/$d" ] && cp -a "/usr/share/icons/Adwaita/$d" "$APPDIR/usr/share/icons/Adwaita/"
done
cp /usr/share/icons/hicolor/index.theme "$APPDIR/usr/share/icons/hicolor/"
gtk4-update-icon-cache -qtf "$APPDIR/usr/share/icons/Adwaita" 2>/dev/null || true

# GtkSourceView language definitions and styles, Poppler's encoding data.
cp -a /usr/share/gtksourceview-5 "$APPDIR/usr/share/"
[ -d /usr/share/poppler ] && cp -a /usr/share/poppler "$APPDIR/usr/share/"

# GStreamer: the plugins Strata's media previews decode with, and the helper
# that scans them (an executable, so it gets the bundled loader too).
mkdir -p "$LIBDIR/gstreamer-1.0" "$APPDIR/usr/libexec/gstreamer-1.0"
cp -aL "$SYSLIB"/gstreamer-1.0/*.so "$LIBDIR/gstreamer-1.0/"
cp -aL "$SYSLIB/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner" "$APPDIR/usr/libexec/gstreamer-1.0/"
ls "$LIBDIR/gstreamer-1.0" | wc -l | sed 's/^/gstreamer plugins: /'

# GTK's own media backend (video previews play through gtk::MediaFile), found
# through GTK_EXE_PREFIX (see AppRun).
mkdir -p "$LIBDIR/gtk-4.0/4.0.0/media"
cp -aL "$SYSLIB"/gtk-4.0/4.0.0/media/libmedia-gstreamer.so "$LIBDIR/gtk-4.0/4.0.0/media/"

# GIO modules: only GVfs's client, which is linked against the bundled GLib and
# talks to the host's gvfsd over D-Bus, so remote locations keep working. The
# host's own modules (dconf, ...) are built against the host's GLib and stay out.
mkdir -p "$LIBDIR/gio/modules"
if [ -e "$SYSLIB/gio/modules/libgvfsdbus.so" ]; then
    cp -aL "$SYSLIB/gio/modules/libgvfsdbus.so" "$LIBDIR/gio/modules/"
else
    echo "::warning::libgvfsdbus.so not found (gvfs); remote locations will be unavailable"
fi

# Fonts: the host's fonts through the bundled fontconfig, with DejaVu as the
# fallback for a host that has none (see AppRun for when this file is used).
mkdir -p "$APPDIR/usr/share/fonts/dejavu" "$APPDIR/etc/fonts"
cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf "$APPDIR/usr/share/fonts/dejavu/"
cat >"$APPDIR/etc/fonts/fonts.conf" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Used only when the host has no /etc/fonts/fonts.conf (see AppRun). -->
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <dir>~/.fonts</dir>
  <dir prefix="relative">../../usr/share/fonts</dir>
  <cachedir prefix="xdg">fontconfig</cachedir>
  <cachedir>~/.fontconfig</cachedir>
  <config><rescan><int>30</int></rescan></config>
</fontconfig>
XML

# --- dlopen()ed glibc pieces that ldd cannot see -------------------------------
mkdir -p "$LIBDIR/gconv"
cp -a "$SYSLIB"/gconv/. "$LIBDIR/gconv/"
for so in libnss_files.so.2 libnss_dns.so.2 libresolv.so.2; do
    [ -e "$SYSLIB/$so" ] && cp -aL "$SYSLIB/$so" "$LIBDIR/"
done

# --- the exec hook that keeps AppRun's environment out of host programs -------
gcc -shared -fPIC -O2 -Wall -Wextra -o "$LIBDIR/exec.so" "$HERE/exec.c" -ldl

# --- the shared-library closure of every ELF in the AppDir --------------------
export LD_LIBRARY_PATH="$LIBDIR"
is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }
bundle_deps() {
    local f="$1" out lib name
    out="$(ldd "$f" 2>/dev/null || true)"
    echo "$out" | awk '/=> \//{print $3}' | while read -r lib; do
        name="$(basename "$lib")"
        if [[ "$name" =~ $EXCLUDE ]]; then continue; fi
        [ -e "$LIBDIR/$name" ] || { cp -aL "$lib" "$LIBDIR/$name"; echo "$LIBDIR/$name"; }
    done
    if echo "$out" | grep -q 'not found'; then
        echo "::error::unresolved dependency for $f" >&2
        echo "$out" | grep 'not found' >&2
        return 1
    fi
}
queue="$(find "$APPDIR/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) | while read -r f; do is_elf "$f" && echo "$f"; done)"
while [ -n "$queue" ]; do
    next=""
    while read -r f; do
        [ -n "$f" ] || continue
        new="$(bundle_deps "$f")"
        next="$next"$'\n'"$new"
    done <<<"$queue"
    queue="$(echo "$next" | sed '/^$/d')"
done

# --- glibc's dynamic loader (see AppRun) -------------------------------------
# Taken from the binary itself, so this works for x86_64 and aarch64 alike.
HOST_LOADER="$(patchelf --print-interpreter "$BIN")"
LOADER_NAME="$(basename "$HOST_LOADER")"
mkdir -p "$APPDIR/lib"
cp -aL "$HOST_LOADER" "$APPDIR/lib/$LOADER_NAME"
rm -f "${LIBDIR:?}/${LOADER_NAME:?}"
LOADER_HASH="$(sha256sum "$APPDIR/lib/$LOADER_NAME" | cut -c1-12)"
LOADER="/tmp/.strata-appimage-$LOADER_HASH/$LOADER_NAME"
find "$APPDIR/usr" -type f -perm -u+x ! -name '*.so' ! -name '*.so.*' | while read -r f; do
    is_elf "$f" || continue
    patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
    patchelf --set-interpreter "$LOADER" "$f"
    echo "interpreter patched: ${f#"$APPDIR"/}"
done

# --- relative RPATHs instead of an exported LD_LIBRARY_PATH -------------------
unset LD_LIBRARY_PATH # patchelf is a host program
"$HERE/set-runpaths.sh" "$APPDIR"

# --- AppImage entry point and metadata ----------------------------------------
sed -e "s|@LOADER@|$LOADER|" -e "s|@LOADER_NAME@|$LOADER_NAME|" "$HERE/AppRun" >"$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "$APPDIR/usr/share/applications/$ID.desktop" "$APPDIR/"
cp "$APPDIR/usr/share/icons/hicolor/scalable/apps/$ID.svg" "$APPDIR/"
ln -sf "$ID.svg" "$APPDIR/.DirIcon"

echo "::group::Libraries still resolved from the host (the GPU stack is expected here)"
"$APPDIR/lib/$LOADER_NAME" --library-path "$LIBDIR" --list "$APPDIR/usr/bin/strata" |
    grep -v "$APPDIR" | grep '=> /' || true
echo "::endgroup::"
du -sh "$APPDIR"
