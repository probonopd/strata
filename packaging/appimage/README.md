# AppImage

The release workflow packages each target's release binary into an
[AppImage](https://appimage.org) (`.github/actions/appimage`) and publishes it
next to the archives. `.github/workflows/appimage.yml` builds one from the
current tree and starts it in stock Debian, Ubuntu and Fedora containers
whenever this packaging changes, to prove that it runs on other distributions.

| File | Purpose |
| --- | --- |
| `build-appdir.sh` | Turns a release binary into an AppDir: the layout of the release archive, GTK's runtime data, GStreamer plugins, every shared library (glibc and its loader included), then `set-runpaths.sh`. |
| `set-runpaths.sh` | Gives every bundled ELF file a relative `DT_RPATH` pointing at `usr/lib`. |
| `exec.c` | Preloaded into Strata: programs it starts get the environment the AppImage was started with, not the one set up for the bundled runtime. |
| `AppRun` | Entry point. Installs the bundled loader, sets up the environment, tells the preview sandbox where the bundle is, starts Strata. |
| `test-appimage.sh` | The distribution test, run inside a stock container. |

To build one locally, on Ubuntu 24.04 with the packages the action installs:

```sh
cargo build --release --locked
packaging/appimage/build-appdir.sh target/release/strata AppDir
appimagetool --no-appstream AppDir
```

## How it works

- **Everything is bundled** except the GPU stack (Mesa, NVIDIA, Vulkan ICDs,
  VA-API drivers), which GTK renders and the media previews decode with and
  which has to match the host's kernel driver. That includes glibc, so the
  AppImage also runs on distributions older than the build host (Ubuntu 22.04
  is in the test matrix). The bundled loader lives at a fixed path,
  `/tmp/.strata-appimage-<hash>/ld-linux-*.so.*`, because the kernel cannot
  expand variables in an ELF interpreter; `AppRun` copies it there on start.
  Every bundled ELF file carries a relative RPATH instead of an exported
  `LD_LIBRARY_PATH`, which would leak into every program Strata starts.
- **Two host programs are still required**, as for every other way of running
  Strata: `bwrap` (bubblewrap) and `prlimit` (util-linux). The preview sandbox
  executes them from the host's trusted directories.
- **The preview sandbox sees the bundle.** Helpers run inside bubblewrap with
  a fresh `/tmp` and only the host's `/usr` bound, where neither the bundled
  loader nor the libraries exist. `AppRun` sets `STRATA_SANDBOX_EXTRA_ROOTS`
  to the mount point and the loader directory; Strata binds those read-only
  and runs the helper from its own path (`docs/preview-sandbox.md`,
  "Relocatable bundles").
- **GTK, GStreamer and GIO come only from the bundle.** `GTK_EXE_PREFIX`,
  `GDK_PIXBUF_MODULE_FILE`, `GST_PLUGIN_SYSTEM_PATH_1_0` with its own registry,
  and a `GIO_MODULE_DIR` holding nothing but GVfs's client keep the host's
  modules (built against the host's GLib and GTK) out. GVfs's client talks to
  the host's `gvfsd` over D-Bus, so remote locations work where the host has
  GVfs.
- **Host programs get the host's environment.** The applications Strata opens
  files with, terminals, `bwrap` and custom actions are host programs.
  `exec.so`, preloaded by `AppRun`, undoes every variable `AppRun` set on each
  `exec` and `posix_spawn`, so none of them sees the bundled runtime's
  settings or the preload itself.

## Limitations

- **In-app updates cannot replace the AppImage.** The updater installs over
  the running executable, which sits in a read-only image; use the new
  AppImage from the release instead. An install-source marker for AppImages
  is deliberately not shipped (`docs/packaging.md`, "Other distributions").
- **One user per machine for a given build.** The loader directory is created
  by the first user who starts the AppImage. `AppRun` refuses a directory that
  belongs to another user (other than root) or that anyone else can write to,
  because it is executed as the interpreter of every process in the bundle. A
  second user gets an error until the directory is gone (when `/tmp` is
  cleaned, for example on reboot).
- **`/tmp` must allow executing files.** On a system where `/tmp` is mounted
  `noexec` the AppImage cannot start.
- **Hardware video decoding** depends on the host's VA-API or Vulkan drivers,
  as it does for every install.
- The portal and `udiskie` integrations (`--install-portal`,
  `--install-udiskie-unlock`) write files that point at the AppImage's current
  path; moving it breaks them until they are reinstalled.

## Troubleshooting

`STRATA_APPIMAGE_DEBUG=1 ./strata-*.AppImage` prints the environment and GTK's
OpenGL debug output and, with `gdb` installed, a backtrace of a crash. If a
window appears but stays empty, try `GSK_RENDERER=cairo` to rule out the
host's OpenGL driver.

## Updating the pinned `appimagetool`

The action downloads a tagged `appimagetool` release and verifies it with
`sha256sum -c`. To update, change `APPIMAGETOOL_VERSION` and both checksums in
`.github/actions/appimage/action.yml` together; each checksum is the SHA-256 of
`https://github.com/AppImage/appimagetool/releases/download/<tag>/appimagetool-<arch>.AppImage`.
