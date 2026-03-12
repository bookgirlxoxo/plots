local MODPATH = minetest.get_modpath(minetest.get_current_modname())
local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    PM = {}
end
PM.modpath = MODPATH
PM.storage = PM.storage or minetest.get_mod_storage()
PM.formname_confirm = PM.formname_confirm or "plots:confirm"
rawset(_G, "plots_mod", PM)

local function register_locked_plot_node(name, description, texture)
    if minetest.registered_nodes[name] then
        return
    end
    minetest.register_node(name, {
        description = description,
        tiles = {texture},
        groups = {unbreakable = 1, not_in_creative_inventory = 1},
        pointable = false,
        drop = "",
        can_dig = function()
            return false
        end,
        on_blast = function()
        end,
    })
end

register_locked_plot_node("plots:claimed", "Claimed Plot Border", "claimed.png")
register_locked_plot_node("plots:unclaimed", "Unclaimed Plot Border", "unclaimed.png")

for _, rel in ipairs({
    "lib/core.lua",
    "lib/commands.lua",
}) do
    dofile(MODPATH .. "/" .. rel)
end
