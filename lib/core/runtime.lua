local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local C = PM._core
if type(C) ~= "table" then
    return
end

local as_int = C.as_int
local round_int = C.round_int or function(v)
    return math.floor((tonumber(v) or 0) + 0.5)
end
local ensure_player_name = C.ensure_player_name
local player_has_priv = C.player_has_priv
local player_has_plot_admin_road = C.player_has_plot_admin_road
local layout_info = C.layout_info
local id_from_cell = C.id_from_cell
local configured_pregenerate_plot_count = C.configured_pregenerate_plot_count
local pregenerate_plot_count = C.pregenerate_plot_count
local claim_order_for_limit = C.claim_order_for_limit
local pregen_signature = C.pregen_signature
local plot_grid_bounds_2d = C.plot_grid_bounds_2d

local function cleanup_invalid_players()
    local changed = false
    for owner, ids in pairs(PM.state.player_plots or {}) do
        if type(ids) == "table" then
            for i = #ids, 1, -1 do
                local id = as_int(ids[i], 0)
                local plot = PM.get_plot(id)
                if not plot or plot.owner ~= owner then
                    table.remove(ids, i)
                    changed = true
                end
            end
            if #ids <= 0 then
                PM.state.player_plots[owner] = nil
                changed = true
            end
        else
            PM.state.player_plots[owner] = nil
            changed = true
        end
    end
    if changed then
        PM.save_state()
    end
end

