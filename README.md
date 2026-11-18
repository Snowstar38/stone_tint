# Stone Tint

A DFHack mod that colors natural stone and soil floors, stairs, and ramps by their material, with support for graphics mods.

Version **1.2.1**. Source is in [`stone_tint/`](stone_tint/); see the [mod README](stone_tint/README.md) for features and settings.

With contributions from [grungeisdead](https://github.com/grungeisdead85/stone_tint).

## Development

The runtime is Lua source and needs no compilation. It requires DFHack 53.15-r3
or a compatible release. For local testing, copy the contents of
`stone_tint/scripts_modinstalled/` into your Dwarf Fortress
`dfhack-config/scripts/` directory, preserving the helper subdirectory. Back up
any existing overrides first. Restart the game after source changes, then run
`overlay enable stone-tint.map` and `stone-tint` in the DFHack console.

Source paths below are relative to `stone_tint/scripts_modinstalled/`:

- `stone-tint.lua`: renderer, settings GUI, material colors, and blend modes.
- `stone-tint/graphicsraws.lua`: graphics tokens and mod load order.
- `stone-tint/imagedecode.lua` and `stone-tint/liveart.lua`: image decoding and
  tintable art from the loaded graphics.
- `stone-tint/art-vanilla.lua`: generated fallback art.

### Tests

Run the 12 offline edge-rendering regression checks from the repository root:

```sh
python -m pip install lupa
python tests/test_edges.py
```

These use Lua 5.3 with mocked game state. For rendering changes, also check the
result in-game on the current and lower levels, with the overlay on and off.
When sharing results, include the DF/DFHack versions, graphics mods, tint
settings, and screenshots.

### Regenerate fallback art

The generated data is already included. To rebuild it using your own vanilla
graphics:

```sh
python -m pip install numpy Pillow
python stone_tint/scripts_modinstalled/stone-tint/build_stone_tint_art.py "/path/to/Dwarf Fortress/data/vanilla" stone_tint/scripts_modinstalled/stone-tint/art-vanilla.lua
```

Keep `engraved_floor_plain.png` beside the generator. Graphics from other mods
are read from the player's installation at runtime.
