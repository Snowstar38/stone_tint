-- stone-tint/liveart.lua
--@ module = true
-- Stone Tint's art, built from the tile pages the loaded world actually uses.
--
-- art-vanilla.lua is vanilla's floor, stair and ramp art, baked. A graphics mod
-- that re-points those tokens at pages of its own (Rounded Hills:
-- FLOORS_ROUND, STONE_RAMPS_ROUND, ...; Detailed Landscapes: the same names
-- with _DETAILED) changes what DF draws, so tinting vanilla's art over it
-- swaps the mod's rounded ramps back to square ones, and floors on the mod's
-- pages are never recognised at all. build() looks each token up in the raws
-- the world loaded (graphicsraws.lua), reads that page's image off disk
-- (imagedecode.lua), and returns a table shaped like art-vanilla.lua, so the
-- tint maths and the renderer do not change. No other mod's art is copied into
-- Stone Tint: it is read from the user's own install at map load.
--
-- Each pixel is keyed the way build_stone_tint_art.py keys vanilla's: the
-- column of palettes.png row 0 nearest it in Rec.601 luminance, ties to the
-- first. Run over vanilla's own pages, build() reproduces art-vanilla.lua's
-- pixels exactly (test_liveart.py).

CELL_PX = 32

-- Rec.601 luminance of palettes.png row 0, DF's untinted reference ramp, as
-- numpy computed it in build_stone_tint_art.py (vanilla 53.16).
KEY_LUMA = {48.613, 64.27799999999999, 72.637, 80.409, 89.708, 108.192, 137.861,
    168.38799999999998, 212.082, 48.613, 62.31399999999999, 76.01499999999999,
    93.60199999999999, 111.189, 142.32, 165.587, 195.073, 255.0}

local FLOOR_SUFFIXES = {'1', '2', '3', '4', '5', '6', '7', '8', '9', '5b', '5c', '5d'}
local STAIR_SHAPES = {'updown', 'up', 'down'}
local WALL_BITS = {'N', 'W', 'E', 'S', 'NW', 'NE', 'SW', 'SE'}
local ADJACENT = {NW={'N', 'W'}, NE={'N', 'E'}, SW={'S', 'W'}, SE={'S', 'E'}}
local CARDINAL = {N=true, S=true, E=true, W=true}

-- art cell name -> raw token, for everything but ramps.
local function plain_sources()
    local src = {}
    for _, n in ipairs(FLOOR_SUFFIXES) do
        src['stone_floor_' .. n] = 'STONE_FLOOR_' .. n:upper()
        src['soil_floor_' .. n] = 'DIRT_FLOOR_' .. n:upper()
    end
    src.smooth_floor = 'SMOOTH_FLOOR'
    for _, s in ipairs(STAIR_SHAPES) do
        src['stone_stair_' .. s] = 'STONE_STAIR_' .. s:upper()
        src['soil_stair_' .. s] = 'DIRT_STAIR_' .. s:upper()
    end
    return src
end

-- The wall set a ramp token names, as a sorted key: 'E,N' for ..._WITH_WALL_N_E.
local function set_key(parts)
    table.sort(parts)
    return table.concat(parts, ',')
end

