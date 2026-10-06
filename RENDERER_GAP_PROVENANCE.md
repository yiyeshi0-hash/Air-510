# RENDERER-GAP: vendored renderer provenance

These trees/binaries were imported from the teammate fork **`Gsjsjzhznsz/Air-Minecraft-iOS-Launcher`**
(same project family; a later fork of this tree). Nothing was pushed to any remote — this is a
local-only import into `tree510`. See `D:\CTF\_RENDERER_GAP_REPORT.md` for the full diff table.

> ★ [DROP-NGG4ES] The NG-GL4ES ("Krypton Wrapper", `BZLZHH/NG-GL4ES`) import was **removed entirely**:
> the source tree `ThirdParty/ZalithLauncher2/`, the Makefile `dep_nggl4es` target, and all of its
> wiring (`RENDERER_NAME_NGGL4ES`, `isNGGL4ESRenderer`, candidate entry, `NGG_DIR_PATH`, boot branch)
> were dropped. Reason: competitor repository — its code must not enter this tree.
> The three imported-and-kept renderers are **VGPU**, **GL4ESZL2** and **VirGL**.

| Path in this tree | Upstream origin | License | Notes |
|---|---|---|---|
| `Natives/external/vgpu/` | [PojavLauncherTeam/VGPU](https://github.com/PojavLauncherTeam/VGPU) (gl4es fork + shader-syntax rewriter), as vendored by the teammate fork (Task173 iOS patches) | MIT (gl4es lineage: © Sebastien Chevalier / Ryan Hileman) | No LICENSE file shipped upstream; MIT per gl4es. Builds `libvgpu.dylib` via CMake (opt-in, `AME_RENDERER_GAP_VGPU=ON`). |
| `Natives/external/virglrenderer/` | [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) 1.3.0 | MIT (`COPYING`) | Builds `libvtestserver.dylib` via Makefile `dep_virgl` (meson). |
| `Natives/external/libepoxy/` | [libepoxy](https://github.com/anholt/libepoxy) (iOS-patched: dlopen → ANGLE frameworks) | MIT (`COPYING`) | Static lib consumed by `libvtestserver.dylib`. |
| `ThirdParty/gl4es_extra_extra/` | [PojavLauncherTeam/gl4es_extra_extra](https://github.com/PojavLauncherTeam/gl4es_extra_extra) | MIT (`LICENSE`) | ZL2 classic gl4es. Builds `libgl4eszl2.dylib` via Makefile `dep_gl4eszl2`. |
| ~~`ThirdParty/ZalithLauncher2/`~~ | ~~[BZLZHH/NG-GL4ES](https://github.com/BZLZHH/NG-GL4ES) ("Krypton Wrapper")~~ | — | ★ [DROP-NGG4ES] **REMOVED** (competitor code). Was `libnggl4es.dylib` via `dep_nggl4es`. |
| `Natives/ctxbridges/virgl_server.{m,h}` | teammate fork (Task215) | same as this repo (LICENSE) | vtest server bootstrap bridge. |
| `Natives/ctxbridges/gl4es_family_boot.{m,h}` | derived from teammate fork's `egl_bridge.m` Task204/211 helpers, refactored into one file | same as this repo (LICENSE) | gl4es-family (VGPU/GL4ESZL2) boot glue. |
| `patches/mesa-215-osmesa-virgl.patch` | teammate fork (Task215) | same as this repo (LICENSE) | Applied to a Mesa 25.0.7 tarball **downloaded at build time** (Mesa is MIT; not vendored into git). |

All renderer dylibs above are **build outputs**, not committed binaries — they are produced by
`make dep_gl4eszl2 / dep_virgl` (or `RENDERER_GAP_EXTRAS=1`) and, for VGPU, by the
opt-in CMake target. Until built, the corresponding entries stay hidden from the settings picker
(existence filter in `Natives/LauncherPreferences.m`).
