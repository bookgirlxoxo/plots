local MODPATH = minetest.get_modpath(minetest.get_current_modname())
local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    PM = {}
end
PM.modpath = MODPATH
PM.storage = PM.storage or minetest.get_mod_storage()
PM.formname_confirm = PM.formname_confirm or "plots:confirm"
rawset(_G, "plots_mod", PM)

if not minetest.registered_nodes["plots:void"] then
    minetest.register_node("plots:void", {
        description = "Plot Void Block",
        tiles = {"void.png"},
        groups = {unbreakable = 1, not_in_creative_inventory = 1},
        drop = "",
        can_dig = function()
            return false
        end,
        on_blast = function()
        end,
    })
end

for _, rel in ipairs({
    "lib/core.lua",
    "lib/commands.lua",
}) do
    dofile(MODPATH .. "/" .. rel)
end