-- [set key] = token, for every token of one ramp family the raws define.
local function ramp_tokens(tokens, prefix)
    local out = {}
    for name in pairs(tokens) do
        if name:sub(1, #prefix) == prefix then
            local rest = name:sub(#prefix + 1)
            if rest == 'OTHER' then
                out[''] = name
            else
                local walls = rest:match('^WITH_WALL_(.+)$')
                if walls then
                    local parts = {}
                    for p in walls:gmatch('[^_]+') do parts[#parts + 1] = p end
                    out[set_key(parts)] = name
                end
            end
        end
    end
    return out
end

-- The set key DF's token rule gives a wall byte: the orthogonal walls, plus
-- each diagonal wall whose two orthogonal neighbours are both open.
local function walls_key(bits)
    local walls = {}
    for i, w in ipairs(WALL_BITS) do
        if (bits >> (i - 1)) & 1 == 1 then walls[w] = true end
    end
    local parts = {}
    for w in pairs(walls) do
        if CARDINAL[w] then
            parts[#parts + 1] = w
        else
            local a, b = ADJACENT[w][1], ADJACENT[w][2]
            if not walls[a] and not walls[b] then parts[#parts + 1] = w end
        end
    end
    return set_key(parts)
end

-- Whether a page belongs to vanilla, by the folder that defined it.
local function is_vanilla_dir(dir)
    dir = (dir or ''):gsub('\\', '/'):lower()
    return dir:find('/data/vanilla/', 1, true) ~= nil or dir:sub(1, 13) == 'data/vanilla/'
end

local function key_of(r, g, b)
    local l = r * 0.299 + g * 0.587 + b * 0.114
    local best, bestd = 0, math.huge
    for k = 1, #KEY_LUMA do
        local d = math.abs(l - KEY_LUMA[k])
        if d < bestd then best, bestd = k - 1, d end
    end
    return best
end

-- Builds the art.
--   resolved  graphicsraws.resolve() output for the loaded world
--   vanilla   art-vanilla.lua's module (used for vanilla's engraved cells, the
--             face-free one of which no page holds, and for any cell that
--             cannot be read)
--   decoder   imagedecode.lua's module
--   opts.force  read every page, vanilla's included (tests)
-- Returns art, info. art is vanilla itself when every cell still comes from a
-- vanilla page (nothing to read). info = {live=n cells read, fallback=n,
-- pages={page token=true}, errors={...}, conflicts=n}.
function build(resolved, vanilla, decoder, opts)
    opts = opts or {}
    local info = {live=0, fallback=0, pages={}, errors={}, conflicts=0}
    local tokens = resolved and resolved.tokens or {}
    local pages = resolved and resolved.pages or {}

    -- cell name -> {page=, x=, y=} for every cell a page can supply.
    local want = {}
    for cell, token in pairs(plain_sources()) do
        local t = tokens[token]
        if t then want[cell] = t end
    end
    -- An engraving mod (Sumptuously Engraved Floors: FLOOR_STONE_ENGRAVED_
    -- NON_PALETTE on a page of its own) replaces vanilla's dwarf face. Its
    -- picture has no face to carve out, so it stands for both engraved cells
    -- and the "Engraving faces" switch makes no difference under it. On
    -- vanilla's page the baked cells stay: the face-free one is made by
    -- build_stone_tint_art.py, not read off a page.
    local eng = tokens['FLOOR_STONE_ENGRAVED_NON_PALETTE']
    local eng_page = eng and pages[eng.page]
    if eng_page and not is_vanilla_dir(eng_page.dir) then
        want.engraved_floor, want.engraved_floor_plain = eng, eng
    end
    for _, fam in ipairs({{'stone', 'STONE_RAMP_'}, {'soil', 'SOIL_RAMP_'}}) do
        local by_key = ramp_tokens(tokens, fam[2])
        for bits = 0, 255 do
            local vcell = vanilla.RAMP_CELL[bits]
            local token = vcell and by_key[walls_key(bits)]
            local t = token and tokens[token]
            if t then
                local cell = fam[1] .. '_ramp_' .. vcell
                local had = want[cell]
                if not had then
                    want[cell] = t
                elseif had.page ~= t.page or had.x ~= t.x or had.y ~= t.y then
                    -- Two wall layouts vanilla draws alike, drawn apart by a
                    -- mod. Stone Tint has one cell for them; the first wins.
                    info.conflicts = info.conflicts + 1
                end
            end
        end
    end

    local any_mod = false
    for _, t in pairs(want) do
        local p = pages[t.page]
        if p and not is_vanilla_dir(p.dir) then any_mod = true break end
    end
    if not any_mod and not opts.force then return vanilla, info end

    -- Start from vanilla's pixel table, so a vanilla cell's indices stay valid.
    local PIXELS, lookup = {}, {}
    for i, e in ipairs(vanilla.PIXELS) do
        PIXELS[i] = e
        local k = e[4] == 0 and 'T' or (e[1] .. ',' .. e[2] .. ',' .. e[3] .. ',' .. e[4] .. ',' .. e[5])
        if not lookup[k] then lookup[k] = i end
    end
    local DIGIT = {}
    for i = 1, #vanilla.ALPHABET do DIGIT[vanilla.ALPHABET:byte(i)] = i - 1 end
    local INDEX = {}
    local function vanilla_index(cell)
        local s = vanilla.CELLS[cell]
        if not s then return nil end
        local idx = {}
        for i = 1, CELL_PX * CELL_PX do
            idx[i] = DIGIT[s:byte(2 * i - 1)] * 64 + DIGIT[s:byte(2 * i)] + 1
        end
        return idx
    end

    local images, keycache = {}, {}
    local function image_for(page)
        local img = images[page.file]
        if img == nil then
            local ok, res, err = pcall(decoder.decode_file, page.file)
            img = ok and res or false
            if not img then info.errors[#info.errors + 1] = tostring(page.file) .. ': ' .. tostring(ok and err or res) end
            images[page.file] = img
        end
        return img or nil
    end

    for cell in pairs(vanilla.CELLS) do
        local t = want[cell]
        local p = t and pages[t.page]
        local img = p and p.tile_w == CELL_PX and p.tile_h == CELL_PX and image_for(p)
        local x0, y0 = t and t.x * CELL_PX, t and t.y * CELL_PX
        if img and x0 + CELL_PX <= img.width and y0 + CELL_PX <= img.height then
            local idx, px, w = {}, img.pixels, img.width
            for y = 0, CELL_PX - 1 do
                local base = ((y0 + y) * w + x0) * 4
                for x = 0, CELL_PX - 1 do
                    local o = base + x * 4
                    local r, g, b, a = px:byte(o + 1, o + 4)
                    local i
                    if a == 0 then
                        i = 1
                    else
                        local ck = r * 65536 + g * 256 + b
                        local k = keycache[ck]
                        if not k then k = key_of(r, g, b) keycache[ck] = k end
                        local lk = r .. ',' .. g .. ',' .. b .. ',' .. a .. ',' .. k
                        i = lookup[lk]
                        if not i then
                            i = #PIXELS + 1
                            PIXELS[i] = {r, g, b, a, k}
                            lookup[lk] = i
                        end
                    end
                    idx[y * CELL_PX + x + 1] = i
                end
            end
            INDEX[cell] = idx
            info.live = info.live + 1
            info.pages[t.page] = true
        else
            INDEX[cell] = vanilla_index(cell)
            info.fallback = info.fallback + 1
        end
    end

    return {
        CELL_PX = CELL_PX,
        ALPHABET = vanilla.ALPHABET,
        PIXELS = PIXELS,
        CELLS = vanilla.CELLS,      -- which cells exist; pixels come from INDEX
        INDEX = INDEX,
        RAMP_CELL = vanilla.RAMP_CELL,
    }, info
end

return {build=build, KEY_LUMA=KEY_LUMA, CELL_PX=CELL_PX}
