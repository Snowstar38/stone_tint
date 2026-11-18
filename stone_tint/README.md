# Stone Tint

Natural stone and soil floors, engraved floors, stairs and ramps display subtle colors based on
their actual material. Bauxite is vermilion, limonite is saffron, cassiterite is gray, microcline
is aqua, and so on.

## Requirement

DFHack 53.15-r3 or a compatible release is required.

## Use

In the DFHack console:

```text
overlay enable stone-tint.map
stone-tint
```

The GUI offers Off, 10%, 15%, 20%, 25%, 30%, 40%, 50%, 75% and 100% strengths, and switches for
rough, smooth and engraved floors, stairs, ramps, soil, engraving faces and ramp overlays.
Settings persist with each fortress. The default is 50%.

`stone-tint status` reports what was tinted in the last drawn frame, `stone-tint set <strength>`
sets the strength, and `stone-tint clear-cache` rereads the materials.

Stone Tint changes rendering only. It does not modify saves or map tiles.

## Graphics mods

Stone Tint tints whatever floor, stair and ramp art your world actually loads. When a world
loads, it reads the graphics files of every mod in that world, in load order, and works out
which picture each floor, stair and ramp really uses. If a mod replaces them (Rounded Hills,
Detailed Landscapes and others), Stone Tint reads that mod's images from your own install and
tints those. Rounded ramps stay rounded and detailed floors keep their detail. Engraving mods
work the same way: with Sumptuously Engraved Floors, its engravings are what gets tinted. (Such
a picture has no dwarf face to carve out, so "Engraving faces" changes nothing under it.)

The rough edges a floor spills onto its neighbours are tinted too, in the colour of the floor
they come from, wherever the game draws an uneven edge, regardless of the neighbouring
terrain. This also applies to visible edges on levels below the current one.

**You no longer need to delete floor, stair or ramp tiles from other mods.** If you did so for
an earlier version, you can put them back. `stone-tint status` lists the pages the art was read
from. If anything cannot be read, Stone Tint falls back to vanilla's art.

## Blend

Since 1.2.0 the tint keeps the art's own light and dark detail, and moves only its color and
overall brightness. The light/dark shapes of the stone stay intact, while dark stones like jet
still come out dark and light ones like marble light. It looks better on vanilla's art too.

The previous look is still there if you prefer it: `stone-tint blend legacy` (and
`stone-tint blend default` to return). The setting is saved with each fortress.

## Engraved floors

Dwarf Fortress draws natural engraved floors with a fixed blue-gray picture that ignores the
stone. Stone Tint draws engraved floors in their stone's color at the same strength as the floor
around them. With "Engraving faces" switched off, an engraved floor keeps its carved border and
the dwarf face is left out.

## Ramp overlays

Some graphics mods draw their own overlay on top of every ramp, which covers the tint.
"Hide ramp overlays" removes it. Ramp shadows are kept either way.

It is **off by default**, and on a vanilla install you should not need it: tested on DF 53.16
with no other mods loaded, natural ramps tint as strongly as the floors beside them, and the
switch makes no visible difference. It affects every ramp in the game rather than only the tinted
ones — constructed ramps lose their overlay without gaining any tint — so leave it off unless a
mod you have is actually covering your ramps.

## Performance

Dwarf Fortress rebuilds its map background texture buffer every rendered frame, so the visible
viewport must be scanned every frame. On an 86-by-45 viewport at a 100 FPS cap, the optimized
renderer measured 3.45 to 3.81% of wall time. This is about five times faster, but it is still 
a measurable always-on cost.

If changed geology ever displays a stale color, run `stone-tint clear-cache`.

## Material colors

Up to version 1.0.0 the tint read each stone's color out of `palettes.png` by the color's
position in the descriptor list. Dwarf Fortress does not number them that way: it assigns rows
with `[PALETTE_COLOR:...]`, and two rows of `palettes.png` belong to no color at all, so every
color past the first gap sat one row off and every color past the second sat two. 83 of
vanilla's 134 colors were drawn in a neighbour's color — bauxite came out turquoise instead of
vermilion, cinnabar raw umber instead of red, brimstone white instead of yellow. From 1.1.0 the
color is read from the palette row the game itself assigns, so a stone is drawn in its own
color. Colors added by other mods should work now as well.

## Credits

Stairs, ramps across the levels below, engraved floors, soil, the live sprite-map renderer and
the settings page are the work of **grungeisdead** (<https://github.com/grungeisdead85/stone_tint>),
contributed in October 2026.
