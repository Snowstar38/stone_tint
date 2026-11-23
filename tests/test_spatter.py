"""Spatter laid over tinted edges, and the floor + edge composite, offline under Lua 5.3.

The in-game texture read (read_surface) needs DF's memory; it was checked in game:
spatter pictures read from enabler.textures.raws matched their PNG cells exactly.
Here the game's own snow.png cells stand in for it.
"""
import os
import sys
from pathlib import Path
from PIL import Image

from lua_harness import load_lua

# Set DF_PATH to your Dwarf Fortress folder if it is not the default Steam location.
DF = Path(os.environ.get(
    'DF_PATH', r'C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress'))
SNOW = DF / 'data' / 'vanilla' / 'vanilla_environment' / 'graphics' / 'images' / 'snow.png'
if not SNOW.exists():
    print(f'SKIP: {SNOW} not found (set DF_PATH)')
    sys.exit(0)

lua, mod, _ = load_lua()
get = lua.eval('''function(f, name)
    for i=1,200 do
        local n,v = debug.getupvalue(f,i)
        if n == name then return v end
        if not n then break end
    end
    error('missing upvalue '..name)
end''')
setv = lua.eval('''function(f, name, value)
    for i=1,200 do
        local n = debug.getupvalue(f,i)
        if n == name then debug.setupvalue(f,i,value) return end
        if not n then break end
    end
    error('missing upvalue '..name)
end''')
render = mod.StoneTintOverlay.onRenderFrame
paint = get(render, 'paint_edges')
edges_texpos = get(paint, 'edges_texpos')

im = Image.open(SNOW).convert('RGBA')
def cell(cx, cy):
    out = []
    for y in range(cy * 32, cy * 32 + 32):
        for x in range(cx * 32, cx * 32 + 32):
            r, g, b, a = im.getpixel((x, y))
            out.append(0 if a == 0 else (a << 24) | (b << 16) | (g << 8) | r)
    return out
# Texpos 500: SNOW 0:0 (FULL_NSWE_A); 501: SNOW 4:3 (PARTIAL_1A); 502: unreadable.
cells = {500: cell(0, 0), 501: cell(4, 3)}
setv(edges_texpos, 'spatter_pixels',
     lambda t: lua.table_from(cells[t]) if t in cells else False)

setv(edges_texpos, 'colour_entries', lua.eval('''function()
    return {packed=setmetatable({}, {__index=function(_, j)
        return j == 1 and 0 or 0xFF305A8C end})}
end'''))
captured = {}
def create(pixels, *a):
    captured['px'] = [pixels[i] for i in range(1, 1025)]
    return lua.table_from([42])
lua.globals().dfhack.textures = lua.table_from({
    'createTileset': create, 'getTexposByHandle': lambda h: 4242})
mod.stone_tint_textures = lua.eval('{}')
lay_over = get(edges_texpos, 'lay_over')
cell_pixels = get(edges_texpos, 'cell_pixels')
colour_entries = get(edges_texpos, 'colour_entries')
art_cell = get(edges_texpos, 'ART_CELL')
ART_COUNT = get(paint, 'ART_COUNT')

keys = lua.table_from([3 * ART_COUNT + 15])   # DIRT_FLOOR_2, colour code 3
edge = cell_pixels(art_cell[15], colour_entries(2, 50))
edge = [edge[i] for i in range(1, 1025)]

for sp, label in [(501, 'partial snow'), (500, 'full snow')]:
    t, left = edges_texpos(keys, 1, 50, 5, sp)
    assert t == 4242 and left == 4, (t, left)
    want = lua.table_from(edge)
    lay_over(want, lua.table_from(cells[sp]))
    got = captured['px']
    assert got == [want[i] for i in range(1, 1025)], label
    # Every opaque snow pixel comes through untouched: the snow is never tinted.
    for i, px in enumerate(cells[sp]):
        if px >> 24 == 255:
            assert got[i] == px, f'{label}: snow pixel {i} altered'
    print(f'PASS edge + {label}: composite exact, snow pixels untinted')

t, left = edges_texpos(keys, 1, 50, 5, 502)
assert t is False, t
print('PASS unreadable spatter: no texture made')
mod.stone_tint_textures = lua.eval('{}')
edges_texpos(keys, 1, 50, 5)
assert captured['px'] == edge, 'plain edge'
print('PASS plain edge unchanged')

# EDGES UNDER DF'S EDGES: floor first, then the edge, nothing else.
mod.stone_tint_textures = lua.eval('{}')
floor_key = 3 * ART_COUNT + 14            # DIRT_FLOOR_1, the floor itself
t, left = edges_texpos(keys, 1, 50, 5, None, floor_key)
assert t == 4242 and left == 4, (t, left)
floor_px = cell_pixels(art_cell[14], colour_entries(2, 50))
want = lua.table_from([floor_px[i] for i in range(1, 1025)])
lay_over(want, lua.table_from(edge))
assert captured['px'] == [want[i] for i in range(1, 1025)], 'floor + edge composite'
print('PASS floor + edge composite exact')
