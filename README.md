# Stone Tint

The canonical source repository for Snowstar's Dwarf Fortress / DFHack Stone Tint
mod, version **1.2.1**. The installable mod is in [`stone_tint/`](stone_tint/); its
[README](stone_tint/README.md) describes the controls and graphics compatibility.

This repository includes [grungeisdead's renderer contribution](https://github.com/grungeisdead85/stone_tint)
and adds the subsequent changes from the current mod, including graphics-mod art
support, the contrast-preserving blend, and rough-floor edge tinting.

## Run a development copy

The runtime is Lua source; there is no compilation step. Install DFHack
53.15-r3 or a compatible release, then copy the `stone_tint` directory into
your Dwarf Fortress `mods` directory. In the DFHack console, run:

```text
overlay enable stone-tint.map
stone-tint
```

DFHack can select a world-active version of a mod over another installed copy.
For reliable iteration on an existing fort, copy the contents of
`stone_tint/scripts_modinstalled/` into `dfhack-config/scripts/`, preserving the
`stone-tint/` helper directory, and restart Dwarf Fortress after source changes.
Back up any existing development override first; remove your override when
returning to the Workshop version.

The `STEAM_FILE_ID` in `stone_tint/info.txt` belongs to the existing Stone Tint
Workshop item. Remove it from your own upload package if publishing a separate
item.

## Source layout

- `stone-tint.lua`: renderer, settings GUI, material colors, and blend modes.
- `stone-tint/graphicsraws.lua`: resolves graphics tokens and mod load order.
- `stone-tint/imagedecode.lua`: reads PNG and BMP images from the installation.
- `stone-tint/liveart.lua`: builds tintable art from the graphics actually loaded.
- `stone-tint/art-vanilla.lua`: generated vanilla fallback art.
- `stone-tint/build_stone_tint_art.py` and `engraved_floor_plain.png`: sources
  needed to regenerate that fallback.

All paths above are relative to `stone_tint/scripts_modinstalled/`.

## Regenerate vanilla fallback art

The generated Lua data is already included. Regeneration requires Python,
NumPy, Pillow, and your own Dwarf Fortress vanilla graphics:

```sh
python -m pip install numpy Pillow
python stone_tint/scripts_modinstalled/stone-tint/build_stone_tint_art.py "/path/to/Dwarf Fortress/data/vanilla" stone_tint/scripts_modinstalled/stone-tint/art-vanilla.lua
```

Keep `engraved_floor_plain.png` beside the generator. Graphics from other mods
are read from each player's installation at runtime; they are not bundled here.

## Contributing

The existing edge-render regression checks run offline against the actual Lua
renderer with mocked DF state. They require Python and Lupa's Lua 5.3 module:

```sh
python -m pip install lupa
python tests/test_edges.py
```

The 12 cases cover recognized and unrecognized receiving terrain, the current
and lower levels, disabled rough tint, occupied backgrounds, missing edge flags,
and texture-budget exhaustion. They do not replace visual testing in the game.

Create a branch from `main`, edit the Lua sources, test in a DFHack-enabled
fortress, and open a pull request. For rendering changes, include the DF and
DFHack versions, active graphics mods, relevant tint settings, and before/after
screenshots. Check the current level and visible lower levels, and verify that
turning the overlay off restores the normal rendering.
