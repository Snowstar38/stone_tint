--@ module = true
-- Pure Lua 5.3 raw resolver. Object directories must be absolute, in load order.
-- Within an object directory .txt files are sorted by name for repeatability.
-- tokens uses the first token field; selectors also preserves qualified variants.
local function trim(s) return s:match('^%s*(.-)%s*$') end
local function join(a, b)
    b = b:gsub('\\', '/')
    if b:match('^%a:/') or b:sub(1, 1) == '/' then return b end
    return a:gsub('\\', '/'):gsub('/+$', '') .. '/' .. b
end
local function integer(s, minimum)
    if type(s) ~= 'string' or not s:match('^%d+$') then return nil end
    local n = tonumber(s)
    if n and n >= minimum and n < math.huge then return n end
end
local function safe(fn, arg)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, arg)
    if ok then return value end
end

function default_fs()
    return {
        listdir = function(dir)
            if dfhack and dfhack.filesystem then
                return dfhack.filesystem.listdir(dir)
            end
        end,
        read = function(path)
            local f = io.open(path, 'rb')
            if not f then return nil end
            local contents = f:read('*a')
            f:close()
            return contents
        end,
    }
end

local function parse(contents, dir)
    if contents:find('\0', 1, true) then error('binary file') end
    local outside = contents:gsub('%[[^%[%]]*%]', '')
    -- Other raw dialects include literal bracket characters (ASCII_GRAPHICS).
    -- Only reject unterminated directives belonging to this resolver's dialect.
    for _, tag in ipairs({'OBJECT', 'TILE_PAGE', 'FILE', 'TILE_DIM', 'PAGE_DIM',
                         'PAGE_DIM_PIXELS', 'TILE_GRAPHICS', 'TILE_GRAPHICS_RECTANGLE'}) do
        assert(not outside:find('%[%s*' .. tag .. '%s*:'), 'unterminated ' .. tag)
    end
    local directives = {}
    for body in contents:gmatch('%[([^%[%]]*)%]') do
        local fields = {}
        for field in (body .. ':'):gmatch('(.-):') do
            fields[#fields + 1] = trim(field)
        end
        directives[#directives + 1] = fields
    end
    local object
    for _, a in ipairs(directives) do
        if a[1] == 'OBJECT' then
            if object or (a[2] ~= 'TILE_PAGE' and a[2] ~= 'GRAPHICS') then
                return {}, {}, {}
            end
            object = a[2]
        end
    end
    local pages, tokens, selectors = {}, {}, {}
    if not object then return pages, tokens, selectors end
    local current
    local function finish()
        if not current then return end
        assert(current.file and current.tile_w and current.tile_h and current.dw and current.dh,
            'incomplete tile page')
        if current.pixels then
            -- Vanilla includes a 32x488 statue sheet with 32px tiles. Retain
            -- pixel dimensions and count complete cells (ignore the 8px tail).
            current.pixel_w, current.pixel_h = current.dw, current.dh
            current.cols = math.floor(current.dw / current.tile_w)
            current.rows = math.floor(current.dh / current.tile_h)
        else current.cols, current.rows = current.dw, current.dh end
        current.dw, current.dh, current.pixels = nil, nil, nil
        local name = current.name
        current.name = nil
        pages[name] = current
        current = nil
    end
    for _, a in ipairs(directives) do
        local tag = a[1]
        if object == 'TILE_PAGE' then
            if tag == 'TILE_PAGE' then
                finish()
                assert(a[2] and a[2] ~= '', 'empty page name')
                current = {name=a[2], dir=dir}
            elseif current and tag == 'FILE' then
                -- Rejoin colon fields so absolute Windows paths remain intact.
                local file = table.concat(a, ':', 2)
                assert(file ~= '', 'empty filename')
                current.file = join(join(dir, 'graphics'), file)
            elseif current and (tag == 'TILE_DIM' or tag == 'PAGE_DIM' or tag == 'PAGE_DIM_PIXELS') then
                local w, h = integer(a[2], 1), integer(a[3], 1)
                assert(w and h, 'invalid dimensions')
                if tag == 'TILE_DIM' then current.tile_w, current.tile_h = w, h
                else current.dw, current.dh, current.pixels = w, h, tag == 'PAGE_DIM_PIXELS' end
            end
        elseif tag == 'TILE_GRAPHICS' or tag == 'TILE_GRAPHICS_RECTANGLE' then
            local rectangle = tag == 'TILE_GRAPHICS_RECTANGLE'
            local ti = rectangle and 7 or 5
            local x, y = integer(a[3], 0), integer(a[4], 0)
            assert(a[2] and a[2] ~= '' and x and y and a[ti] and a[ti] ~= '',
                'invalid tile graphics')
            local entry = {page=a[2], x=x, y=y, dir=dir}
            if rectangle then
                entry.width, entry.height = integer(a[5], 1), integer(a[6], 1)
                assert(entry.width and entry.height, 'invalid rectangle')
            end
            local key = table.concat(a, ':', ti)
            selectors[key] = entry
            tokens[a[ti]] = entry
        end
    end
    finish()
    return pages, tokens, selectors
end

function resolve(object_dirs, fs)
    fs = fs or default_fs()
    local result = {tokens={}, pages={}, selectors={}, skipped={}}
    for _, dir in ipairs(object_dirs) do
        local graphics = join(dir, 'graphics')
        local files = safe(fs.listdir, graphics)
        if type(files) == 'table' then
            local names = {}
            for _, name in ipairs(files) do
                if type(name) == 'string' and name:lower():match('%.txt$')
                    and not name:find('[/\\]') then names[#names + 1] = name end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                local path = join(graphics, name)
                local contents = safe(fs.read, path)
                if type(contents) == 'string' then
                    local ok, pages, tokens, selectors = pcall(parse, contents, dir)
                    if ok then
                        for k, v in pairs(pages) do result.pages[k] = v end
                        for k, v in pairs(tokens) do result.tokens[k] = v end
                        for k, v in pairs(selectors) do result.selectors[k] = v end
                    else
                        result.skipped[#result.skipped + 1] = {file=path, reason=tostring(pages)}
                    end
                else result.skipped[#result.skipped + 1] = {file=path, reason='unreadable'} end
            end
        end
    end
    return result
end

-- BEGIN GENERATED TOKEN INVENTORY
-- Vanilla has no stone-floor tokens at DETAILED_FLOORS 0:3..2:5 or
-- DETAILED_ALT_FLOORS 7:4..7:6 (the legacy VARIANTS aliases).
-- Use the STONE_FLOOR tokens below; do not synthesize tokens for those cells.
NEEDED_TOKENS = {
    -- Stone floors (runtime ids 1-12)
    'STONE_FLOOR_1', -- id 1: FLOORS 0:3
    'STONE_FLOOR_2', -- id 2: FLOORS 1:3
    'STONE_FLOOR_3', -- id 3: FLOORS 2:3
    'STONE_FLOOR_4', -- id 4: FLOORS 0:4
    'STONE_FLOOR_5', -- id 5: FLOORS 1:4
    'STONE_FLOOR_6', -- id 6: FLOORS 2:4
    'STONE_FLOOR_7', -- id 7: FLOORS 0:5
    'STONE_FLOOR_8', -- id 8: FLOORS 1:5
    'STONE_FLOOR_9', -- id 9: FLOORS 2:5
    'STONE_FLOOR_5B', -- id 10: ALT_FLOORS 7:4
    'STONE_FLOOR_5C', -- id 11: ALT_FLOORS 7:5
    'STONE_FLOOR_5D', -- id 12: ALT_FLOORS 7:6
    -- Smooth floor (runtime id 13)
    'SMOOTH_FLOOR', -- id 13: FLOORS 6:3
    -- Soil floors (runtime ids 14-25)
    'DIRT_FLOOR_1', -- id 14: FLOORS 0:6
    'DIRT_FLOOR_2', -- id 15: FLOORS 1:6
    'DIRT_FLOOR_3', -- id 16: FLOORS 2:6
    'DIRT_FLOOR_4', -- id 17: FLOORS 0:7
    'DIRT_FLOOR_5', -- id 18: FLOORS 1:7
    'DIRT_FLOOR_6', -- id 19: FLOORS 2:7
    'DIRT_FLOOR_7', -- id 20: FLOORS 0:8
    'DIRT_FLOOR_8', -- id 21: FLOORS 1:8
    'DIRT_FLOOR_9', -- id 22: FLOORS 2:8
    'DIRT_FLOOR_5B', -- id 23: ALT_FLOORS 7:7
    'DIRT_FLOOR_5C', -- id 24: ALT_FLOORS 7:8
    'DIRT_FLOOR_5D', -- id 25: ALT_FLOORS 7:9
    -- Engraved pages: both have tokens; id 27 is the derived face-free art, not another raw cell
    'FLOOR_STONE_ENGRAVED_NON_PALETTE', -- id 26: FLOOR_STONE_ENGRAVED_NON_PALETTE 0:0
    'FLOOR_STONE_ENGRAVED_PALETTE', -- id 26: FLOOR_STONE_ENGRAVED_PALETTE 0:0
    -- Stairs (runtime ids 28-33)
    'STONE_STAIR_UPDOWN', -- id 28: STAIRS 0:1
    'STONE_STAIR_UP', -- id 29: STAIRS 1:1
    'STONE_STAIR_DOWN', -- id 30: STAIRS 2:1
    'DIRT_STAIR_UPDOWN', -- id 31: STAIRS 0:2
    'DIRT_STAIR_UP', -- id 32: STAIRS 1:2
    'DIRT_STAIR_DOWN', -- id 33: STAIRS 2:2
    -- STONE ramps (aliases share a runtime art id)
    'STONE_RAMP_WITH_WALL_N_S_E_W', -- id 34: STONE_RAMPS 11:1
    'STONE_RAMP_WITH_WALL_S_NW_NE', -- id 35: STONE_RAMPS 11:11
    'STONE_RAMP_WITH_WALL_NW_NE', -- id 36: STONE_RAMPS 11:3
    'STONE_RAMP_WITH_WALL_SW_SE', -- id 37: STONE_RAMPS 11:5
    'STONE_RAMP_WITH_WALL_W_NE', -- id 38: STONE_RAMPS 11:7
    'STONE_RAMP_WITH_WALL_N_W_SE', -- id 39: STONE_RAMPS 11:9
    'STONE_RAMP_WITH_WALL_NE_SW_SE', -- id 39: STONE_RAMPS 11:9
    'STONE_RAMP_OTHER', -- id 40: STONE_RAMPS 13:1
    'STONE_RAMP_WITH_WALL_W_NE_SE', -- id 41: STONE_RAMPS 13:11
    'STONE_RAMP_WITH_WALL_NE_SE', -- id 42: STONE_RAMPS 13:3
    'STONE_RAMP_WITH_WALL_NW_SW', -- id 43: STONE_RAMPS 13:5
    'STONE_RAMP_WITH_WALL_N_SE', -- id 44: STONE_RAMPS 13:7
    'STONE_RAMP_WITH_WALL_N_E_SW', -- id 45: STONE_RAMPS 13:9
    'STONE_RAMP_WITH_WALL_NW_SW_SE', -- id 45: STONE_RAMPS 13:9
    'STONE_RAMP_WITH_WALL_NW_SE', -- id 46: STONE_RAMPS 1:11
    'STONE_RAMP_WITH_WALL_E', -- id 47: STONE_RAMPS 1:3
    'STONE_RAMP_WITH_WALL_S_NE', -- id 48: STONE_RAMPS 1:7
    'STONE_RAMP_WITH_WALL_N_SW', -- id 49: STONE_RAMPS 1:9
    'STONE_RAMP_WITH_WALL_SE', -- id 50: STONE_RAMPS 2:1
    'STONE_RAMP_WITH_WALL_S_E', -- id 51: STONE_RAMPS 2:2
    'STONE_RAMP_WITH_WALL_N_E', -- id 52: STONE_RAMPS 2:4
    'STONE_RAMP_WITH_WALL_NE', -- id 53: STONE_RAMPS 2:5
    'STONE_RAMP_WITH_WALL_S', -- id 54: STONE_RAMPS 3:1
    'STONE_RAMP_WITH_WALL_NE_SW', -- id 55: STONE_RAMPS 3:11
    'STONE_RAMP_WITH_WALL_N', -- id 56: STONE_RAMPS 3:5
    'STONE_RAMP_WITH_WALL_W_SE', -- id 57: STONE_RAMPS 3:7
    'STONE_RAMP_WITH_WALL_E_NW', -- id 58: STONE_RAMPS 3:9
    'STONE_RAMP_WITH_WALL_SW', -- id 59: STONE_RAMPS 4:1
    'STONE_RAMP_WITH_WALL_S_W', -- id 60: STONE_RAMPS 4:2
    'STONE_RAMP_WITH_WALL_N_W', -- id 61: STONE_RAMPS 4:4
    'STONE_RAMP_WITH_WALL_NW', -- id 62: STONE_RAMPS 4:5
    'STONE_RAMP_WITH_WALL_NW_NE_SW_SE', -- id 63: STONE_RAMPS 5:11
    'STONE_RAMP_WITH_WALL_W', -- id 64: STONE_RAMPS 5:3
    'STONE_RAMP_WITH_WALL_N_S', -- id 65: STONE_RAMPS 7:1
    'STONE_RAMP_WITH_WALL_N_SW_SE', -- id 66: STONE_RAMPS 7:11
    'STONE_RAMP_WITH_WALL_S_W_E', -- id 67: STONE_RAMPS 7:3
    'STONE_RAMP_WITH_WALL_N_W_E', -- id 68: STONE_RAMPS 7:5
    'STONE_RAMP_WITH_WALL_E_SW', -- id 69: STONE_RAMPS 7:7
    'STONE_RAMP_WITH_WALL_S_E_NW', -- id 70: STONE_RAMPS 7:9
    'STONE_RAMP_WITH_WALL_NW_NE_SW', -- id 70: STONE_RAMPS 7:9
    'STONE_RAMP_WITH_WALL_W_E', -- id 71: STONE_RAMPS 9:1
    'STONE_RAMP_WITH_WALL_E_NW_SW', -- id 72: STONE_RAMPS 9:11
    'STONE_RAMP_WITH_WALL_N_S_E', -- id 73: STONE_RAMPS 9:3
    'STONE_RAMP_WITH_WALL_N_S_W', -- id 74: STONE_RAMPS 9:5
    'STONE_RAMP_WITH_WALL_S_NW', -- id 75: STONE_RAMPS 9:7
    'STONE_RAMP_WITH_WALL_S_W_NE', -- id 76: STONE_RAMPS 9:9
    'STONE_RAMP_WITH_WALL_NW_NE_SE', -- id 76: STONE_RAMPS 9:9
    -- SOIL ramps (aliases share a runtime art id)
    'SOIL_RAMP_WITH_WALL_N_S_E_W', -- id 77: SOIL_RAMPS 11:1
    'SOIL_RAMP_WITH_WALL_S_NW_NE', -- id 78: SOIL_RAMPS 11:11
    'SOIL_RAMP_WITH_WALL_NW_NE', -- id 79: SOIL_RAMPS 11:3
    'SOIL_RAMP_WITH_WALL_SW_SE', -- id 80: SOIL_RAMPS 11:5
    'SOIL_RAMP_WITH_WALL_W_NE', -- id 81: SOIL_RAMPS 11:7
    'SOIL_RAMP_WITH_WALL_N_W_SE', -- id 82: SOIL_RAMPS 11:9
    'SOIL_RAMP_WITH_WALL_NE_SW_SE', -- id 82: SOIL_RAMPS 11:9
    'SOIL_RAMP_OTHER', -- id 83: SOIL_RAMPS 13:1
    'SOIL_RAMP_WITH_WALL_W_NE_SE', -- id 84: SOIL_RAMPS 13:11
    'SOIL_RAMP_WITH_WALL_NE_SE', -- id 85: SOIL_RAMPS 13:3
    'SOIL_RAMP_WITH_WALL_NW_SW', -- id 86: SOIL_RAMPS 13:5
    'SOIL_RAMP_WITH_WALL_N_SE', -- id 87: SOIL_RAMPS 13:7
    'SOIL_RAMP_WITH_WALL_N_E_SW', -- id 88: SOIL_RAMPS 13:9
    'SOIL_RAMP_WITH_WALL_NW_SW_SE', -- id 88: SOIL_RAMPS 13:9
    'SOIL_RAMP_WITH_WALL_NW_SE', -- id 89: SOIL_RAMPS 1:11
    'SOIL_RAMP_WITH_WALL_E', -- id 90: SOIL_RAMPS 1:3
    'SOIL_RAMP_WITH_WALL_S_NE', -- id 91: SOIL_RAMPS 1:7
    'SOIL_RAMP_WITH_WALL_N_SW', -- id 92: SOIL_RAMPS 1:9
    'SOIL_RAMP_WITH_WALL_SE', -- id 93: SOIL_RAMPS 2:1
    'SOIL_RAMP_WITH_WALL_S_E', -- id 94: SOIL_RAMPS 2:2
    'SOIL_RAMP_WITH_WALL_N_E', -- id 95: SOIL_RAMPS 2:4
    'SOIL_RAMP_WITH_WALL_NE', -- id 96: SOIL_RAMPS 2:5
    'SOIL_RAMP_WITH_WALL_S', -- id 97: SOIL_RAMPS 3:1
    'SOIL_RAMP_WITH_WALL_NE_SW', -- id 98: SOIL_RAMPS 3:11
    'SOIL_RAMP_WITH_WALL_N', -- id 99: SOIL_RAMPS 3:5
    'SOIL_RAMP_WITH_WALL_W_SE', -- id 100: SOIL_RAMPS 3:7
    'SOIL_RAMP_WITH_WALL_E_NW', -- id 101: SOIL_RAMPS 3:9
    'SOIL_RAMP_WITH_WALL_SW', -- id 102: SOIL_RAMPS 4:1
    'SOIL_RAMP_WITH_WALL_S_W', -- id 103: SOIL_RAMPS 4:2
    'SOIL_RAMP_WITH_WALL_N_W', -- id 104: SOIL_RAMPS 4:4
    'SOIL_RAMP_WITH_WALL_NW', -- id 105: SOIL_RAMPS 4:5
    'SOIL_RAMP_WITH_WALL_NW_NE_SW_SE', -- id 106: SOIL_RAMPS 5:11
    'SOIL_RAMP_WITH_WALL_W', -- id 107: SOIL_RAMPS 5:3
    'SOIL_RAMP_WITH_WALL_N_S', -- id 108: SOIL_RAMPS 7:1
    'SOIL_RAMP_WITH_WALL_N_SW_SE', -- id 109: SOIL_RAMPS 7:11
    'SOIL_RAMP_WITH_WALL_S_W_E', -- id 110: SOIL_RAMPS 7:3
    'SOIL_RAMP_WITH_WALL_N_W_E', -- id 111: SOIL_RAMPS 7:5
    'SOIL_RAMP_WITH_WALL_E_SW', -- id 112: SOIL_RAMPS 7:7
    'SOIL_RAMP_WITH_WALL_S_E_NW', -- id 113: SOIL_RAMPS 7:9
    'SOIL_RAMP_WITH_WALL_NW_NE_SW', -- id 113: SOIL_RAMPS 7:9
    'SOIL_RAMP_WITH_WALL_W_E', -- id 114: SOIL_RAMPS 9:1
    'SOIL_RAMP_WITH_WALL_E_NW_SW', -- id 115: SOIL_RAMPS 9:11
    'SOIL_RAMP_WITH_WALL_N_S_E', -- id 116: SOIL_RAMPS 9:3
    'SOIL_RAMP_WITH_WALL_N_S_W', -- id 117: SOIL_RAMPS 9:5
    'SOIL_RAMP_WITH_WALL_S_NW', -- id 118: SOIL_RAMPS 9:7
    'SOIL_RAMP_WITH_WALL_S_W_NE', -- id 119: SOIL_RAMPS 9:9
    'SOIL_RAMP_WITH_WALL_NW_NE_SE', -- id 119: SOIL_RAMPS 9:9
}

return {resolve=resolve, default_fs=default_fs, NEEDED_TOKENS=NEEDED_TOKENS}
