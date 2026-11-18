"""Load the actual renderer with narrow mocks; no game process is contacted."""
from pathlib import Path

from lupa.lua53 import LuaRuntime

MOD = Path(__file__).resolve().parents[1] / 'stone_tint/scripts_modinstalled'


def load_lua():
    lua = LuaRuntime(unpack_returned_tuples=True)
    # Narrow, explicit mocks: unexpected requirements raise instead of returning
    # recursively permissive dummy objects. No game process or bridge is used.
    lua.execute('''
        dfhack_flags = {module=true}
        SC_MAP_LOADED, SC_MAP_UNLOADED, SC_WORLD_UNLOADED = 1, 2, 3
        df = {
            tiletype_shape={STAIR_UPDOWN=1, STAIR_UP=2, STAIR_DOWN=3},
            tiletype_material={STONE=1, MINERAL=2, FEATURE=3, LAVA_STONE=4},
            tiletype_special={NORMAL=1, WET=2},
        }
        dfhack = {
            isWorldLoaded=function() return false end,
            isMapLoaded=function() return false end,
            onStateChange={},
            screen={findGraphicsTile=function() return nil end},
            printerr=function(s) error(s) end,
        }
        function defclass(_, base)
            assert(type(base) == 'table')
            return {ATTRS=function(_) end}
        end
        local mocks = {
            ['plugins.overlay']={OverlayWidget={}}, ['tile-material']={},
            ['gui']={ZScreen={}}, ['gui.widgets']={Window={}},
        }
        function require(name)
            assert(mocks[name], 'unexpected require: ' .. name)
            return mocks[name]
        end
    ''')
    module_loader = lua.eval('''function(path)
        local env = setmetatable({}, {__index=_G})
        assert(loadfile(path, 't', env))()
        return env
    end''')
    art = module_loader(str(MOD / 'stone-tint/art-vanilla.lua'))
    requests = []

    def reqscript(name):
        requests.append(name)
        if name == 'stone-tint/art-vanilla':
            return art
        if name in ('stone-tint/liveart', 'stone-tint/graphicsraws', 'stone-tint/imagedecode'):
            # These modules are not executed: no world is loaded.
            return lua.table()
        raise AssertionError(f'unexpected reqscript: {name}')

    lua.globals().reqscript = reqscript
    module = module_loader(str(MOD / 'stone-tint.lua'))
    assert requests.count('stone-tint/art-vanilla') == 1
    assert module.get_report()[0] is True
    assert module.get_state().blend == 'default'
    return lua, module, art
