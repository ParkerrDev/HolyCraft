# HolyCraft

A small voxel sandbox for TempleOS, written in HolyC: walk a blocky world, break blocks and place new
ones in any of the 16 system colors. One source file, `HolyCraft.HC`, builds two ways:

- **TempleOS V5.03** (with `TOS_NATIVE` defined): draws through the window's `draw_it` callback, reads
  the keyboard from `kbd.down_bitmap` and `ScanMsg`, and renders the world's exposed block faces as
  z-buffered polygons with `GrFillPoly3`.
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
```

They compile the browser build with HolyC-wasm and run it on a clock they move. The input test checks
that a still mouse leaves the camera still, one mouse move turns it once, a held key moves the player and
letting go stops it. The physics test checks that the player walks as far in a second at 10 frames a
second as at 60, that the player's box keeps the eye out of walls, ceilings and the world's edges, and
that a block is not placed where the player stands. They find HolyC-wasm in `$HOLYC_WASM` or beside
this repository (`../HolyC-wasm`), and skip when it is not there.
