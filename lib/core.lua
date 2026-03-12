local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

for _, rel in ipairs({
    "lib/core/shared.lua",
    "lib/core/state.lua",
    "lib/core/terrain.lua",
    "lib/core/plots.lua",
    "lib/core/teleport.lua",
    "lib/core/runtime.lua",
}) do
    dofile(PM.modpath .. "/" .. rel)
end
