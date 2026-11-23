"""Exercise the real render loop and edge painter offline under Lua 5.3."""
from lua_harness import load_lua


def check(name, *, drawn=999, lower=False, rough=True, smooth=True,
          source=True, occupied=False, flags=1, expected=1, budget=True,
          spat=0, floorkey=None, grass=False, mode='smart'):
    lua, mod, _ = load_lua()
    lua.execute('''
        local mod, drawn, lower, rough, smooth, source, occupied, flags,
            expected, budget, spat, floorkey, grass, mode = ...
        -- grass: the north neighbour (10,9) is a tile Stone Tint does not tint,
        -- whose own edge byte DF keeps (EDGES UNDER DF'S EDGES).
        local GRASS_BYTE = 0x12 << 24
        if grass then flags = flags | GRASS_BYTE end
        local function get(f, name)
            for i=1,100 do
                local n,v = debug.getupvalue(f,i)
                if n == name then return v end
                if not n then break end
            end
            error('missing upvalue '..name)
        end
        local function set(f, name, value)
            for i=1,100 do
                local n = debug.getupvalue(f,i)
                if n == name then debug.setupvalue(f,i,value); return end
                if not n then break end
            end
            error('missing upvalue '..name)
        end
        local render = mod.StoneTintOverlay.onRenderFrame
        local paint = get(render, 'paint_edges')
        local state = get(render, 'state')
        state.rough, state.smooth, state.edges = rough, smooth, mode
        state.hide_overlays = false
        local env = get(render, '_ENV')
        env.update_ramp_overlays = function() end
        mod.StoneTintOverlay.super = {onRenderFrame=function() end}
        dfhack.isMapLoaded = function() return true end
        dfhack.screen.inGraphicsMode = function() return true end
        local function viewport(bg, f)
            return {dim_x=1, dim_y=1, flag={active=true},
                screentexpos_background={[0]=bg},
                screentexpos_ramp_flag={[0]=0},
                screentexpos_floor_flag={[0]=f},
                screentexpos_background_two={[0]=occupied and 88 or 0},
                screentexpos_spatter={[0]=spat}}
        end
        local target = viewport(drawn, flags)
        local main = lower and viewport(0, 0) or target
        df.global = {window_x=10, window_y=10, window_z=5,
            gps={main_viewport=main, lower_viewport=lower and {[0]=target} or {}}}
        set(render, 'map_max_x', 100); set(render, 'map_max_y', 100)
        set(render, 'cached_z', 5)
        set(render, 'sentinel_texpos', function() return 123 end)
        set(render, 'tint_sentinel', 123)
        set(render, 'tint_strength', state.strength)
        set(render, 'known_texpos', {[999]=false})
        local cells = 0
        set(render, 'paint_cell', function()
            cells=cells+1
            if floorkey then set(paint, 'cell_key', floorkey) end
            return 1
        end)
        set(render, 'level_caches', function() return {}, {} end)
        -- Keep the real edge-source eligibility check and real flag handling.
        df.tiletype_shape.FLOOR = 10
        df.tiletype = {attrs={[1]={shape=10, special=1, material=1},
            [2]={shape=10, special=99, material=1}}}
        dfhack.maps = {
            getTileType=function(x, y) if y == 9 then return 2 end return source and 1 or 2 end,
            getTileFlags=function() return {hidden=false} end,
        }
        local lookups = 0
        set(paint, 'colour_code', function(x,y,z)
            assert(x==10 and y==11 and z==(lower and 4 or 5))
            lookups=lookups+1; return 2
        end)
        set(paint, 'tint_texpos', function(key,colour,id,strength,remaining)
            assert(colour==1 and id==2 and (spat==0 or mode=='simple'), 'single edge without spatter')
            return budget and 777 or nil, remaining
        end)
        -- 207983 is readable snow; 999999 is a picture that cannot be read.
        set(paint, 'spatter_pixels', function(t) return t == 207983 and {} or false end)
        set(paint, 'edges_texpos', function(keys, n, strength, remaining, sp, floor)
            if floor then
                assert(mode=='smart', 'floor-under path only in smart mode')
                assert(floor==floorkey and sp==nil and n==1, 'floor-under path')
                return budget and 999 or nil, remaining
            end
            assert(spat==207983 and sp==207983 and n==1, 'spatter goes through the combined path')
            return budget and 888 or nil, remaining
        end)
        render({}, nil, nil)
        assert(mod.stone_tint_stats.edges==expected, 'edge count')
        local kept = grass and GRASS_BYTE or 0
        assert(target.screentexpos_floor_flag[0]==(expected==1 and kept or flags),
            'only clear our flags when replacement is ready; DF keeps its own')
        local under = expected==1 and grass and floorkey and mode=='smart'
        assert(target.screentexpos_background[0]==(under and 999 or drawn),
            'floor picture holds the edges only under DF edges on a tinted floor')
        assert(target.screentexpos_background_two[0]==
            (under and 0 or expected==1 and (spat ~= 0 and mode=='smart' and 888 or 777)
                or occupied and 88 or 0),
            'replacement texture')
        assert(cells==(drawn==1234 and 1 or 0), 'floor-art eligibility unchanged')
        assert(target.screentexpos_spatter[0]==spat, 'DF spatter left in place')
    ''', mod, drawn, lower, rough, smooth, source, occupied, flags, expected, budget,
        spat, floorkey, grass, mode)
    print(f'PASS {name}')


check('unrecognized receiving terrain')
check('recognized receiving terrain', drawn=1234)
check('empty receiving background', drawn=0)
check('smooth tint disabled', smooth=False)
check('rough tint disabled', rough=False, expected=0)
check('non-rough source', source=False, expected=0)
check('existing second background preserved', occupied=True, expected=0)
check('no edge flag', flags=0, expected=0)
check('texture budget exhausted', budget=False, expected=0)
check('unrecognized lower-level terrain', lower=True)
check('recognized lower-level terrain', drawn=1234, lower=True)
check('lower-level rough tint disabled', lower=True, rough=False, expected=0)
check('snow on receiver: edge with snow baked in', spat=207983)
check('snow on receiver below: edge with snow baked in', lower=True, spat=207983)
check('unreadable spatter picture: left to DF', spat=999999, expected=0)
check('snow but budget exhausted: left to DF this frame', spat=207983, budget=False,
      expected=0)
check('grass edge too, tinted floor: our edge goes into the floor picture',
      drawn=1234, floorkey=4242, grass=True)
check('grass edge too, tinted floor below: into the floor picture', drawn=1234,
      floorkey=4242, grass=True, lower=True)
check('grass edge too, snow: floor picture, DF draws the snow itself', drawn=1234,
      floorkey=4242, grass=True, spat=207983)
check('grass edge too, floor not tinted: our layer as before', grass=True)
check('tinted floor, no DF edge left: our layer as before', drawn=1234, floorkey=4242)
check('grass edge too, budget exhausted: nothing this frame', drawn=1234,
      floorkey=4242, grass=True, budget=False, expected=0)
check('simple: snow ignored, edge on top as in 1.2.1', spat=207983, mode='simple')
check('simple: grass too, still our layer', drawn=1234, floorkey=4242, grass=True,
      mode='simple')
check('off: nothing tinted, DF keeps its edges', mode='off', expected=0)
check('off: with grass and snow, untouched', drawn=1234, floorkey=4242, grass=True,
      spat=207983, mode='off', expected=0)
