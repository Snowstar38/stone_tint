-- Tint natural stone and soil floors, stairs and ramps by their material.
--@ module = true

--[====[

stone-tint
==========

Tags: fort | graphics | map

Tints natural stone and soil floors, engraved floors, stairs and ramps in the
colour of what they are made of, on your level and the levels you can see
below. Works with graphics mods: it tints whatever floor art your world loads.

Usage
-----

``stone-tint``
    Open the settings window: strength, which tiles to tint, and floor edges.
``stone-tint set <strength>``
    Set the strength: 0 (off), 10, 15, 20, 25, 30, 40, 50, 75 or 100.
``stone-tint edges smart|simple|off``
    How tinted floor edges are drawn. ``smart`` (default) keeps snow, mud,
    leaves and grass edges on top of them; ``simple`` draws them on top of
    everything; ``off`` leaves edges untinted.
``stone-tint blend default|legacy``
    ``legacy`` is the flatter tint from before 1.2.0.
``stone-tint status``
    What was tinted last frame and which art was read.
``stone-tint clear-cache``
    Reread the materials, if a changed tile shows a stale colour.

If nothing is tinted, enable the overlay with ``overlay enable stone-tint.map``.
Settings are saved with each fortress.

]====]

local overlay = require('plugins.overlay')
local tile_material = require('tile-material')
local gui = require('gui')
local widgets = require('gui.widgets')

