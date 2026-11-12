# orca-slicer-nix

A Nix flake overlay that packages [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer) by building it from the
source tarball of each upstream GitHub release — never from the AppImage.

## Usage

```nix
{
  inputs.orca-slicer-nix.url = "github:<you>/orca-slicer-nix";

  outputs = { self, nixpkgs, orca-slicer-nix, ... }: {
    # as an overlay
    nixpkgs.overlays = [ orca-slicer-nix.overlays.default ];

    # or directly
    # orca-slicer-nix.packages.x86_64-linux.orca-slicer
  };
}
```

Or try it without installing anything:

```sh
nix run github:<you>/orca-slicer-nix
```

## How the package is built

`pkgs/orca-slicer/default.nix` fetches the tagged source (`vX.Y.Z`) named in `pkgs/orca-slicer/version.json` and
builds it with CMake/Clang, following the same shape as nixpkgs' own `orca-slicer` package, adjusted for things that
changed in OrcaSlicer 2.5.0's build system:

- an embedded Python 3.12 interpreter (via pybind11), where upstream's CMake pins an exact bundled patch version —
  patched to accept any 3.12.x
- a `uv` executable path, so CMake configure doesn't try to download one (no network access during a Nix build)
- OpenCASCADE and `usrsctp`, which upstream's CMake looks up via its own single-prefix "deps" convention rather than
  the normal nixpkgs mechanism — handled with a small staging directory assembled in `preConfigure`; OpenCASCADE's
  shared libraries also need an explicit runtime library path, since they're only ever linked via that staging
  directory and the automatic rpath nixpkgs would otherwise add doesn't survive past the build sandbox
- `libdatachannel` (WebRTC data channels) and `wxInspector` (a small wxWidgets debug panel, vendored upstream via
  its own `deps/wxInspector` build and packaged here directly from its GitHub source), two new dependencies for the
  GUI
- a hardcoded, exact-version copy of ffmpeg's shared libraries that upstream's CMake installs next to the binary for
  self-contained/AppImage-style distribution — skipped under `SLIC3R_FHS`, since nixpkgs' ffmpeg is a different
  major version with different library names, and the installed binary finds ffmpeg via its normal rpath anyway

The parametric Design/CAD tab (`SLIC3R_CAD`) is turned off: it needs upstream's own vendored SolveSpace solver build
(`deps/SLVS`), which isn't packaged in nixpkgs and wasn't worth vendoring just for this. Everything else, including
normal slicing, is unaffected — verified with a headless slice (`orca-slicer --slice 0 --export-3mf ...`) against a
bundled test STL.

Python-based plugin/scripting features are not expected to work: on a plain FHS-style Linux install (which is what
this package produces), upstream's own build does not bundle a Python runtime into the installed tree, so the app's
own runtime lookup for a bundled interpreter will come up empty. Everything else should work as normal.

## Automated updates

`.github/workflows/update.yml` runs on a schedule (twice a day) and on demand:

1. checks `OrcaSlicer/OrcaSlicer`'s latest GitHub release
2. if it's newer than `pkgs/orca-slicer/version.json`, prefetches the new source hash and writes it there
3. builds the package
4. only if that build succeeds: commits the version bump, tags it, and publishes a GitHub release in this repo

No one reviews these updates before they go out — if the build fails, the workflow leaves `version.json` untouched
and the job just shows as failed; nothing is published.

For this to work on a fresh fork/clone:

- the repo's Actions must be allowed to push to `main` (Settings → Actions → General → Workflow permissions →
  "Read and write permissions")
- optionally, set the `CACHIX_CACHE_NAME` repo/org variable and `CACHIX_AUTH_TOKEN` secret to use a
  [Cachix](https://www.cachix.org/) binary cache — without one, every run recompiles the large from-source
  dependencies (wxWidgets, Boost, CGAL, OpenCASCADE, OpenCV, ...) that aren't on cache.nixos.org, which is both slow
  and at real risk of hitting the 6-hour GitHub Actions job limit