local function build_unowned_pregen_queue(limit, target)
    local queue = {}
    local queued = {}
    local layout = layout_info()
    local cols = math.max(1, as_int(layout.cols, 1))
    local rows = math.max(1, as_int(layout.rows, 1))
    local wanted = math.max(1, as_int(target, 1))

    -- First pass: compact centered square to keep pregen local around spawn/center.
    local side = math.max(1, math.ceil(math.sqrt(wanted)))
    if side > cols then
        side = cols
    end
    if side > rows then
        side = rows
    end
    local center_col = math.floor((cols - 1) * 0.5)
    local center_row = math.floor((rows - 1) * 0.5)
    local start_col = center_col - math.floor((side - 1) * 0.5)
    local start_row = center_row - math.floor((side - 1) * 0.5)
    if start_col < 0 then
        start_col = 0
    end
    if start_row < 0 then
        start_row = 0
    end
    if start_col + side > cols then
        start_col = cols - side
    end
    if start_row + side > rows then
        start_row = rows - side
    end

    for row = start_row, (start_row + side - 1) do
        for col = start_col, (start_col + side - 1) do
            if #queue >= wanted then
                break
            end
            local id = id_from_cell(col, row)
            if id and id <= limit and not PM.get_plot(id) and not queued[id] then
                queued[id] = true
                queue[#queue + 1] = id
            end
        end
        if #queue >= wanted then
            break
        end
    end

    -- Fallback: if centered square has claimed holes, backfill from nearest order.
    if #queue < wanted then
        for _, id in ipairs(claim_order_for_limit(limit)) do
            if #queue >= wanted then
                break
            end
            if not queued[id] and not PM.get_plot(id) then
                queued[id] = true
                queue[#queue + 1] = id
            end
        end
    end

    return queue
end

local function finish_unowned_pregen(signature, generated_count, total_slots)
    PM.runtime = PM.runtime or {}
    PM.runtime.pregen_queue = nil
    PM.runtime.pregen_index = nil
    PM.runtime.pregen_signature_target = nil
    PM.runtime.pregen_attempts = nil
    PM.runtime.pregen_target_count = nil
    PM.runtime.pregen_running = false
    PM.state.pregen_signature = signature
    PM.save_state()
    minetest.log(
        "action",
        "[plots] pre-generated " .. tostring(generated_count) .. " unowned cells (" .. tostring(total_slots) .. " total slots)."
    )
end

local function process_unowned_pregen_batch(max_batch_override)
    PM.runtime = PM.runtime or {}
    if PM.runtime.pregen_running ~= true then
        return
    end

    local queue = PM.runtime.pregen_queue
    if type(queue) ~= "table" then
        PM.runtime.pregen_running = false
        return
    end

    local idx = math.max(1, as_int(PM.runtime.pregen_index, 1))
    local per_step = math.max(1, as_int((PM.config or {}).pregenerate_batch_size, 16))
    if max_batch_override ~= nil then
        per_step = math.min(per_step, math.max(1, as_int(max_batch_override, 1)))
    end
    local processed = 0
    PM.runtime.pregen_attempts = PM.runtime.pregen_attempts or {}

    while processed < per_step and idx <= #queue do
        local id = queue[idx]
        local ok = PM.render_unowned_cell(id)
        if not ok and not PM.get_plot(id) then
            local attempts = as_int(PM.runtime.pregen_attempts[id], 0) + 1
            PM.runtime.pregen_attempts[id] = attempts
            if attempts < 3 then
                queue[#queue + 1] = id
            end
        end
        idx = idx + 1
        processed = processed + 1
    end

    PM.runtime.pregen_index = idx
    if idx > #queue then
        local generated = as_int(PM.runtime.pregen_target_count, 0)
        finish_unowned_pregen(
            tostring(PM.runtime.pregen_signature_target or pregen_signature()),
            generated,
            pregenerate_plot_count()
        )
    end
end

function PM.schedule_unowned_pregen(force)
    if type(PM.state) ~= "table" then
        return false
    end

    local signature = pregen_signature()
    PM.runtime = PM.runtime or {}
    if PM.runtime.pregen_running == true and tostring(PM.runtime.pregen_signature_target or "") == signature then
        return true
    end
    if force ~= true and tostring(PM.state.pregen_signature or "") == signature then
        return false
    end

    local limit = pregenerate_plot_count()
    local target = math.min(limit, configured_pregenerate_plot_count())
    local queue = build_unowned_pregen_queue(limit, target)
    PM.runtime.pregen_queue = queue
    PM.runtime.pregen_index = 1
    PM.runtime.pregen_signature_target = signature
    PM.runtime.pregen_attempts = {}
    PM.runtime.pregen_target_count = target
    PM.runtime.pregen_running = true

    if #queue <= 0 then
        finish_unowned_pregen(signature, 0, limit)
    else
        minetest.log("action", "[plots] queued unowned grid generation for " .. tostring(#queue) .. " cells.")
    end
    return true
end

function PM.install_protection_wrapper()
    local current = minetest.is_protected
    if current == PM._is_protected_wrapper_fn then
        return
    end

    local function has_protection_bypass(player_name)
        if player_name == "" then
            return false
        end
        return player_has_priv(player_name, "protection_bypass")
    end

    local function in_managed_plot_window(pos)
        return PM.in_plot_dimension(pos) and PM.in_plot_grid_area(pos)
    end

    local function normalize_node_pos(pos)
        if type(pos) ~= "table" then
            return nil
        end
        return {
            x = round_int(pos.x),
            y = round_int(pos.y),
            z = round_int(pos.z),
        }
    end

    local function is_claimed_border_node(pos)
        local p = normalize_node_pos(pos)
        if not p then
            return false
        end
        local node = minetest.get_node_or_nil(p)
        return node and node.name == "plots:claimed"
    end

    local function is_claimed_border_ring_xz(plot, x, z)
        if not plot then
            return false
        end
        local center = plot.center or {x = 0, y = 0, z = 0}
        local r = PM.plot_radius(plot)
        local dx = x - center.x
        local dz = z - center.z
        local shape = tostring(plot.shape or ((PM.config or {}).shape) or "square")

        if shape == "sphere" then
            local d2 = (dx * dx) + (dz * dz)
            local inner = math.max(1, r - 1)
            return d2 <= (r * r) and d2 >= (inner * inner)
        end

        local adx = math.abs(dx)
        local adz = math.abs(dz)
        if adx > r or adz > r then
            return false
        end
        return adx == r or adz == r
    end

    local function is_claimed_border_column_locked(pos)
        if type(pos) ~= "table" then
            return false
        end
        local p = normalize_node_pos(pos)
        if not p then
            return false
        end

        local cfg = PM.config or {}
        local origin = type(cfg.origin) == "table" and cfg.origin or {x = 0, y = 0, z = 0}
        local probe_y = as_int(origin.y, 0)
        local plot = PM.plot_at_pos({x = p.x, y = probe_y, z = p.z})
        if not plot then
            plot = PM.plot_at_pos({x = p.x, y = p.y, z = p.z})
        end
        if not plot then
            plot = PM.plot_at_pos({x = p.x, y = p.y - 1, z = p.z})
        end
        if not plot then
            return false
        end

        local surface_y = PM.plot_surface_y(plot)
        local floor_y = (plot.center or {y = 0}).y - math.max(8, as_int(cfg.build_depth, 32))
        if p.y < floor_y or p.y > (surface_y + 1) then
            return false
        end
        return is_claimed_border_ring_xz(plot, p.x, p.z)
    end

    local function is_or_above_claimed_border(pos)
        local p = normalize_node_pos(pos)
        if not p then
            return false
        end
        if is_claimed_border_node(p) then
            return true
        end
        local below = {
            x = p.x,
            y = p.y - 1,
            z = p.z,
        }
        return is_claimed_border_node(below) or is_claimed_border_column_locked(p)
    end

    PM._is_protected_base_fn = current
    PM._is_protected_wrapper_fn = function(pos, name)
        local pname = ensure_player_name(name)

        if in_managed_plot_window(pos) then
            if is_or_above_claimed_border(pos) then
                return true
            end
            if has_protection_bypass(pname) then
                return false
            end
            local plot = PM.plot_at_pos(pos)
            if plot and PM.can_player_build(plot, pname) then
                return false
            end
            if (not plot) and player_has_plot_admin_road(pname) and PM.is_road_pos(pos) then
                return false
            end
            return true
        end
        if has_protection_bypass(pname) then
            return false
        end
        return PM._is_protected_base_fn(pos, name)
    end
    minetest.is_protected = PM._is_protected_wrapper_fn

    if PM._border_place_guard_registered ~= true then
        PM._border_place_guard_registered = true
        minetest.register_on_placenode(function(pos, newnode, placer, oldnode, itemstack)
            local pname = ensure_player_name(placer)
            if pname == "" then
                return
            end
            if not in_managed_plot_window(pos) then
                return
            end
            if not is_or_above_claimed_border(pos) then
                return
            end

            if type(oldnode) == "table" and oldnode.name and oldnode.name ~= "" then
                minetest.set_node(pos, oldnode)
            else
                minetest.remove_node(pos)
            end

            if type(minetest.is_creative_enabled) == "function" and minetest.is_creative_enabled(pname) then
                return
            end

            local stack = ItemStack((newnode and newnode.name) or "")
            if stack:is_empty() then
                return
            end

            local remaining = stack
            if itemstack and type(itemstack.add_item) == "function" then
                remaining = itemstack:add_item(stack)
                if placer and placer.is_player and placer:is_player() then
                    placer:set_wielded_item(itemstack)
                end
            end

            if not remaining:is_empty() and placer and placer.is_player and placer:is_player() then
                local inv = placer:get_inventory()
                if inv and type(inv.add_item) == "function" then
                    remaining = inv:add_item("main", remaining)
                end
                if not remaining:is_empty() then
                    minetest.add_item(placer:get_pos(), remaining)
                end
            end
        end)
    end
end

PM.install_protection_wrapper()
minetest.register_on_mods_loaded(function()
    PM.install_protection_wrapper()
end)

do
    local cold_content_ids = {}
    for _, nodename in ipairs({
        "default:snow",
        "default:snowblock",
        "default:dirt_with_snow",
        "default:ice",
        "default:permafrost",
        "default:permafrost_with_stones",
        "default:permafrost_with_moss",
        "mapgen_snow",
        "mapgen_ice",
    }) do
        if minetest.registered_nodes[nodename] then
            cold_content_ids[minetest.get_content_id(nodename)] = true
        end
    end

    local function chunk_intersects_plot_window(minp, maxp)
        local dim = ((PM.config or {}).dimension) or {}
        local y_min = as_int(dim.y_min, -31000)
        local y_max = as_int(dim.y_max, 31000)
        if maxp.y < y_min or minp.y > y_max then
            return false
        end
        local bounds = plot_grid_bounds_2d()
        if not bounds then
            return false
        end
        return not (
            maxp.x < bounds.min_x or minp.x > bounds.max_x or
            maxp.z < bounds.min_z or minp.z > bounds.max_z
        )
    end

    local function strip_cold_nodes_in_chunk(area, data, minp, maxp, c_air)
        if next(cold_content_ids) == nil then
            return false
        end

        local dim = ((PM.config or {}).dimension) or {}
        local y_min = as_int(dim.y_min, -31000)
        local y_max = as_int(dim.y_max, 31000)
        local bounds = plot_grid_bounds_2d()
        if not bounds then
            return false
        end

        local x1 = math.max(minp.x, bounds.min_x)
        local z1 = math.max(minp.z, bounds.min_z)
        local x2 = math.min(maxp.x, bounds.max_x)
        local z2 = math.min(maxp.z, bounds.max_z)
        local surface_y = as_int(((PM.config or {}).origin or {}).y, 6000) + math.max(8, as_int((PM.config or {}).build_height, 96))
        local yy1 = math.max(minp.y, y_min, surface_y - 24)
        local yy2 = math.min(maxp.y, y_max, surface_y + 24)
        if x1 > x2 or z1 > z2 or yy1 > yy2 then
            return false
        end

        local changed = false
        local min_edge = area.MinEdge
        local ystride = area.ystride
        local zstride = area.zstride
        local xoff = x1 - min_edge.x
        local xlen = (x2 - x1) + 1

        for z = z1, z2 do
            local zoff = (z - min_edge.z) * zstride
            for y = yy1, yy2 do
                local vi = zoff + ((y - min_edge.y) * ystride) + xoff + 1
                for _ = 1, xlen do
                    if cold_content_ids[data[vi]] then
                        data[vi] = c_air
                        changed = true
                    end
                    vi = vi + 1
                end
            end
        end

        return changed
    end

    minetest.register_on_generated(function(minp, maxp, _seed)
        if not chunk_intersects_plot_window(minp, maxp) then
            return
        end

        local vm, emin, emax = minetest.get_mapgen_object("voxelmanip")
        if not vm then
            return
        end
        local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
        local data = vm:get_data()
        local c_air = minetest.get_content_id("air")
        if not strip_cold_nodes_in_chunk(area, data, minp, maxp, c_air) then
            return
        end

        vm:set_data(data)
        vm:write_to_map()
    end)
end

do
    PM.runtime = PM.runtime or {}
    PM.runtime.pregen_accum = 0
    minetest.register_globalstep(function(dtime)
        if PM.runtime.pregen_running ~= true then
            return
        end
        local online = #minetest.get_connected_players()
        local interval = online > 0 and 0.25 or 0.05
        PM.runtime.pregen_accum = (PM.runtime.pregen_accum or 0) + (tonumber(dtime) or 0)
        if PM.runtime.pregen_accum < interval then
            return
        end
        PM.runtime.pregen_accum = 0
        process_unowned_pregen_batch(online > 0 and 1 or nil)
    end)
end

do
    PM.runtime = PM.runtime or {}
    PM.runtime.deny_timer = 0
    minetest.register_globalstep(function(dtime)
        PM.runtime.deny_timer = (PM.runtime.deny_timer or 0) + (tonumber(dtime) or 0)
        local interval = math.max(0.2, tonumber((PM.config or {}).deny_check_interval) or 1.0)
        if PM.runtime.deny_timer < interval then
            return
        end
        PM.runtime.deny_timer = 0

        for _, player in ipairs(minetest.get_connected_players()) do
            local pname = player:get_player_name()
            local plot = PM.plot_at_pos(player:get_pos())
            if plot and not PM.can_player_visit(plot, pname) then
                PM.kick_player_from_plot(pname, plot, minetest.colorize("#ff7777", "You are denied from this plot."))
            end
        end
    end)
end

PM.apply_config()
PM.load_state()
cleanup_invalid_players()
PM.schedule_unowned_pregen(false)