-- The strength ladder. Nothing here is baked any more: a strength is a number
-- the tint is computed with while the game runs (THE TINT), so these values are
-- free to choose. The old PNG sheets stopped at 50% because 50% was the last
-- sheet that existed; 75 and 100 close a request made in the workshop comments
-- in August 2026 that there was no sheet to answer.
--
-- Ten is the most stops that fit: gui.widgets Slider draws
-- (stops - 1) * max(3, (w - 7) // (stops - 1)) + 6 columns, which is 33 of the
-- slider's 38 at ten stops and 42 at thirteen. Add more and widen the slider
-- and the window together, or the track runs past the frame.
local STRENGTHS = {0, 10, 15, 20, 25, 30, 40, 50, 75, 100}
local GLOBAL_KEY = 'stone-tint'
local CELL_PX = 32
-- New textures made per frame at most. The first sight of a material makes one
-- texture per kind of tile it covers; a z-level full of new materials would
-- otherwise make them all in one frame and stall it. A tile waiting its turn
-- keeps DF's own picture for a frame or two.
local NEW_TEXTURES_PER_FRAME = 32

-- ==========================================
-- THE ART
-- ==========================================
-- Vanilla's floor, stair and ramp art as Lua data, written by
-- build_stone_tint_art.py: DF cannot hand a PNG's pixels back to a script, so
-- art that is tinted while the game runs has to exist as data. Each pixel
-- carries its key column, the palette column its tint blends toward.
local ok_art, art = pcall(reqscript, 'stone-tint/art-vanilla')
if not ok_art or type(art) ~= 'table' or not art.CELLS then
    dfhack.printerr('stone-tint: could not load stone-tint/art-vanilla.lua; nothing will be tinted')
    art = nil
end
-- The art actually drawn: vanilla's, or the loaded world's own pages when a
-- graphics mod re-points the floor, stair or ramp tokens (LIVE ART, below).
local vanilla_art = art
local ok_live, liveart = pcall(reqscript, 'stone-tint/liveart')
local ok_raws, graphicsraws = pcall(reqscript, 'stone-tint/graphicsraws')
local ok_decode, imagedecode = pcall(reqscript, 'stone-tint/imagedecode')

-- ==========================================
-- KINDS OF TILE
-- ==========================================
-- Every picture stone-tint can draw gets an id: its art cell, the switch group
-- that turns it on, and the kind it is counted as in `stone-tint status`.
-- Groups: a soil tile needs both "Include soil" and the switch for its shape.
local G_ROUGH, G_SMOOTH, G_STAIRS, G_RAMPS = 1, 2, 3, 4
local G_SOIL_FLOORS, G_SOIL_STAIRS, G_SOIL_RAMPS = 5, 6, 7
local G_ENGRAVED = 8
local K_FLOOR, K_STAIR, K_RAMP, K_ENGRAVED = 1, 2, 3, 4

local ART_CELL, ART_GROUP, ART_KIND = {}, {}, {}
local function add_art(cell, group, kind)
    local id = #ART_CELL + 1
    ART_CELL[id], ART_GROUP[id], ART_KIND[id] = cell, group, kind
    return id
end

-- 1 to 13: stone floors, in the order of VARIANTS below.
local FLOOR_SUFFIXES = {'1', '2', '3', '4', '5', '6', '7', '8', '9', '5b', '5c', '5d'}
for _, n in ipairs(FLOOR_SUFFIXES) do add_art('stone_floor_' .. n, G_ROUGH, K_FLOOR) end
add_art('smooth_floor', G_SMOOTH, K_FLOOR)
-- 14 to 25: soil floors, the same twelve on the dirt rows.
local FIRST_SOIL_FLOOR = #ART_CELL + 1
for _, n in ipairs(FLOOR_SUFFIXES) do add_art('soil_floor_' .. n, G_SOIL_FLOORS, K_FLOOR) end
-- 26 and 27: the engraved floor, as vanilla draws it and with the face carved
-- out. The "Engraving faces" switch picks which (ENGRAVED FLOORS, below).
local ENGRAVED_FACE = add_art('engraved_floor', G_ENGRAVED, K_ENGRAVED)
local ENGRAVED_PLAIN = add_art('engraved_floor_plain', G_ENGRAVED, K_ENGRAVED)

-- Stairs and ramps, by family ('stone' or 'soil'): STAIR_ART[family][shape]
-- and RAMP_ART[family][ramp cell].
local STAIR_ART, RAMP_ART = {stone={}, soil={}}, {stone={}, soil={}}
for _, family in ipairs({'stone', 'soil'}) do
    local group = family == 'stone' and G_STAIRS or G_SOIL_STAIRS
    for _, shape in ipairs({'updown', 'up', 'down'}) do
        STAIR_ART[family][shape] = add_art(family .. '_stair_' .. shape, group, K_STAIR)
    end
end
if art then
    local ramp_cells, seen = {}, {}
    for walls = 0, 255 do
        local c = art.RAMP_CELL[walls]
        if c and not seen[c] then seen[c] = true ramp_cells[#ramp_cells + 1] = c end
    end
    table.sort(ramp_cells)
    for _, family in ipairs({'stone', 'soil'}) do
        local group = family == 'stone' and G_RAMPS or G_SOIL_RAMPS
        for _, c in ipairs(ramp_cells) do
            RAMP_ART[family][c] = add_art(family .. '_ramp_' .. c, group, K_RAMP)
        end
    end
end
local ART_COUNT = #ART_CELL

-- ==========================================
-- FLOORS: LOOKED UP ON THE TILE PAGES
-- ==========================================
-- DF draws floors straight off their tile page, so their texposes are found by
-- page and cell. This order must match ids 1 to 13 above.
local VARIANTS = {
    {'DETAILED_FLOORS', 0, 3}, {'DETAILED_FLOORS', 1, 3}, {'DETAILED_FLOORS', 2, 3},
    {'DETAILED_FLOORS', 0, 4}, {'DETAILED_FLOORS', 1, 4}, {'DETAILED_FLOORS', 2, 4},
    {'DETAILED_FLOORS', 0, 5}, {'DETAILED_FLOORS', 1, 5}, {'DETAILED_FLOORS', 2, 5},
    {'DETAILED_ALT_FLOORS', 7, 4}, {'DETAILED_ALT_FLOORS', 7, 5}, {'DETAILED_ALT_FLOORS', 7, 6},
    {'FLOORS', 6, 3},
}
local VANILLA_VARIANTS = {
    {'FLOORS', 0, 3}, {'FLOORS', 1, 3}, {'FLOORS', 2, 3},
    {'FLOORS', 0, 4}, {'FLOORS', 1, 4}, {'FLOORS', 2, 4},
    {'FLOORS', 0, 5}, {'FLOORS', 1, 5}, {'FLOORS', 2, 5},
    {'ALT_FLOORS', 7, 4}, {'ALT_FLOORS', 7, 5}, {'ALT_FLOORS', 7, 6},
}
-- DIRT_FLOOR_1 to 9 and 5B to 5D, matching ids 14 to 25. Sand has pages of its
-- own (FLOOR_SAND), so sand floors never match these and keep DF's look.
local SOIL_VARIANTS = {
    {'FLOORS', 0, 6}, {'FLOORS', 1, 6}, {'FLOORS', 2, 6},
    {'FLOORS', 0, 7}, {'FLOORS', 1, 7}, {'FLOORS', 2, 7},
    {'FLOORS', 0, 8}, {'FLOORS', 1, 8}, {'FLOORS', 2, 8},
    {'ALT_FLOORS', 7, 7}, {'ALT_FLOORS', 7, 8}, {'ALT_FLOORS', 7, 9},
}

-- ==========================================
-- ENGRAVED FLOORS: LOOKED UP ON THEIR PAGES
-- ==========================================
-- Vanilla has two one-cell pages for an engraved stone floor.
-- FLOOR_STONE_ENGRAVED_PALETTE is drawn in four colours that are all palette
-- row 0 keys (columns 12 to 15), the mark of art DF recolours by palette.
-- FLOOR_STONE_ENGRAVED_NON_PALETTE is seven fixed blue-greys, none of them a
-- row 0 key, so no stone's colour can reach it. It was cut into vanilla's
-- smooth floor: outside the carving, every pixel is the smooth floor's own
-- (FLOORS 6:3, 468 of 1024 equal). Seen in play 2026-10-21: an engraved
-- claystone floor (CHOCOLATE) showed NON_PALETTE's blue-greys, 104,110,114 the
-- commonest pixel, beside an engraved claystone wall in the stone's brown. So
-- DF drew that natural engraved floor in the fixed art, not its stone's
-- colour, and it read as plain blue next to tinted floors.
--
-- stone-tint draws the NON_PALETTE cell in its place, keyed by luminance like
-- every other floor so it tints the same way as the floor around it, or the
-- same cell with the face carved out (engraved_floor_plain.png, see
-- build_stone_tint_art.py), as the "Engraving faces" switch says.
--
-- NOT YET MEASURED (2026-10-21): that DF puts the engraved page tile in
-- screentexpos_background, the way it does the smooth floor, rather than
-- drawing it over the floor from a flag, the way the ramp overlays come (RAMP
-- OVERLAYS). `stone-tint status` counts the engraved tiles drawn: none while
-- engraved floors are on screen means it does not. Both pages are looked up,
-- in case DF ever draws the PALETTE cell unswapped.
local ENGRAVED_PAGES = {
    {'FLOOR_STONE_ENGRAVED_NON_PALETTE', 0, 0},
    {'FLOOR_STONE_ENGRAVED_PALETTE', 0, 0},
}
-- Marks an engraved floor's page tile in floor_texpos and known_texpos. Not an
-- art id: whether the tile is natural stone is checked once per tile
-- (natural_engraved), and which picture it gets is the switch, read per frame.
local ENGRAVED = -2

-- ==========================================
-- STAIRS AND RAMPS: LEARNED FROM THE MAP
-- ==========================================
-- DF does not draw natural stairs or ramps off a tile page, so they cannot be
-- looked up the way floors are. Measured with stone-tint-stair-probe and
-- stone-tint-ramp-probe: every stone, mineral and soil stair and every stone
-- and mineral ramp held a texture in screentexpos_background that is on no
-- tile page, one per material and shape (every pyrite up-stair on screen shared
-- one; three tetrahedrite ramps against different walls had three), and no
-- other layer held anything for them. Grass stairs alone came straight off the
-- STAIRS page. The run-time textures were renumbered between runs along with
-- the pages. So the overlay learns them from the map instead (natural_art and
-- the render loop) and draws vanilla's art in their place: STAIRS rows 1 and 2
-- for stairs, STONE_RAMPS and SOIL_RAMPS for ramps.
--
-- A ramp's picture depends on which of its 8 neighbours are walls. DF works
-- that out itself and leaves it in screentexpos_ramp_flag, bits 8 to 15 in the
-- order N, W, E, S, NW, NE, SW, SE (the layout devel/inspect-screen decodes),
-- so the overlay reads DF's own answer rather than working it out again, and
-- art.RAMP_CELL turns it into the vanilla cell. The probe's ramps decoded as a
-- column against a west wall: N_W, W, S_W. The probe found nothing of the ramp
-- overlays or shadows (vanilla's or Dark Depths') in any texpos layer, and in
-- play Dark Depths' ramp overlay drew on top of our tinted ramps: DF draws
-- those from the flags after the background. The overlay is hidden separately
-- (RAMP OVERLAYS, below); the shadows stay.
local STAIR_SHAPES = {
    [df.tiletype_shape.STAIR_UPDOWN] = 'updown',
    [df.tiletype_shape.STAIR_UP] = 'up',
    [df.tiletype_shape.STAIR_DOWN] = 'down',
}
-- Natural stone, as with floors. Soil is its own family; ice, grass and
-- constructed tiles keep DF's own picture.
local STONE_MATERIALS = {
    [df.tiletype_material.STONE] = true,
    [df.tiletype_material.MINERAL] = true,
    [df.tiletype_material.FEATURE] = true,
    [df.tiletype_material.LAVA_STONE] = true,
}
-- Marks a texture DF drew on a natural stair or ramp in known_texpos (below).
local LEARNED = -1

-- ==========================================
-- THE LEVELS BELOW
-- ==========================================
-- Levels seen from above through open space (a ramp's top, a shaft, a cliff
-- edge) are not drawn in the main viewport. Measured with
-- stone-tint-depth-probe: DF keeps eight more viewports, gps.lower_viewport[0]
-- to [7], each the size of the main viewport and indexed the same way, and
-- [0] held the level just below the camera. [1] to [7] are taken to be the
-- levels below that, in order: DFHack's smooth-movement plugin draws them
-- deepest first, [7] up to [0], then the main viewport. A ramp seen from its
-- top sat in lower_viewport[0] with the same kind of run-time texture and
-- ramp flags it has on its own level, so it showed DF's untinted ramp. The
-- depth shading sat in that viewport's own screentexpos_interface layer,
-- which is drawn over its background, so it stays on top of a tint written
-- underneath. With Dark Depths that shading is its DARK_DEPTHS_Z page: the
-- same alpha as vanilla's MULTILEVEL_OVERLAY, in black where vanilla's is
-- light blue, at most 48 of 255 on a ramp.
--
-- On the probe's screen the main viewport held a background in 917 of its 920
-- cells and lower_viewport[0] held one in exactly the other 3. So the loop
-- walks down only through cells the level above left empty, and stops at the
-- first level where none are left, which on most screens is the first.
local LOWER_LEVELS = 8

-- ==========================================
-- STATE
-- ==========================================
-- texpos of a pristine game floor sprite -> art id, or ENGRAVED for an
-- engraved floor's page tile. Small (<= 39 entries).
local floor_texpos = {}
-- How many of ENGRAVED_PAGES were found on a loaded page, for `stone-tint status`.
local engraved_found = 0
-- Every texpos the floor buffers have shown since the last reset, filed once:
-- a floor art id, LEARNED, ENGRAVED, or false for anything that is not ours. One table
-- for every level, since a texture means the same thing at any depth, so the
-- common cell costs one lookup. Rebuilt from the floor sprites on every z
-- change, and when the floor sprites or our textures move, because DF
-- renumbers its run-time textures when it reloads them.
local known_texpos = {}
local cached_z
-- Per level, since the levels below are drawn too. Both are emptied on every
-- z change.
local color_cache = {}          -- [z] = {[world_x] = {[world_y] = colour code}}
-- [z] = {[world_x] = {[world_y] = {texpos=, id=}}}: what a learned stair or
-- ramp tile is, or whether an engraved floor is natural stone (ENGRAVED or
-- false), checked against the texture DF drew there, so a tile goes back to
-- the map only when its picture changes.
local tile_checks = {}
-- [z] = {[world_x] = {[world_y] = edge_source}}, emptied with the others.
local edge_cache = {}
local map_max_x, map_max_y      -- tile bounds, refreshed on map load
-- hide_overlays is off by default, so the game looks as it did before unless
-- you opt in. It is the one switch here that *removes* something DF
-- draws, and it does it to every ramp in the game rather than only the tinted
-- ones, so it is the one that should be asked for. The rest add tint to tiles
-- this mod now handles, which is what the update is for.
local state = {strength=50, rough=true, smooth=true, stairs=true, ramps=true, soil=true,
               hide_overlays=false, engraved=true, faces=true, blend='default',
               edges='smart'}
local view

-- Running stone-tint from the console re-executes this whole file in the same
-- environment: every local above starts over, while the overlay keeps drawing.
-- What has to survive that lives in environment globals instead: the counts
-- the console reads back, and the textures already made, so a console command
-- never makes a second set.
stone_tint_stats = stone_tint_stats or {floors=0, engraved=0, stairs=0, ramps=0, below=0,
    textures=0}
-- [strength] = {[colour code * ART_COUNT + art id] = handle, or false}
stone_tint_textures = stone_tint_textures or {}
if stone_tint_textures.art_count ~= ART_COUNT then
    stone_tint_textures = {art_count=ART_COUNT}
end

-- Resolved texposes for the strength in use: [colour code * ART_COUNT + art id]
-- -> texpos, or false for "nothing to draw". Thrown away when the strength
-- changes or our sentinel texture's texpos moves (DF reset its textures).
local tint_cache = {}
local tint_sentinel, tint_strength

-- Scratch tables reused every frame so the render loop allocates nothing.
local group_enabled = {}
local frame_counts = {0, 0, 0, 0}
-- Cell indices the level above left empty, for the next level down. Two lists
-- that swap roles level by level; only the first n entries of each are live.
local see_through, see_next = {}, {}

-- ==========================================
-- COLOUR
-- ==========================================
-- A material's state_color.Solid is a PATTERN index (descriptors.patterns),
-- not a colour index; the colour DF draws with is the pattern's first. Read as
-- a colour index it only lines up for vanilla's own colours, while a mod's
-- colours sit at the end of the pattern list (found in Refinish Metal's
-- refinish-sprite-art). Every colour carries its palette row live, as
-- palette.color: 18 colours, 54 bytes. The old sheets looked rows up on
-- palettes.png by colour index + 1, but that image has two rows no colour uses
-- (52 and 116), so 83 of vanilla's 134 colours wore a neighbour's row (slate
-- gray stone got sky blue's) and a mod's colours had no row at all.
local palettes = {}             -- [colour index] = flat 54 bytes, or false

local function material_colour(m)
    local idx
    pcall(function() idx = m.state_color.Solid end)
    if not idx or idx < 0 then return nil end
    local ci
    pcall(function()
        local p = df.global.world.raws.descriptors.patterns[idx]
        if p and #p.colors > 0 then ci = p.colors[0] end
    end)
    return ci
end

local function palette_of(ci)
    local pal = palettes[ci]
    if pal ~= nil then return pal end
    pal = false
    pcall(function()
        local bytes = df.global.world.raws.descriptors.colors[ci].palette.color
        local t, any = {}, false
        for i = 0, 53 do
            t[i + 1] = bytes[i]
            if bytes[i] > 0 then any = true end
        end
        -- A colour with every byte zero has no palette row: nothing to tint with.
        if any then pal = t end
    end)
    palettes[ci] = pal
    return pal
end

-- SOIL ON A ROCK LAYER. A soil tile reads its material from its geological
-- layer, but the layer boundary steps between columns, so a soil floor can sit
-- in a column whose layer at that z is rock: measured 2026-11-22, a SoilFloor
-- at (109,122,84) whose layer is siltstone, beside one in fire clay, both
-- named "fire clay" by DF on hover. tile-material then returns the rock and
-- the floor took siltstone's ecru. DF's own answer is the soil layer: the
-- deepest soil layer above that rock in the same biome's list.
local function soil_above_rock(x, y, z)
    local rx, ry = dfhack.maps.getTileBiomeRgn(x, y, z)
    local region = dfhack.maps.getRegionBiome(rx, ry)
    local biome = region and df.world_geo_biome.find(region.geo_index)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not biome or not block then return nil end
    local index = block.designation[x % 16][y % 16].geolayer_index
    for i = math.min(index, #biome.layers) - 1, 0, -1 do
        local inorganic = df.inorganic_raw.find(biome.layers[i].mat_index)
        if inorganic and inorganic.flags.SOIL_ANY then
            return dfhack.matinfo.decode(0, biome.layers[i].mat_index)
        end
    end
    return nil
end

-- The colour code for a tile: its colour index + 1, or 0 for none.
local function colour_code(x, y, z)
    local ok, matinfo = pcall(tile_material.GetTileMat, x, y, z)
    if not ok or not matinfo then
        local ok2, fallback = pcall(tile_material.GetLayerMat, x, y, z)
        matinfo = ok2 and fallback or nil
    end
    local material
    -- GetTileMat returns a plain list of materials for some plant tiles;
    -- those have no single colour.
    pcall(function()
        material = matinfo.material
        local tt = dfhack.maps.getTileType(x, y, z)
        if tt and df.tiletype.attrs[tt].material == df.tiletype_material.SOIL
                and matinfo.inorganic and not matinfo.inorganic.flags.SOIL_ANY then
            local soil = soil_above_rock(x, y, z)
            if soil then material = soil.material end
        end
    end)
    local ci = material and material_colour(material)
    return ci and ci + 1 or 0
end

-- Sand is soil to the map, but DF draws it with art of its own (sand floors,
-- stairs and ramps), so it keeps that look.
local function is_sand(x, y, z)
    local sand = false
    pcall(function()
        local matinfo = tile_material.GetTileMat(x, y, z)
        sand = matinfo and matinfo.inorganic and matinfo.inorganic.flags.SOIL_SAND or false
    end)
    return sand
end

-- ==========================================
-- THE TINT
-- ==========================================
-- The maths the old sheets were baked with, measured off them: each pixel
-- moves toward the material's palette colour in its key column by the
-- strength, rounded halves to even.
--     out = round(pixel + strength * (palette[key] - pixel))
-- Doubles in the same order as the Python that made the sheets, so a colour
-- whose row the sheets got right comes out bit for bit the same.
local function rint(v)
    local f = math.floor(v)
    local d = v - f
    if d > 0.5 then return f + 1 end
    if d < 0.5 then return f end
    return (f % 2 == 0) and f or f + 1
end

-- ALPHABET character -> its 0-based place; a cell names each pixel with two.
local DIGIT = {}
if art then
    for i = 1, #art.ALPHABET do DIGIT[art.ALPHABET:byte(i)] = i - 1 end
end
local decoded = {}              -- cell name -> 1024 PIXELS indices

local function decode(cell)
    local idx = decoded[cell]
    if idx then return idx end
    if art and art.INDEX then return art.INDEX[cell] end
    local s = art and art.CELLS[cell]
    if not s then return nil end
    idx = {}
    for i = 1, CELL_PX * CELL_PX do
        idx[i] = DIGIT[s:byte(2 * i - 1)] * 64 + DIGIT[s:byte(2 * i)] + 1
    end
    decoded[cell] = idx
    return idx
end

-- Every entry of art.PIXELS tinted toward one palette at one strength, packed
-- for createTileset. The art has a few hundred distinct pixels shared by every
-- cell, so a colour's entries are worked out once and each of its cells is then
-- 1024 lookups rather than 1024 blends. Packing is ABGR,
-- (a << 24) | (b << 16) | (g << 8) | r, confirmed in Refinish Metal by a test
-- card: the obvious 0xRRGGBBAA renders as ghostly negatives because alpha ends
-- up tracking red.
--
-- THE BLEND (2026-11-07). The legacy blend above, used alone, also pulls every
-- pixel's brightness toward the palette's, which flattens art with a wide
-- brightness range: Detailed Landscapes' and Rounded Hills' floors lost their
-- shape and read as noise. The default blend keeps the legacy blend's colour
-- but puts back each pixel's own brightness (Rec.601), then moves the whole
-- sprite by the one brightness change the legacy blend made on average over
-- that sprite's opaque pixels. So jet still comes out dark and marble light,
-- and the light/dark shapes of the art are kept exactly:
--     out = legacy + (L(pixel) - L(legacy)) - mean over the sprite of the same
-- `stone-tint blend legacy` brings
-- back the old look; the setting is saved with the fort.
local LR, LG, LB = 0.299, 0.587, 0.114

local function tinted_entries(pal, strength, blend)
    local s = strength / 100.0
    if blend == 'legacy' then
        local out = {}
        for i, e in ipairs(art.PIXELS) do
            local a = e[4]
            if a == 0 then
                out[i] = 0
            else
                local k = e[5] * 3
                local r = rint(e[1] + s * (pal[k + 1] - e[1]))
                local g = rint(e[2] + s * (pal[k + 2] - e[2]))
                local b = rint(e[3] + s * (pal[k + 3] - e[3]))
                out[i] = (a << 24) | (b << 16) | (g << 8) | r
            end
        end
        return {packed=out}
    end
    -- Unrounded legacy colour per entry, and D = how much brightness the
    -- legacy blend took away from it; cell_pixels applies the sprite's mean.
    local R, G, B, A, D = {}, {}, {}, {}, {}
    for i, e in ipairs(art.PIXELS) do
        local a = e[4]
        A[i] = a
        if a ~= 0 then
            local k = e[5] * 3
            local r = e[1] + s * (pal[k + 1] - e[1])
            local g = e[2] + s * (pal[k + 2] - e[2])
            local b = e[3] + s * (pal[k + 3] - e[3])
            R[i], G[i], B[i] = r, g, b
            D[i] = (e[1] * LR + e[2] * LG + e[3] * LB) - (r * LR + g * LG + b * LB)
        end
    end
    return {R=R, G=G, B=B, A=A, D=D}
end

local function channel(v)
    v = rint(v)
    if v < 0 then return 0 elseif v > 255 then return 255 end
    return v
end

local function cell_pixels(cell, entries)
    local idx = decode(cell)
    if not idx then return nil end
    local out = {}
    local n = CELL_PX * CELL_PX
    local packed = entries.packed
    if packed then
        for i = 1, n do out[i] = packed[idx[i]] end
        return out
    end
    local R, G, B, A, D = entries.R, entries.G, entries.B, entries.A, entries.D
    local sum, count = 0, 0
    for i = 1, n do
        local j = idx[i]
        if A[j] ~= 0 then sum = sum + D[j] count = count + 1 end
    end
    local m = count > 0 and sum / count or 0
    for i = 1, n do
        local j = idx[i]
        local a = A[j]
        if a == 0 then
            out[i] = 0
        else
            local d = D[j] - m
            out[i] = (a << 24) | (channel(B[j] + d) << 16) | (channel(G[j] + d) << 8)
                | channel(R[j] + d)
        end
    end
    return out
end

-- One cell tinted with a palette (54 bytes, 1-based) at a strength. Module-level
-- so a test can call it; the overlay goes through colour_entries' cache instead.
function tint_pixels(cell, pal, strength, blend)
    return cell_pixels(cell, tinted_entries(pal, strength, blend))
end

-- [colour index] = tinted_entries for the strength in use, or false when the
-- colour has no palette. Emptied with tint_cache when the strength changes.
local entry_cache = {}

local function colour_entries(ci, strength)
    local entries = entry_cache[ci]
    if entries == nil then
        local pal = palette_of(ci)
        entries = pal and tinted_entries(pal, strength, state.blend) or false
        entry_cache[ci] = entries
    end
    return entries
end

-- A new texture for one cell in one colour. Dynamic range: there will be
-- hundreds, too many for the reserved range, and DFHack gives each a handle
-- that survives DF wiping its textures. Never deleted: deleting texture handles
-- on the way out of a world took DF down in Refinish Metal (measured twice), so
-- they are kept for the session and reused by every later request.
local function make_texture(cell, entries)
    local pixels = cell_pixels(cell, entries)
    if not pixels then return false end
    local ok, handles = pcall(dfhack.textures.createTileset, pixels, CELL_PX, CELL_PX,
        CELL_PX, CELL_PX)
    if ok and handles and handles[1] then return handles[1] end
    return false
end

-- The texpos for one colour and art id at a strength, making the texture if
-- this is its first request. Returns texpos, false (nothing to draw), or nil
-- (not this frame: out of budget, or DF still loading), plus the budget left.
local function tint_texpos(key, ci, id, strength, budget)
    local skey = state.blend == 'legacy' and (strength .. ' legacy') or strength
    local store = stone_tint_textures[skey]
    if not store then store = {} stone_tint_textures[skey] = store end
    local handle = store[key]
    if handle == nil then
        if budget <= 0 then return nil, budget end
        budget = budget - 1
        local entries = colour_entries(ci, strength)
        handle = entries and make_texture(ART_CELL[id], entries) or false
        store[key] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then return false, budget end
    local t = dfhack.textures.getTexposByHandle(handle)
    -- 0 means DFHack is holding the texture until DF finishes loading.
    if t and t > 0 then return t, budget end
    return nil, budget
end

-- src laid over dst, both packed ABGR, in place in dst.
local function lay_over(dst, src)
    for i = 1, #dst do
        local sp = src[i]
        local sa = (sp >> 24) & 0xFF
        if sa == 255 then
            dst[i] = sp
        elseif sa > 0 then
            local dp = dst[i]
            local keep = ((dp >> 24) & 0xFF) * (255 - sa) / 255
            local oa = sa + keep
            local out = rint(oa) << 24
            for shift = 0, 16, 8 do
                out = out | (rint((((sp >> shift) & 0xFF) * sa
                    + ((dp >> shift) & 0xFF) * keep) / oa) << shift)
            end
            dst[i] = out
        end
    end
end

-- ==========================================
-- SPATTER ART
-- ==========================================
-- The picture DF puts in a cell's spatter layer (snow, mud, blood, fallen
-- leaves, fruit, whatever a mod adds), read straight out of DF's own texture:
-- enabler.textures.raws[texpos] is an SDL_Surface, and for these it is 32x32
-- ABGR8888, the same packing as cell_pixels. Measured 2026-11-22: 60 snow,
-- mud and blood pictures read this way matched their PNG cells exactly, and
-- leaves and fruit, which come from no [TILE_GRAPHICS] cell, read the same way.
-- Cached by texpos; DF renumbers texposes when it resets its textures, so the
-- cache and the composites' names follow spatter_gen (see sentinel_texpos).
local SDL_ABGR8888 = 0x16762004
local spatter_cells = {}      -- [texpos] = packed pixels, or false
local spatter_gen = 0

local function read_surface(texpos)
    local raws = df.global.enabler.textures.raws
    if texpos < 0 or texpos >= #raws then return false end
    local surface = raws[texpos]
    if not surface then return false end
    local _, s = df.sizeof(df.reinterpret_cast('uint32_t', surface))
    if not s or s == 0 then return false end
    local function i32(a) return df.reinterpret_cast('int32_t', a).value end
    local function u64(a) return df.reinterpret_cast('uint64_t', a).value end
    local w, h, pitch = i32(s + 16), i32(s + 20), i32(s + 24)
    local format, pixels = u64(s + 8), u64(s + 32)
    if w ~= CELL_PX or h ~= CELL_PX or pitch < CELL_PX * 4 or format == 0 or pixels == 0 then
        return false
    end
    if df.reinterpret_cast('uint32_t', format).value ~= SDL_ABGR8888 then return false end
    local out, i = {}, 0
    for y = 0, CELL_PX - 1 do
        local row = pixels + y * pitch
        for x = 0, CELL_PX - 1 do
            local px = df.reinterpret_cast('uint32_t', row + x * 4).value
            i = i + 1
            out[i] = (px >> 24) == 0 and 0 or px
        end
    end
    return out
end

local function spatter_pixels(texpos)
    local px = spatter_cells[texpos]
    if px == nil then
        local ok, got = pcall(read_surface, texpos)
        px = ok and got or false
        spatter_cells[texpos] = px
    end
    return px
end

-- The texpos for several edge pieces at once: keys are tint keys
-- (code * ART_COUNT + id), in EDGE_SIDES order; sp, if given, is the texpos of
-- a spatter picture that goes on top (SPATTER ART); floor, if given, is the tint
-- key of the cell's own floor, drawn first (EDGES UNDER DF'S EDGES). Returns as
-- tint_texpos does.
local function edges_texpos(keys, n, strength, budget, sp, floor)
    local skey = state.blend == 'legacy' and (strength .. ' legacy') or strength
    local store = stone_tint_textures[skey]
    if not store then store = {} stone_tint_textures[skey] = store end
    local name = 'edges ' .. table.concat(keys, ' ', 1, n)
    if sp then name = name .. ' s' .. sp .. '/' .. spatter_gen end
    if floor then name = 'f' .. floor .. ' ' .. name end
    local handle = store[name]
    if handle == nil then
        if budget <= 0 then return nil, budget end
        budget = budget - 1
        local pixels
        if floor then
            local id = (floor - 1) % ART_COUNT + 1
            local entries = colour_entries((floor - id) // ART_COUNT - 1, strength)
            pixels = entries and cell_pixels(ART_CELL[id], entries)
            if not pixels then n = 0 end
        end
        for i = 1, n do
            local key = keys[i]
            local id = (key - 1) % ART_COUNT + 1
            local code = (key - id) // ART_COUNT
            local entries = colour_entries(code - 1, strength)
            local px = entries and cell_pixels(ART_CELL[id], entries)
            if px then
                if pixels then lay_over(pixels, px) else pixels = px end
            end
        end
        if pixels and sp then
            local spx = spatter_pixels(sp)
            if spx then lay_over(pixels, spx) else pixels = nil end
        end
        handle = false
        if pixels then
            local ok, handles = pcall(dfhack.textures.createTileset, pixels, CELL_PX, CELL_PX,
                CELL_PX, CELL_PX)
            if ok and handles and handles[1] then handle = handles[1] end
        end
        store[name] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then return false, budget end
    local t = dfhack.textures.getTexposByHandle(handle)
    if t and t > 0 then return t, budget end
    return nil, budget
end

-- One transparent texture whose texpos is watched every frame: if it moves, DF
-- reset its textures and every texpos stone-tint holds is stale. Made on first
-- need, on a loaded map, and kept with the other textures.
local function sentinel_texpos()
    if stone_tint_sentinel == nil then
        local blank = {}
        for i = 1, CELL_PX * CELL_PX do blank[i] = 0 end
        local ok, handles = pcall(dfhack.textures.createTileset, blank, CELL_PX, CELL_PX,
            CELL_PX, CELL_PX)
        stone_tint_sentinel = ok and handles and handles[1] or false
    end
    if not stone_tint_sentinel then return nil end
    return dfhack.textures.getTexposByHandle(stone_tint_sentinel)
end

-- ==========================================
-- RAMP OVERLAYS
-- ==========================================
-- DF draws a ramp overlay (the OVERLAY_RAMP_WITH_WALL_* tokens: vanilla's
-- RAMP_OVERLAY page, or Dark Depths' DARK_RAMP_OVERLAY) over every ramp's
-- background, picked by the same walls as the ramp. Seen in play: it covers
-- our tinted ramps. It is in no per-cell texpos layer, so it cannot be skipped
-- cell by cell. DF looks a token's texture up in its tables of token texposes,
-- gps.texture_indices1 to 11, as it draws: Making Fuel's hide sprite already
-- writes DF's ITEM_LIQUID entry there, and globs follow it live. So hiding the
-- overlay means pointing every overlay token's entry at one blank texture, and
-- showing it again means writing the old values back. The entries are found by
-- value: whichever hold a texpos off either overlay page. That is global, so
-- every ramp loses its overlay, not only the ones stone-tint draws. The shadows
-- are other tokens (SHADOWS_RAMP and SHADOWS_WALL, or Dark Depths' DARK_ ones)
-- and are left alone.
--
-- The blank is a RESERVED texture: these entries hold raw texposes, not
-- handles, and the dynamic range gets wiped and renumbered. The entries and
-- their old values live in an environment global, so a console command
-- re-running this file cannot lose what is needed to put them back.
stone_tint_overlays = stone_tint_overlays or {hidden=false}
-- Any loaded page whose token ends in RAMP_OVERLAY, rather than a fixed list of
-- two. Measured 2026-10-21: with Rounded Hills installed the overlay page is
-- RAMP_OVERLAY_ROUND, which the fixed list missed, so find_overlay_slots found
-- nothing and "Hide ramp overlays" silently did nothing at all. Vanilla's
-- RAMP_OVERLAY, Dark Depths' DARK_RAMP_OVERLAY and Rounded Hills'
-- RAMP_OVERLAY_ROUND all match this.
local function is_overlay_page(token)
    return token ~= nil and token:find('RAMP_OVERLAY') ~= nil
end
local TEXTURE_TABLES = {}
for i = 1, 11 do TEXTURE_TABLES[i] = 'texture_indices' .. i end

local function blank_reserved_texpos()
    local ov = stone_tint_overlays
    if ov.blank_handle == nil then
        local blank = {}
        for i = 1, CELL_PX * CELL_PX do blank[i] = 0 end
        local ok, handles = pcall(dfhack.textures.createTileset, blank, CELL_PX, CELL_PX,
            CELL_PX, CELL_PX, true)
        ov.blank_handle = ok and handles and handles[1] or false
    end
    if not ov.blank_handle then return nil end
    local t = dfhack.textures.getTexposByHandle(ov.blank_handle)
    return t and t > 0 and t or nil
end

-- {table name, index, old value} for every token entry holding an overlay
-- texture. One pass over the tables, about 52,000 entries, so it runs only
-- when the overlays are hidden, never per frame.
local function find_overlay_slots()
    local wanted, any = {}, false
    local pages = df.global.texture.page
    for pi = 0, #pages - 1 do
        local page = pages[pi]
        if page.loaded and is_overlay_page(page.token) then
            for j = 0, #page.texpos - 1 do
                local t = page.texpos[j]
                if t > 0 then wanted[t], any = true, true end
            end
            for j = 0, #page.texpos_gs - 1 do
                local t = page.texpos_gs[j]
                if t > 0 then wanted[t] = true end
            end
        end
    end
    local slots = {}
    if not any then return slots end
    local gps = df.global.gps
    for _, name in ipairs(TEXTURE_TABLES) do
        local ok, arr = pcall(function() return gps[name] end)
        if ok and arr then
            for i = 0, #arr - 1 do
                local v = arr[i]
                if wanted[v] then slots[#slots + 1] = {name, i, v} end
            end
        end
    end
    return slots
end

local function hide_ramp_overlays()
    local ov = stone_tint_overlays
    local blank = blank_reserved_texpos()
    if not blank then return end
    local slots = find_overlay_slots()
    local gps = df.global.gps
    for _, s in ipairs(slots) do gps[s[1]][s[2]] = blank end
    -- Marked hidden even when nothing was found, so the tables are not
    -- searched again every frame; status reports the count.
    ov.slots, ov.blank, ov.hidden = slots, blank, true
end

local function show_ramp_overlays()
    local ov = stone_tint_overlays
    if not ov.hidden then return end
    local gps = df.global.gps
    for _, s in ipairs(ov.slots or {}) do
        -- Only an entry still holding our blank: one DF has written since is its own.
        pcall(function()
            if gps[s[1]][s[2]] == ov.blank then gps[s[1]][s[2]] = s[3] end
        end)
    end
    ov.slots, ov.hidden = nil, false
end

-- Keep the overlays the way the settings ask: hidden while ramps are tinted
-- and "Hide ramp overlays" is on, back otherwise. While hidden, one entry is
-- read each frame: DF rebuilding its tables (a graphics reload) writes all of
-- them back with new values, and then they are found and hidden again rather
-- than "restored" to values that no longer mean anything.
function update_ramp_overlays()
    local ov = stone_tint_overlays
    local want = art ~= nil and state.strength > 0 and state.ramps and state.hide_overlays
    if ov.hidden then
        if not want then
            show_ramp_overlays()
        elseif ov.slots and ov.slots[1] then
            local s = ov.slots[1]
            local ok, v = pcall(function() return df.global.gps[s[1]][s[2]] end)
            if not ok or v ~= ov.blank then ov.slots, ov.hidden = nil, false end
        end
    end
    if want and not ov.hidden then hide_ramp_overlays() end
end

-- ==========================================
-- WHAT A TILE IS
-- ==========================================
-- The art id for a revealed natural stair or ramp of stone or soil (sand
-- excepted), or false for any other tile. flag is the tile's
-- screentexpos_ramp_flag, which picks a ramp's cell. Map reads, so the render
-- loop calls it only for a texture it has not seen since the last reset and
-- for a stair or ramp tile it has not checked, never per cell per frame.
local function natural_art(x, y, z, flag)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local attrs = df.tiletype.attrs[tt]
    local family
    if STONE_MATERIALS[attrs.material] then
        family = 'stone'
    elseif attrs.material == df.tiletype_material.SOIL then
        family = 'soil'
    else
        return false
    end
    local id
    local shape = STAIR_SHAPES[attrs.shape]
    if shape then
        id = STAIR_ART[family][shape]
    elseif attrs.shape == df.tiletype_shape.RAMP and art then
        local bits = flag and math.tointeger(flag)
        local cell = bits and art.RAMP_CELL[(bits >> 8) & 0xFF]
        id = cell and RAMP_ART[family][cell]
    end
    if not id then return false end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if des and des.hidden then return false end
    if family == 'soil' and is_sand(x, y, z) then return false end
    return id
end

-- Whether a tile DF drew its engraved floor picture on is one stone-tint draws:
-- a revealed natural stone floor. ENGRAVED or false. Map reads, so the render
-- loop calls it once per tile, kept against the texture like a learned stair
-- (paint_cell).
local function natural_engraved(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local attrs = df.tiletype.attrs[tt]
    if not STONE_MATERIALS[attrs.material] or attrs.shape ~= df.tiletype_shape.FLOOR then
        return false
    end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if des and des.hidden then return false end
    return ENGRAVED
end

-- ==========================================
-- FLOOR EDGES
-- ==========================================
-- A rough floor spills over onto a neighbouring floor of lower rank (onto a
-- smooth floor, say): the scalloped bits of the art's 3x3 block around the
-- floor cell (STONE_FLOOR_2, 4, 6 and 8 are its top, left, right and bottom
-- edges). DF does not put those in the background: it keeps one byte per side
-- in screentexpos_floor_flag (s, w, e and n_edging, as devel/inspect-screen
-- decodes it; measured 2026-11-07, every nonzero byte faced a floor that
-- spills) and draws the neighbour's edge piece from it afterwards, in DF's own
-- untinted art, which shows as grey seams beside tinted floors.
--
-- On any receiving tile, each side whose neighbour is a rough floor Stone Tint
-- tints has its byte cleared and the piece drawn in the neighbour's tint
-- instead, through screentexpos_background_two, which DF leaves empty on
-- floors and draws over the background. Two or more sides make one texture
-- of the pieces laid over each other. A side whose neighbour is anything else
-- (grass, sand, a constructed floor) keeps DF's edge. Corners: DF keeps no
-- byte for them, and neither does this.
-- {shift of the side's byte, dx, dy, the neighbour's piece (FLOOR_SUFFIXES index)}
local EDGE_SIDES = {
    {0, 0, 1, 2},       -- s_edging: the tile to the south, its top edge
    {8, -1, 0, 6},      -- w_edging: the tile to the west, its right edge
    {16, 1, 0, 4},      -- e_edging: the tile to the east, its left edge
    {24, 0, -1, 8},     -- n_edging: the tile to the north, its bottom edge
}
local ROUGH_SPECIALS = {
    [df.tiletype_special.NORMAL] = true,
    [df.tiletype_special.WET] = true,
}

-- The first art id of the family (1 for stone, FIRST_SOIL_FLOOR for soil) of a
-- revealed natural rough floor, or false. Map reads, once per tile per level.
local function edge_source(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local attrs = df.tiletype.attrs[tt]
    if attrs.shape ~= df.tiletype_shape.FLOOR or not ROUGH_SPECIALS[attrs.special] then
        return false
    end
    local base
    if STONE_MATERIALS[attrs.material] then
        base = 1
    elseif attrs.material == df.tiletype_material.SOIL then
        base = FIRST_SOIL_FLOOR
    else
        return false
    end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if des and des.hidden then return false end
    if base ~= 1 and is_sand(x, y, z) then return false end
    return base
end

-- ==========================================
-- SETTINGS AND CACHES
-- ==========================================
local function load_state()
    if not dfhack.isMapLoaded() then return end
    local saved = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    if tonumber(saved.strength) then state.strength = tonumber(saved.strength) end
    for _, k in ipairs({'rough', 'smooth', 'stairs', 'ramps', 'soil', 'hide_overlays',
                        'engraved', 'faces', 'blend', 'edges'}) do
        if saved[k] ~= nil then state[k] = saved[k] end
    end
end

local function save_state()
    if dfhack.isMapLoaded() then dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
end

-- Forget every learned texture; keep only the floor sprites.
local function reset_known()
    known_texpos = {}
    for texpos, id in pairs(floor_texpos) do known_texpos[texpos] = id end
end

local function reset_cache(z)
    cached_z = z
    color_cache = {}
    tile_checks = {}
    edge_cache = {}
    reset_known()
end

-- One level's colour and tile check tables, made on first need.
local function level_caches(z)
    local colours = color_cache[z]
    if not colours then colours = {} color_cache[z] = colours end
    local checks = tile_checks[z]
    if not checks then checks = {} tile_checks[z] = checks end
    return colours, checks
end

local function refresh_map_bounds()
    if not dfhack.isMapLoaded() then
        map_max_x, map_max_y = nil, nil
        return
    end
    local ok, x, y = pcall(dfhack.maps.getTileSize)
    if ok then map_max_x, map_max_y = x, y end
end

-- Repaint immediately after a settings change rather than waiting for DF to
-- decide the screen is stale.
local function force_repaint()
    df.global.gps.force_full_display_count = 1
end

local function set_strength(strength)
    state.strength = strength
    save_state()
    update_ramp_overlays()
    force_repaint()
    return true
end

-- ==========================================
-- LIVE ART
-- ==========================================
-- Graphics mods re-point the floor, stair and ramp tokens at pages of their
-- own: Rounded Hills draws STONE_FLOOR_1 from FLOORS_ROUND and the ramps from
-- STONE_RAMPS_ROUND, Detailed Landscapes from FLOORS_ROUND_DETAILED and
-- STONE_RAMPS_ROUND_DETAILED. With vanilla's pages hardcoded, such a mod's
-- floors were never recognised (no tint) and its ramps, once tinted, came back
-- square: the art drawn over them was vanilla's.
--
-- So on map load the world's own raws are read in load order (later mods
-- win, as DF does), each token's page and cell is found, and when any of them
-- is not vanilla's, that page's image is read off disk and keyed the same way
-- the baked art is (liveart.lua). Over vanilla's own pages this reproduces
-- art-vanilla.lua pixel for pixel (test_liveart.py, 2026-11-07), so the tint
-- is the same maths on whatever art the player actually has. Nothing is
-- copied from another mod into this one. Anything that cannot be read keeps
-- vanilla's art, so the worst case is the old behaviour.
--
-- Floor tokens, in art id order (ids 1 to 25).
local LIVE_FLOOR_TOKENS = {}
for _, n in ipairs(FLOOR_SUFFIXES) do LIVE_FLOOR_TOKENS[#LIVE_FLOOR_TOKENS + 1] = 'STONE_FLOOR_' .. n:upper() end
LIVE_FLOOR_TOKENS[#LIVE_FLOOR_TOKENS + 1] = 'SMOOTH_FLOOR'
for _, n in ipairs(FLOOR_SUFFIXES) do LIVE_FLOOR_TOKENS[#LIVE_FLOOR_TOKENS + 1] = 'DIRT_FLOOR_' .. n:upper() end

-- {page, x, y, art id} for every floor token, wherever the raws put it.
local live_floor_specs = {}
-- {page, x, y} for the engraved floor tokens, wherever the raws put them: an
-- engraving mod moves them to pages of its own (Sumptuously Engraved Floors:
-- FLOOR_STONE_ENGRAVED_NON_PALETTE_CLEAN), which ENGRAVED_PAGES never names.
local live_engraved_specs = {}
-- For `stone-tint status`.
local art_report = {source='vanilla'}

-- The world's object folders in load order, as paths that exist. DF lists
-- them relative to where it keeps them, which on a Steam install is the game
-- folder for vanilla and the user folder (%APPDATA%\Bay 12 Games\Dwarf
-- Fortress) for installed mods; try both, and the path as given.
local function object_dirs()
    local roots = {dfhack.filesystem.getBaseDir()}
    local ok, user = pcall(function() return dfhack.filesystem.getUserDir() end)
    if ok and type(user) == 'string' then roots[#roots + 1] = user end
    local appdata = os.getenv('APPDATA')
    if appdata then roots[#roots + 1] = appdata .. '/Bay 12 Games/Dwarf Fortress/' end
    roots[#roots + 1] = ''
    local dirs, missing, missing_names = {}, 0, nil
    for _, p in ipairs(df.global.world.object_loader.object_load_order_src_dir) do
        if type(p) ~= 'string' then p = p.value end
        local found
        for _, root in ipairs(roots) do
            local sep = (root == '' or root:match('[/\\]$')) and '' or '/'
            local cand = root .. sep .. p
            if dfhack.filesystem.isdir(cand) then found = cand break end
        end
        if found then dirs[#dirs + 1] = found else missing = missing + 1 end
        if not found then missing_names = (missing_names or '') .. ' ' .. p end
    end
    return dirs, missing, missing_names
end

-- Kept across console runs of this file (they re-execute it), keyed by the
-- load order, so the pages are read once per world rather than per command.
stone_tint_live = stone_tint_live or nil

local function use_art(new_art, specs, report, engraved_specs)
    art, live_floor_specs, art_report = new_art, specs, report
    live_engraved_specs = engraved_specs or {}
    decoded = {}
    entry_cache = {}
    tint_cache = {}
    local sig = report.sig or 'vanilla'
    if stone_tint_textures.art_sig ~= sig then
        stone_tint_textures = {art_count=ART_COUNT, art_sig=sig}
    end
end

local function rebuild_art()
    if not vanilla_art then return end
    if not (ok_live and ok_raws and ok_decode) then
        use_art(vanilla_art, {}, {source='vanilla', error='live art modules did not load'})
        return
    end
    if not dfhack.isWorldLoaded() then return end
    local ok, err = pcall(function()
        local dirs, missing, missing_names = object_dirs()
        local sig = table.concat(dirs, '|')
        local live = stone_tint_live
        if not live or live.sig ~= sig then
            local resolved = graphicsraws.resolve(dirs, graphicsraws.default_fs())
            local mod_dirs = {}
            for _, d in ipairs(dirs) do
                local norm = d:gsub('\\', '/'):lower()
                if not norm:find('/data/vanilla/', 1, true) and norm:sub(1, 13) ~= 'data/vanilla/' then
                    mod_dirs[#mod_dirs + 1] = d
                end
            end
            local specs = {}
            for id, token in ipairs(LIVE_FLOOR_TOKENS) do
                local t = resolved.tokens[token]
                if t then specs[#specs + 1] = {t.page, t.x, t.y, id} end
            end
            local engraved_specs = {}
            for _, spec in ipairs(ENGRAVED_PAGES) do
                local t = resolved.tokens[spec[1]]
                if t then engraved_specs[#engraved_specs + 1] = {t.page, t.x, t.y} end
            end
            local built, info = liveart.build(resolved, vanilla_art, imagedecode)
            local pages = {}
            for page in pairs(info.pages) do pages[#pages + 1] = page end
            table.sort(pages)
            local is_live = built ~= vanilla_art
            live = {sig=sig, art=built, specs=specs, engraved_specs=engraved_specs, report={
                source=is_live and 'live' or 'vanilla', sig=is_live and sig or 'vanilla',
                dirs=#dirs, missing=missing, missing_names=missing_names, mod_dirs=mod_dirs, live=info.live, fallback=info.fallback,
                conflicts=info.conflicts, errors=info.errors, pages=pages}}
            stone_tint_live = live
        end
        use_art(live.art, live.specs, live.report, live.engraved_specs)
    end)
    if not ok then
        use_art(vanilla_art, {}, {source='vanilla', error=tostring(err)})
        dfhack.printerr('stone-tint: could not read the loaded graphics, using vanilla art: ' .. tostring(err))
    end
end

-- Only the pristine floor texposes need rediscovering; they move when the game
-- reloads graphics. Cheap: at most 39 findGraphicsTile calls. Learned
-- textures are dropped only when a floor texpos actually moved (or force), so
-- the periodic refresh does not throw away what the loop has learned.
local function refresh_texpos_maps(force)
    local fresh = {}
    local function add(list, first_id)
        for i, spec in ipairs(list) do
            local texpos = dfhack.screen.findGraphicsTile(spec[1], spec[2], spec[3])
            if texpos and texpos >= 0 then fresh[texpos] = first_id + i - 1 end
        end
    end
    add(VARIANTS, 1)
    -- Also recognize vanilla rough-floor pages. This lets the same script run
    -- standalone or alongside Detailed Landscapes.
    add(VANILLA_VARIANTS, 1)
    add(SOIL_VARIANTS, FIRST_SOIL_FLOOR)
    -- Wherever the loaded raws really put them (LIVE ART).
    for _, spec in ipairs(live_floor_specs) do
        local texpos = dfhack.screen.findGraphicsTile(spec[1], spec[2], spec[3])
        if texpos and texpos >= 0 then fresh[texpos] = spec[4] end
    end
    -- Engraved floors file as ENGRAVED, not an art id (ENGRAVED FLOORS).
    -- ENGRAVED_PAGES by vanilla's page names, then wherever the loaded raws
    -- put the tokens (LIVE ART), counting each texpos once.
    engraved_found = 0
    local function add_engraved(list)
        for _, spec in ipairs(list) do
            local texpos = dfhack.screen.findGraphicsTile(spec[1], spec[2], spec[3])
            if texpos and texpos >= 0 and fresh[texpos] ~= ENGRAVED then
                fresh[texpos] = ENGRAVED
                engraved_found = engraved_found + 1
            end
        end
    end
    add_engraved(ENGRAVED_PAGES)
    add_engraved(live_engraved_specs)
    local changed = force
    for texpos, id in pairs(fresh) do
        if floor_texpos[texpos] ~= id then changed = true end
    end
    for texpos in pairs(floor_texpos) do
        if fresh[texpos] == nil then changed = true end
    end
    floor_texpos = fresh
    if changed then reset_known() end
end

-- ==========================================
-- THE OVERLAY
-- ==========================================
StoneTintOverlay = defclass(StoneTintOverlay, overlay.OverlayWidget)
StoneTintOverlay.ATTRS{
    desc='Tint natural stone and soil floors, engraved floors, stairs and ramps by their material.',
    viewscreens='dwarfmode',
    default_enabled=true,
}

function StoneTintOverlay:init()
    load_state()
    refresh_texpos_maps(true)
    refresh_map_bounds()
    reset_cache(nil)
end

-- Per-frame values paint_cell reads, set at the top of each frame.
-- frame_engraved is the art id an engraved floor gets this frame.
local frame_strength, frame_budget, frame_engraved = 0, 0, ENGRAVED_FACE
-- The tint key paint_cell wrote for the cell being visited, or nil. The render
-- loops clear it before each cell, so paint_edges reads only its own cell's.
local cell_key

-- One cell DF drew with a texture that may be ours (its known_texpos entry is
-- not false): works out which art it is, if any, and writes the tinted texture
-- over DF's. bg and flags are the arrays of the viewport the cell is in, z its
-- level, colours and checks that level's caches. Returns the kind of tile it
-- tinted, for the counts, or nil. One function for the level you are on and
-- the levels below, so both tint the same way.
local function paint_cell(bg, flags, index, drawn, wx, wy, z, colours, checks)
    local id = known_texpos[drawn]
    if id == nil then
        -- First sight of this texture since the last reset. One map read
        -- files it for every cell after this.
        id = natural_art(wx, wy, z, flags[index]) and LEARNED or false
        known_texpos[drawn] = id
    end
    if id == LEARNED then
        -- A texture DF drew on a natural stair or ramp. Which shape this tile
        -- is, and for a ramp which walls it meets, is read once and kept
        -- against the texture, so a changed tile is read again.
        local ccol = checks[wx]
        if not ccol then ccol = {} checks[wx] = ccol end
        local check = ccol[wy]
        if not check or check.texpos ~= drawn then
            check = {texpos=drawn, id=natural_art(wx, wy, z, flags[index])}
            ccol[wy] = check
        end
        id = check.id
    elseif id == ENGRAVED then
        -- DF's engraved floor picture (ENGRAVED FLOORS). Whether this tile is
        -- natural stone is read once and kept against the texture, as above;
        -- which picture it gets is the "Engraving faces" switch.
        local ccol = checks[wx]
        if not ccol then ccol = {} checks[wx] = ccol end
        local check = ccol[wy]
        if not check or check.texpos ~= drawn then
            check = {texpos=drawn, id=natural_engraved(wx, wy, z)}
            ccol[wy] = check
        end
        id = check.id and frame_engraved
    end
    if not id or not group_enabled[ART_GROUP[id]] then return nil end
    local col = colours[wx]
    if not col then col = {} colours[wx] = col end
    local code = col[wy]
    if not code then
        code = colour_code(wx, wy, z)
        col[wy] = code
    end
    if code == 0 then return nil end
    local key = code * ART_COUNT + id
    local texpos = tint_cache[key]
    if texpos == nil then
        texpos, frame_budget = tint_texpos(key, code - 1, id, frame_strength, frame_budget)
        -- nil: not this frame, so not cached; asked again next frame
        if texpos ~= nil then tint_cache[key] = texpos end
    end
    if not texpos then return nil end
    bg[index] = texpos
    cell_key = key
    return ART_KIND[id]
end

-- The edges spilling onto any visible cell (FLOOR EDGES). The receiving
-- terrain need not have tintable art. Returns how many sides it drew.
--
-- SPATTER ON TOP. DF draws its own edges before spatter (snow, mud, blood),
-- so spatter covers them; background_two, where the tinted edge goes, is drawn
-- after spatter, which put tinted edges on top of snow (reported 2026-11-22).
-- So on a cell with spatter the texture made is the tinted edge with that
-- cell's spatter picture laid over it (SPATTER ART), one picture in the layer
-- this already uses. DF draws the same spatter underneath, so the cell looks
-- as it would with DF's own edge, tinted. A spatter picture that cannot be
-- read leaves the cell to DF: its own edge, under the spatter, untinted.
--
-- EDGES UNDER DF'S EDGES. A cell can also keep an edge DF draws itself, from a
-- neighbour Stone Tint does not tint (grass, most often). DF draws those after
-- the floor and before spatter, so a tinted edge in background_two lands on
-- top of them: a dirt edge over the grass spilling onto the same tile
-- (reported 2026-11-22). When the cell's own floor is one paint_cell just
-- tinted, the tinted edges go into that floor's picture instead, so DF's edges
-- and then the spatter are drawn over them in DF's own order. A cell whose
-- floor is not tinted (constructed, sand, a switched-off kind) keeps the
-- background_two picture.
--
-- EDGE MODES (the window's "Edges" setting): 'smart' is all of the above;
-- 'simple' is 1.2.1's way, every tinted edge in background_two, over whatever
-- DF draws; 'off' leaves every edge to DF, untinted.
local edge_keys = {}
local function paint_edges(floor_flags, bg2, index, wx, wy, z, colours, spatter, bg)
    local mode = state.edges
    if mode == 'off' then return 0 end
    local f = floor_flags[index]
    if f == 0 then return 0 end
    f = math.tointeger(f)
    if not f or (f & 0xFFFFFFFF) == 0 or bg2[index] ~= 0 then return 0 end
    local smart = mode ~= 'simple'
    local sp = smart and spatter and spatter[index] or 0
    if sp == 0 then sp = nil end
    local edges = edge_cache[z]
    if not edges then edges = {} edge_cache[z] = edges end
    local n, clear = 0, 0
    for _, side in ipairs(EDGE_SIDES) do
        local shift = side[1]
        if (f >> shift) & 0xFF ~= 0 then
            local nx, ny = wx + side[2], wy + side[3]
            if nx >= 0 and ny >= 0 and nx < map_max_x and ny < map_max_y then
                local ecol = edges[nx]
                if not ecol then ecol = {} edges[nx] = ecol end
                local base = ecol[ny]
                if base == nil then
                    base = edge_source(nx, ny, z)
                    ecol[ny] = base
                end
                if base and group_enabled[ART_GROUP[base]] then
                    local col = colours[nx]
                    if not col then col = {} colours[nx] = col end
                    local code = col[ny]
                    if not code then
                        code = colour_code(nx, ny, z)
                        col[ny] = code
                    end
                    if code ~= 0 then
                        n = n + 1
                        edge_keys[n] = code * ART_COUNT + base + side[4] - 1
                        clear = clear | (0xFF << shift)
                    end
                end
            end
        end
    end
    if n == 0 then return 0 end
    local floor_key = smart and cell_key
    if floor_key and bg and ((f & ~clear) & 0xFFFFFFFF) ~= 0 then
        local name = 'f' .. floor_key .. ' ' .. table.concat(edge_keys, ' ', 1, n)
        local texpos = tint_cache[name]
        if texpos == nil then
            texpos, frame_budget = edges_texpos(edge_keys, n, frame_strength, frame_budget,
                nil, floor_key)
            if texpos ~= nil then tint_cache[name] = texpos end
        end
        if not texpos then return 0 end
        floor_flags[index] = f & ~clear
        bg[index] = texpos
        return n
    end
    if sp and not spatter_pixels(sp) then return 0 end
    local texpos
    if n == 1 and not sp then
        local key = edge_keys[1]
        texpos = tint_cache[key]
        if texpos == nil then
            local id = (key - 1) % ART_COUNT + 1
            texpos, frame_budget = tint_texpos(key, (key - id) // ART_COUNT - 1, id,
                frame_strength, frame_budget)
            if texpos ~= nil then tint_cache[key] = texpos end
        end
    else
        local name = table.concat(edge_keys, ' ', 1, n)
        if sp then name = name .. ' s' .. sp end
        texpos = tint_cache[name]
        if texpos == nil then
            texpos, frame_budget = edges_texpos(edge_keys, n, frame_strength, frame_budget, sp)
            if texpos ~= nil then tint_cache[name] = texpos end
        end
    end
    if not texpos then return 0 end
    floor_flags[index] = f & ~clear
    bg2[index] = texpos
    return n
end

-- DF rebuilds screentexpos_background from scratch every rendered frame. This
-- was measured, not assumed: writing a sentinel into the buffer and reading it
-- back 1, 5 and 60 frames later found it gone every time (see probe.lua). Two
-- consequences shape this function:
--
--   * The scan cannot be skipped on quiet frames. There is no persistent state
--     to keep dirty -- skip a frame and DF's untinted floor is what shows.
--   * Nothing needs restoring. When the tint is switched off or a floor falls
--     out of scope we simply decline to write, and DF's own sprite stands.
--
-- So the work went into making each cell nearly free instead. Per cell in the
-- common case (not one of our floors, stairs or ramps, and no edging) this is
-- array reads and a hash lookup, with no allocation and no C call; an empty
-- cell also gets a note for the level below. Map reads happen only to file a texture
-- the loop has not seen since the last reset and to check a stair or ramp tile
-- once; material lookups once per tile per z-level; texture making at most
-- NEW_TEXTURES_PER_FRAME times a frame. The levels below cost nothing more
-- than the cells the level above left empty (THE LEVELS BELOW).
function StoneTintOverlay:onRenderFrame(dc, rect)
    StoneTintOverlay.super.onRenderFrame(self, dc, rect)

    if not dfhack.screen.inGraphicsMode() or not dfhack.isMapLoaded() then return end
    -- Before the strength check, so turning the tint off puts the overlays back.
    update_ramp_overlays()
    local strength = state.strength
    if strength == 0 or not art then return end

    local gps = df.global.gps
    local vp = gps.main_viewport
    if not vp then return end
    local dim_x, dim_y = vp.dim_x, vp.dim_y
    if dim_x <= 0 or dim_y <= 0 then return end

    if not map_max_x then
        refresh_map_bounds()
        if not map_max_x then return end
    end

    local z = df.global.window_z
    if z ~= cached_z then reset_cache(z) end

    -- One C call per frame instead of one per cell: if the sentinel's texpos
    -- has moved, DF reset its textures, every texpos held here is stale, and
    -- the floor sprites and learned textures have moved with it.
    local sentinel = sentinel_texpos()
    if sentinel ~= tint_sentinel then
        tint_sentinel = sentinel
        tint_cache = {}
        spatter_cells, spatter_gen = {}, spatter_gen + 1
        refresh_texpos_maps(true)
    end
    if strength ~= tint_strength then
        tint_strength = strength
        tint_cache = {}
        entry_cache = {}
    end

    -- Which groups are in scope this frame. Only cells already found to be ours
    -- ask, so the common cell never touches this.
    local enabled = group_enabled
    local soil = state.soil
    enabled[G_ROUGH], enabled[G_SMOOTH] = state.rough, state.smooth
    enabled[G_STAIRS], enabled[G_RAMPS] = state.stairs, state.ramps
    enabled[G_SOIL_FLOORS] = soil and state.rough
    enabled[G_SOIL_STAIRS] = soil and state.stairs
    enabled[G_SOIL_RAMPS] = soil and state.ramps
    enabled[G_ENGRAVED] = state.engraved
    if not (state.rough or state.smooth or state.stairs or state.ramps or state.engraved) then
        return
    end

    -- Taken after the z, sentinel and strength checks above, any of which can
    -- replace them.
    local bg = vp.screentexpos_background
    local ramp_flags = vp.screentexpos_ramp_flag
    local floor_flags, bg2 = vp.screentexpos_floor_flag, vp.screentexpos_background_two
    local spatter = vp.screentexpos_spatter
    local n_edges = 0
    local known = known_texpos
    local win_x, win_y = df.global.window_x, df.global.window_y
    local max_x, max_y = map_max_x, map_max_y
    local counts = frame_counts
    counts[K_FLOOR], counts[K_STAIR], counts[K_RAMP], counts[K_ENGRAVED] = 0, 0, 0, 0
    frame_strength, frame_budget = strength, NEW_TEXTURES_PER_FRAME
    frame_engraved = state.faces and ENGRAVED_FACE or ENGRAVED_PLAIN
    local colours, checks = level_caches(z)
    local open, n_open = see_through, 0

    -- The level you are on. index = sx * dim_y + sy, so iterating sy innermost
    -- lets it just increment.
    local index = 0
    for sx = 0, dim_x - 1 do
        local wx = win_x + sx
        if wx < 0 or wx >= max_x then
            index = index + dim_y
        else
            for sy = 0, dim_y - 1 do
                local drawn = bg[index]          -- the texpos DF drew here this frame
                if drawn == 0 then
                    -- Nothing drawn here: the level below shows through.
                    n_open = n_open + 1
                    open[n_open] = index
                end
                local wy = win_y + sy
                if wy >= 0 and wy < max_y then
                    cell_key = nil
                    if drawn ~= 0 and known[drawn] ~= false then
                        local kind = paint_cell(bg, ramp_flags, index, drawn, wx, wy, z,
                            colours, checks)
                        if kind then counts[kind] = counts[kind] + 1 end
                    end
                    n_edges = n_edges + paint_edges(floor_flags, bg2, index, wx, wy, z,
                        colours, spatter, bg)
                end
                index = index + 1
            end
        end
    end

    -- The levels below, one at a time, through the cells left empty above
    -- (see THE LEVELS BELOW). A cell empty again on this level goes on the
    -- list for the next one down.
    local below = 0
    local lower = gps.lower_viewport
    local next_open = see_next
    for i = 0, LOWER_LEVELS - 1 do
        local lz = z - i - 1
        if n_open == 0 or lz < 0 then break end
        local lvp = lower and lower[i]
        if not lvp or not lvp.flag.active or lvp.dim_x ~= dim_x or lvp.dim_y ~= dim_y then break end
        local lbg, lflags = lvp.screentexpos_background, lvp.screentexpos_ramp_flag
        local ledges, lbg2 = lvp.screentexpos_floor_flag, lvp.screentexpos_background_two
        if not lbg or not lflags then break end
        colours, checks = level_caches(lz)
        local n_next = 0
        for k = 1, n_open do
            local cell = open[k]
            local drawn = lbg[cell]
            if drawn == 0 then
                n_next = n_next + 1
                next_open[n_next] = cell
            end
            local sx = cell // dim_y
            local wy = win_y + cell - sx * dim_y
            if wy >= 0 and wy < max_y then
                cell_key = nil
                if drawn ~= 0 and known[drawn] ~= false then
                    local kind = paint_cell(lbg, lflags, cell, drawn, win_x + sx, wy, lz,
                        colours, checks)
                    if kind then
                        counts[kind] = counts[kind] + 1
                        below = below + 1
                    end
                end
                if ledges and lbg2 then
                    n_edges = n_edges + paint_edges(ledges, lbg2, cell, win_x + sx, wy, lz,
                        colours, lvp.screentexpos_spatter, lbg)
                end
            end
        end
        open, next_open, n_open = next_open, open, n_next
    end

    stone_tint_stats.floors = counts[K_FLOOR]
    stone_tint_stats.engraved = counts[K_ENGRAVED]
    stone_tint_stats.stairs = counts[K_STAIR]
    stone_tint_stats.ramps = counts[K_RAMP]
    stone_tint_stats.below = below
    stone_tint_stats.edges = n_edges
end

function StoneTintOverlay:overlay_onupdate()
    -- Graphics can be reloaded without changing texture handles. Refresh only the
    -- texpos values that identify the game's original floor sprites.
    refresh_texpos_maps(false)
end

-- Module state outlives a world: DFHack caches script environments, and the
-- overlay framework rebuilds widgets on SC_WORLD_LOADED without clearing
-- anything here. Without this, loading a second fort whose camera happens to
-- start on the same z-level as the last one leaves cached_z matching and paints
-- the previous fort's stone colours.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        palettes = {}
        entry_cache = {}
        tint_cache = {}
        refresh_map_bounds()
        load_state()
        rebuild_art()
        refresh_texpos_maps(true)
        reset_cache(nil)
    elseif sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        -- Put DF's ramp overlays back; the next map hides them again.
        show_ramp_overlays()
        reset_cache(nil)
        map_max_x, map_max_y = nil, nil
        palettes = {}
        entry_cache = {}
        tint_cache = {}
        if sc == SC_WORLD_UNLOADED then
            -- Colour indices belong to a world. The textures are not deleted
            -- (see make_texture); they are only forgotten.
            stone_tint_textures = {art_count=ART_COUNT, art_sig=stone_tint_textures.art_sig}
            stone_tint_live = nil
        end
    end
end

-- ==========================================
-- THE WINDOW
-- ==========================================
TintWindow = defclass(TintWindow, widgets.Window)
TintWindow.ATTRS{
    frame_title='Stone Tint',
    -- Height is the body plus 4 (border and inset, top and bottom). The body
    -- runs to the Close line at row 26, so 27 rows.
    frame={w=44, h=31},
    resizable=false,
    autoarrange_subviews=true,
    autoarrange_gap=1,
}

local function toggle(label, key, field)
    return widgets.ToggleHotkeyLabel{
        label=label, key=key, initial_option=state[field],
        -- update_ramp_overlays here as well as per frame, so the overlays come back
        -- even with the stone-tint.map widget switched off.
        on_change=function(value)
            state[field]=value save_state() update_ramp_overlays() force_repaint()
        end,
    }
end

function TintWindow:init()
    local strength_options = {}
    for i, strength in ipairs(STRENGTHS) do
        strength_options[i] = {label=strength == 0 and 'Off' or strength .. '%', value=i}
    end
    local initial_idx = 1
    for i, strength in ipairs(STRENGTHS) do
        if strength == state.strength then initial_idx = i break end
    end
    self:addviews{
        widgets.Label{text='Tint strength:'},
        widgets.CycleHotkeyLabel{
            view_id='strength', label='Strength:', key='CUSTOM_SHIFT_S',
            options=strength_options, initial_option=initial_idx,
            on_change=function(idx) set_strength(STRENGTHS[idx]) end,
        },
        widgets.Slider{
            frame={l=1, w=38}, num_stops=#STRENGTHS,
            get_idx_fn=function() return self.subviews.strength:getOptionValue() end,
            on_change=function(idx) self.subviews.strength:setOption(idx, true) end,
        },
        widgets.Divider{frame={h=1}, frame_style_l=false, frame_style_r=false},
        toggle('Tint rough floors:', 'CUSTOM_R', 'rough'),
        toggle('Tint smooth floors:', 'CUSTOM_M', 'smooth'),
        toggle('Tint engraved floors:', 'CUSTOM_E', 'engraved'),
        -- Vanilla's engraving, or the same tile with the face carved out. Only
        -- while engraved floors are tinted: stone-tint draws them or nothing.
        toggle('Engraving faces:', 'CUSTOM_F', 'faces'),
        toggle('Tint stairs:', 'CUSTOM_T', 'stairs'),
        toggle('Tint ramps:', 'CUSTOM_A', 'ramps'),
        -- Soil rides on the switches above: a soil floor, stair or ramp needs
        -- this and the switch for its shape.
        toggle('Include soil:', 'CUSTOM_O', 'soil'),
        -- Global: every ramp's overlay goes, see RAMP OVERLAYS. Only while
        -- ramps are tinted.
        toggle('Hide ramp overlays:', 'CUSTOM_H', 'hide_overlays'),
        -- EDGE MODES: Smart puts tinted edges under snow, mud, leaves and DF's
        -- grass edges; Simple is 1.2.1's, always on top; Off leaves them to DF.
        widgets.CycleHotkeyLabel{
            label='Floor edges:', key='CUSTOM_D',
            options={{label='Smart', value='smart'}, {label='Simple', value='simple'},
                     {label='Off', value='off'}},
            initial_option=state.edges or 'smart',
            on_change=function(mode) set_edges(mode) end,
        },
        widgets.Label{frame={t=26}, text={{key='LEAVESCREEN', text=': Close'}}},
    }
end

TintScreen = defclass(TintScreen, gui.ZScreen)
TintScreen.ATTRS{focus_path='stone-tint', pass_movement_keys=true}
function TintScreen:init() self:addviews{TintWindow{}} end
function TintScreen:onDismiss() view=nil end

function show_gui()
    if not dfhack.isMapLoaded() then qerror('stone-tint needs a loaded fortress map') end
    view = view and view:raise() or TintScreen{}:show()
end

function set_preset(strength)
    return set_strength(strength)
end

-- 'default' or 'legacy' (THE BLEND).
function set_blend(blend)
    state.blend = blend
    save_state()
    entry_cache = {}
    tint_cache = {}
    force_repaint()
end

function set_edges(mode)
    state.edges = mode
    save_state()
    force_repaint()
end

function clear_material_cache()
    reset_cache(nil)
    palettes = {}
    entry_cache = {}
    tint_cache = {}
    refresh_map_bounds()
end

function get_state()
    return state
end

-- For `stone-tint status`: whether the art loaded, the counts the overlay
-- keeps in stone_tint_stats, the ramp overlay entries hidden, how many of the
-- engraved floor pages were found, and whether the art has the engraved cells
-- (an art-vanilla.lua older than this file does not, and then engraved floors
-- keep DF's picture).
function get_report()
    local ov = stone_tint_overlays
    local engraved_art = art ~= nil and art.CELLS.engraved_floor ~= nil
        and art.CELLS.engraved_floor_plain ~= nil
    return art ~= nil, stone_tint_stats, ov.hidden and #(ov.slots or {}) or nil,
        engraved_found, #ENGRAVED_PAGES + #live_engraved_specs, engraved_art, art_report
end


-- Initialize module state independently of widget construction. DFHack can preserve
-- widget class objects across development rescans without calling init() again.
load_state()
rebuild_art()
refresh_texpos_maps(true)
refresh_map_bounds()

OVERLAY_WIDGETS = {map=StoneTintOverlay}

if dfhack_flags.module then return end

local args = {...}
if not args[1] or args[1] == 'gui' then
    reqscript('stone-tint').show_gui()
elseif args[1] == 'clear-cache' then
    reqscript('stone-tint').clear_material_cache()
    print('stone-tint: material cache cleared')
elseif args[1] == 'status' then
    print(('stone-tint: overlay is %s'):format(
        overlay.isOverlayEnabled('stone-tint.map') and 'enabled' or 'disabled'))
    local st = reqscript('stone-tint').get_state()
    print(('stone-tint: strength is %d%%, %s blend, %s edges'):format(st.strength,
        st.blend or 'default', st.edges or 'smart'))
    local art_ok, stats, hidden, engraved_found, engraved_pages, engraved_art, ar =
        reqscript('stone-tint').get_report()
    if ar and ar.source == 'live' then
        print(('stone-tint: art read from the loaded graphics: %d cells from %s, %d kept vanilla'):format(
            ar.live, table.concat(ar.pages, ', '), ar.fallback))
    elseif ar then
        print('stone-tint: art is vanilla' .. (ar.error and (' (' .. ar.error .. ')') or ''))
    end
    if ar and ar.dirs then
        print(('stone-tint: world loads %d object folders, %d of them mods:'):format(
            ar.dirs + (ar.missing or 0), #(ar.mod_dirs or {})))
        for _, d in ipairs(ar.mod_dirs or {}) do print('    ' .. d) end
        if ar.missing_names then print('  not found:' .. ar.missing_names) end
    end
    if ar and ar.missing and ar.missing > 0 then
        print(('stone-tint: %d of the world object folders were not found on disk'):format(ar.missing))
    end
    if ar and ar.errors then
        for _, e in ipairs(ar.errors) do print('stone-tint: could not read ' .. e) end
    end
    if not art_ok then
        print('stone-tint: art data stone-tint/art-vanilla.lua did not load; nothing is tinted')
    end
    print(('stone-tint: tinted in the last drawn frame: %d floor, %d engraved, %d stair, %d ramp '
        .. 'tiles, %d of them on levels below; %d floor edges'):format(stats.floors,
        stats.engraved or 0, stats.stairs, stats.ramps, stats.below or 0, stats.edges or 0))
    print(('stone-tint: engraved floor pages found: %d of %d; engraved art %s'):format(
        engraved_found, engraved_pages,
        engraved_art and 'loaded' or 'missing from stone-tint/art-vanilla.lua'))
    print(('stone-tint: textures made this session: %d'):format(stats.textures))
    if hidden then
        print(('stone-tint: ramp overlays hidden (%d DF table entries)'):format(hidden))
    else
        print('stone-tint: ramp overlays shown')
    end
elseif args[1] == 'blend' then
    local b = args[2]
    if b ~= 'default' and b ~= 'legacy' then
        print(('stone-tint: blend is %s'):format(reqscript('stone-tint').get_state().blend or 'default'))
        qerror('use: stone-tint blend <default|legacy>')
    end
    reqscript('stone-tint').set_blend(b)
    print('stone-tint: blend set to ' .. b)
elseif args[1] == 'edges' then
    local mode = args[2]
    if mode ~= 'smart' and mode ~= 'simple' and mode ~= 'off' then
        print(('stone-tint: edges are %s'):format(reqscript('stone-tint').get_state().edges or 'smart'))
        qerror('use: stone-tint edges <smart|simple|off>')
    end
    reqscript('stone-tint').set_edges(mode)
    print('stone-tint: edges set to ' .. mode)
elseif args[1] == 'set' then
    local strength = tonumber(args[2])
    local valid = false
    for _, value in ipairs(STRENGTHS) do if value == strength then valid=true break end end
    -- Built from STRENGTHS rather than written out, so the message cannot drift
    -- from the ladder the check above actually uses.
    if not valid then qerror('strength must be one of: ' .. table.concat(STRENGTHS, ', ')) end
    reqscript('stone-tint').set_preset(strength)
else
    print('Use: stone-tint [gui]')
    print('     overlay enable stone-tint.map')
    print('     overlay disable stone-tint.map')
    print('     stone-tint clear-cache')
    print('     stone-tint status')
    print('     stone-tint set <' .. table.concat(STRENGTHS, '|') .. '>')
    print('     stone-tint blend <default|legacy>')
    print('     stone-tint edges <smart|simple|off>')
end
