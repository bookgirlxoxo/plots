local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local C = PM._core
if type(C) ~= "table" then
    return
end

local PLOT_TP_GRACE_KEY = C.PLOT_TP_GRACE_KEY
local PLOT_TP_GRACE_SECONDS = C.PLOT_TP_GRACE_SECONDS

local now = C.now
local as_int = C.as_int
local center_for_plot_id = C.center_for_plot_id

local function is_blocking_node(pos)
    local node = minetest.get_node_or_nil(pos)
    if not node or node.name == "ignore" then
        return false
    end
    local def = minetest.registered_nodes[node.name]
    if not def then
        return false
    end
    if def.walkable == true then
        return true
    end
    return tostring(def.liquidtype or "none") ~= "none"
end

local function is_standable_node(pos)
    local node = minetest.get_node_or_nil(pos)
    if not node or node.name == "ignore" then
        return false
    end
    local def = minetest.registered_nodes[node.name]
    if not def then
        return false
    end
    if def.walkable ~= true then
        return false
    end
    return tostring(def.liquidtype or "none") == "none"
end

local function plot_spawn_candidates(plot)
    local center = plot.center or center_for_plot_id(plot.id)
    local floor_y = PM.plot_surface_y(plot)
    local radius = PM.plot_radius(plot)
    local edge_y = floor_y + 3
    local edge_offset = radius + 2
    local y = floor_y + 1
    return {
        {x = center.x, y = edge_y, z = center.z + radius},
        {x = center.x, y = y, z = center.z + edge_offset},
        {x = center.x + edge_offset, y = y, z = center.z},
        {x = center.x - edge_offset, y = y, z = center.z},
        {x = center.x, y = y, z = center.z - edge_offset},
        {x = center.x, y = y, z = center.z},
    }
end

local function safe_spawn_from_candidates(candidates)
    local list = type(candidates) == "table" and candidates or {}
    for _, pos in ipairs(list) do
        local base_y = as_int(pos.y, 0)
        for step = 0, 24 do
            local y = base_y + step
            local feet = {x = pos.x, y = y, z = pos.z}
            local head = {x = pos.x, y = y + 1, z = pos.z}
            local below = {x = pos.x, y = y - 1, z = pos.z}
            if (not is_blocking_node(feet))
                and (not is_blocking_node(head))
                and is_standable_node(below) then
                return {x = pos.x, y = y, z = pos.z}
            end
        end
    end

    local fallback = list[1] or {x = 0, y = 0, z = 0}
    local y = as_int(fallback.y, 0)
    for _ = 1, 24 do
        local feet = {x = fallback.x, y = y, z = fallback.z}
        local head = {x = fallback.x, y = y + 1, z = fallback.z}
        if (not is_blocking_node(feet)) and (not is_blocking_node(head)) then
            break
        end
        y = y + 1
    end
    return {x = fallback.x, y = y, z = fallback.z}
end

function PM.teleport_to_plot(player_or_name, plot, opts)
    local player = player_or_name
    if type(player_or_name) == "string" then
        player = minetest.get_player_by_name(player_or_name)
    end
    if not player or not player.is_player or not player:is_player() then
        return false, "Player not found."
    end
    if not plot then
        return false, "Plot not found."
    end

    local options = type(opts) == "table" and opts or {}
    if options.rebuild == true then
        local ok, err = PM.rebuild_plot(plot)
        if not ok then
            return false, "Failed to refresh plot terrain: " .. tostring(err or "unknown error")
        end
    end

    local candidates = plot_spawn_candidates(plot)
    if type(minetest.load_area) == "function" and #candidates > 0 then
        local minx = candidates[1].x
        local miny = candidates[1].y - 6
        local minz = candidates[1].z
        local maxx = candidates[1].x
        local maxy = candidates[1].y + 24
        local maxz = candidates[1].z
        for i = 2, #candidates do
            local c = candidates[i]
            if c.x < minx then minx = c.x end
            if c.y - 6 < miny then miny = c.y - 6 end
            if c.z < minz then minz = c.z end
            if c.x > maxx then maxx = c.x end
            if c.y + 24 > maxy then maxy = c.y + 24 end
            if c.z > maxz then maxz = c.z end
        end
        minetest.load_area(
            {x = minx - 8, y = miny, z = minz - 8},
            {x = maxx + 8, y = maxy, z = maxz + 8}
        )
    end

    local spawn_pos = safe_spawn_from_candidates(candidates)
    local meta = player:get_meta()
    if meta then
        meta:set_int(PLOT_TP_GRACE_KEY, now() + PLOT_TP_GRACE_SECONDS)
    end
    player:set_pos(spawn_pos)
    player:set_velocity({x = 0, y = 0, z = 0})
    return true
end
