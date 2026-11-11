# HolyCraft

A small voxel sandbox for TempleOS, written in HolyC: walk a blocky world, break blocks and place new
ones in any of the 16 system colors. One source file, `HolyCraft.HC`, builds two ways:

- **TempleOS V5.03** (with `TOS_NATIVE` defined): draws through the window's `draw_it` callback, reads
  the keyboard from `kbd.down_bitmap` and `ScanMsg`, and renders the world's exposed block faces as
  near-clipped, subpixel spans with reciprocal depth and `GrHLine`. A private drawing context
  lets the TempleOS compositor clip moving windows; resizing grows its buffers as needed.
- **The browser**, compiled to WebAssembly by [HolyC-wasm](https://github.com/ParkerrDev/HolyC-wasm): a
  per-pixel voxel raycaster presented with `GrSprite`, with mouse look through the `Browser*` globals
  below. This is the build [TempleOS-Web](https://github.com/ParkerrDev/TempleOS-Web) plays in its Games
  menu.

## Play it in TempleOS

Copy `HolyCraft.HC` and `Run.HC` into one folder on the TempleOS disk, for example `C:/Home/HolyCraft/`,
then at the TempleOS prompt:

```
#include "C:/Home/HolyCraft/Run"
```

`Run.HC` changes to its own folder, defines `TOS_NATIVE` and includes the game, which starts at once.
Without `Run.HC`, type `#define TOS_NATIVE 1` first and then `#include` the game file.

| Key | Action |
|---|---|
| W / S | forward / back |
| A / D | strafe left / right |
| Mouse, or J / L and I / K | turn, and look up / down |
| Space | jump |
| G | fly on or off; R / F rise and sink while flying |
| Left click | break the block under the cross |
| Right click | place the selected block |
| 1 to 9, Q / E, arrow keys | pick a block |
| Esc | quit |

## Build it for the browser

Compile `HolyCraft.HC` with HolyC-wasm without defining `TOS_NATIVE`. The page that hosts it talks to the
game through four globals:

| Global | Set by | Meaning |
|---|---|---|
| `I64 BrowserMouseCapture` | the game | 1 while it wants the pointer locked |
| `I64 BrowserMouseDX`, `BrowserMouseDY` | the page | mouse movement since the last frame; the game reads and zeroes them |
| `U8 BrowserKeys[128]` | the page | 1 for each scan code held down |

## Test

```sh
node tools/input.test.mjs
node tools/physics.test.mjs
node tools/window.test.mjs
node tools/render/web.mjs check
```

They compile the browser build with HolyC-wasm and run it on a clock they move. The input test checks
that a still mouse leaves the camera still, one mouse move turns it once, a held key moves the player and
letting go stops it. The physics test checks that the player walks as far in a second at 10 frames a
second as at 60, that the player's box keeps the eye out of walls, ceilings and the world's edges, and
that a block is not placed where the player stands. They find HolyC-wasm in `$HOLYC_WASM` or beside
this repository (`../HolyC-wasm`). A missing compiler fails the checks. The window check guards
the HUD buffer and row padding at seven sizes, and checks that cleanup followed by Init restarts
the game. The renderer check compares all visible faces before fog with independent exact rays
at 48 fixed and seeded camera poses, including close walls, ceilings and world boundaries.


The native checks use the actual TempleOS V5.03 compiler and drawing routines inside HEMU. They
need a TempleOS-Web checkout with its HEMU and HolyC-wasm dependencies, tracked snapshot/disk,
and `tools/hemu/Fixtures.mjs`:

```sh
export TEMPLEOS_WEB=/path/to/TempleOS-Web
node --max-old-space-size=3072 tools/render/tos.mjs check
HLE=0 node --max-old-space-size=3072 tools/render/tos.mjs check
node --max-old-space-size=3072 tools/render/tos.mjs windows
```

The native ray comparison covers 45 poses. Three browser stress poses put the eye inside a
solid block, which the player box prevents during play; the native exposed-face renderer does
not support those poses. Colors identify each material and face, avoiding random dither in the
comparison. Matching pre-fog faces also have their integer reciprocal depths
checked against the independent rays: endpoint truncation and interpolation
flooring allow an error from -2 to 0 depth units, plus a 0.0001-unit margin for
32.32 slope quantization and floating-point plane setup in these 640-wide views.
This is separate from the visibility classifier's looser distance tolerance;
it checks both displaced-nearer and displaced-farther surfaces. It does not require
bit-identical depth buffers across different rendering algorithms.
The native limit is 0.87 cells before fog starts because fog is selected at each block's center.
`HLE=0` disables raster acceleration and asserts that it stayed disabled. The `windows` check
compares DrawIt with a separately rendered view at seven sizes, including odd widths and repeated
growth/shrink. It does not substitute for testing actual window occlusion in QEMU or on hardware.

When HolyC-wasm includes the recovered native oracle runner, QEMU can also check eight
near-clipping/ceiling camera poses using its original TempleOS disk and compiler:

```sh
node tools/render/qemu.mjs check
REPEATS=3 node tools/render/qemu.mjs time /path/to/prior/HolyCraft.HC
```

The QEMU check compares 1,320,325 pre-fog pixels against independent ray results. It uses
a deterministic scene and reports the QEMU backend plus the path to its execution evidence.
The timing command warms each renderer, then measures 200 spawn-view frames using guest
`tS`; `N` changes the frame count. The baseline source must provide the native rendering API.

To measure rendering on the current machine:

```sh
node tools/render/web.mjs bench
N=15 node --max-old-space-size=3072 tools/render/tos.mjs time
```

`SRC` can select a different HolyCraft source for a regression comparison. `POSE` selects one
native check pose; `OUT` saves its frame, depth and world arrays for diagnosis. `LIVE` and `RAW`
can select alternate snapshot/disk fixtures. No test writes to the bundled disk image.
The timing mode retains the game's actual material and sky colors. The geometry checks
replace them with face-identifying colors; those diagnostic colors must not be used to
measure optimizations that depend on whether two shades are equal.
Equal face shades use solid drawing. This preserves their color while consuming fewer
random values, so subsequent dither and sky noise need not match an older seeded frame.

Native rendering performance is still being optimized. The precise scanline renderer fixes
missing blocks, but it is slower in HEMU than the earlier integer polygon path. Passing these
checks establishes the listed cases, not universal parity or a frame-rate guarantee across
QEMU, VirtualBox, VMware and bare metal. The native and browser rendering/input adapters still
differ; replacing them with one native API path depends on HolyC-wasm runtime support.
