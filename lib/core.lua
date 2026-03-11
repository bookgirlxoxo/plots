local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local SAVE_KEY = "plots_state"
local PLOT_LAYOUT_REV = 3
local PLOT_TP_GRACE_KEY = "plots:tp_grace_until"
local PLOT_TP_GRACE_SECONDS = 20

local function now()
    return os.time()
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function as_int(v, minv)
    local n = math.floor(tonumber(v) or 0)
    if minv and n < minv then
        return minv
    end
    return n
end

local function copy_vec3(v, fallback)
    local src = type(v) == "table" and v or (fallback or {})
    return {
        x = as_int(src.x, 0),
        y = as_int(src.y, 0),
        z = as_int(src.z, 0),
    }
end

local function ensure_player_name(player_or_name)
    if type(player_or_name) == "string" then
        return trim(player_or_name)
    end
    if player_or_name and player_or_name.is_player and player_or_name:is_player() then
        return player_or_name:get_player_name()
    end
    return ""
end

local function ensure_access_table(raw)
    local out = {}
    for name, enabled in pairs(type(raw) == "table" and raw or {}) do
        local pname = trim(name)
        if pname ~= "" and enabled == true then
            out[pname] = true
        end
    end
    return out
end

local function sanitize_shape(raw, fallback)
    local shape = trim(raw):lower()
    if shape == "sphere" then
        return "sphere"
    end
    if shape == "square" then
        return "square"
    end
    return fallback or "square"
end

local function read_text(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, err
    end
    local body = file:read("*a")
    file:close()
    return body
end

local function load_config()
    local path = tostring(PM.modpath or "") .. "/data/config.json"
    local body = read_text(path)
    if not body or body == "" then
        return {}
    end
    local decoded = minetest.parse_json(body)
    if type(decoded) ~= "table" then
        minetest.log("warning", "[plots] invalid JSON in data/config.json")
        return {}
    end
    return decoded
end

function PM.apply_config()
    local cfg = load_config()
    local origin = copy_vec3(cfg.origin, {x = 4000, y = 6000, z = 4000})
    local build_height = math.max(8, as_int(cfg.build_height, 96))
    local build_depth = math.max(8, as_int(cfg.build_depth, 32))
    local dim = type(cfg.dimension) == "table" and cfg.dimension or {}
    local spawn_cfg = type(cfg.spawn) == "table" and cfg.spawn or {}
    local default_spawn = {
        x = origin.x,
        y = origin.y + build_height + 2,
        z = origin.z,
    }
    local spawn = copy_vec3(spawn_cfg, default_spawn)
    local dim_min = as_int(dim.y_min, origin.y - build_depth - 128)
    local dim_max = as_int(dim.y_max, origin.y + (build_height * 2) + 256)
    if dim_min > dim_max then
        dim_min, dim_max = dim_max, dim_min
    end
    PM.config = {
        max_plots_per_player = math.max(1, as_int(cfg.max_plots_per_player, 1)),
        plot_size = math.max(8, as_int(cfg.plot_size, 48)),
        plot_gap = math.max(2, as_int(cfg.plot_gap, 14)),
        shape = sanitize_shape(cfg.shape, "square"),
        grid_columns = math.max(1, as_int(cfg.grid_columns, 64)),
        origin = origin,
        spawn = spawn,
        dimension = {
            y_min = dim_min,
            y_max = dim_max,
        },
        build_height = build_height,
        build_depth = build_depth,
        floor_node = trim(cfg.floor_node) ~= "" and trim(cfg.floor_node) or "default:stone",
        wall_node = trim(cfg.wall_node) ~= "" and trim(cfg.wall_node) or "plots:void",
        terrain_top_node = trim(cfg.terrain_top_node) ~= "" and trim(cfg.terrain_top_node) or "default:dirt_with_grass",
        terrain_dirt_node = trim(cfg.terrain_dirt_node) ~= "" and trim(cfg.terrain_dirt_node) or "default:dirt",
        terrain_stone_node = trim(cfg.terrain_stone_node) ~= "" and trim(cfg.terrain_stone_node) or "default:stone",
        terrain_grass_plant_chance = math.max(0, math.min(1, tonumber(cfg.terrain_grass_plant_chance) or 0.13)),
        border_enabled = cfg.border_enabled ~= false,
        confirm_ttl_seconds = math.max(10, as_int(cfg.confirm_ttl_seconds, 45)),
        deny_check_interval = math.max(0.2, tonumber(cfg.deny_check_interval) or 1.0),
    }
end

local function sanitize_plot(raw, fallback_shape, fallback_id)
    local src = type(raw) == "table" and raw or {}
    local id = as_int(src.id, as_int(fallback_id, 0))
    local owner = trim(src.owner)
    if id <= 0 or owner == "" then
        return nil
    end
    local size = math.max(8, as_int(src.size, 48))
    local center = copy_vec3(src.center, {x = 0, y = 10, z = 0})
    local cfg = PM.config or {}
    local dim = type(cfg.dimension) == "table" and cfg.dimension or {}
    local y_min = as_int(dim.y_min, -31000)
    local y_max = as_int(dim.y_max, 31000)
    if center.y < y_min or center.y > y_max then
        center.y = as_int(((cfg.origin or {}).y), 6000)
    end
    return {
        id = id,
        owner = owner,
        center = center,
        size = size,
        shape = sanitize_shape(src.shape, fallback_shape),
        layout_rev = math.max(1, as_int(src.layout_rev, 1)),
        created_at = as_int(src.created_at, 0),
        add = ensure_access_table(src.add),
        trust = ensure_access_table(src.trust),
        deny = ensure_access_table(src.deny),
    }
end

local function insert_owner_plot(player_plots, owner, id)
    local row = player_plots[owner]
    if type(row) ~= "table" then
        row = {}
        player_plots[owner] = row
    end
    row[#row + 1] = id
end

local function sort_owner_plot_rows(player_plots)
    for _, row in pairs(player_plots) do
        table.sort(row, function(a, b)
            return (tonumber(a) or 0) < (tonumber(b) or 0)
        end)
    end
end

local function sanitize_state(raw)
    local src = type(raw) == "table" and raw or {}
    local out = {
        next_id = math.max(1, as_int(src.next_id, 1)),
        plots = {},
        player_plots = {},
    }

    local fallback_shape = ((PM.config or {}).shape) or "square"
    for key, row in pairs(type(src.plots) == "table" and src.plots or {}) do
        local key_id = as_int(key, 0)
        local parsed = sanitize_plot(row, fallback_shape, key_id)
        if parsed then
            local id = as_int(parsed.id, 1)
            local id_key = tostring(id)
            out.plots[id_key] = parsed
            insert_owner_plot(out.player_plots, parsed.owner, id)
            if id >= out.next_id then
                out.next_id = id + 1
            end
        end
    end

    sort_owner_plot_rows(out.player_plots)
    return out
end

function PM.save_state()
    if not PM.storage then
        return false
    end
    PM.storage:set_string(SAVE_KEY, minetest.serialize(PM.state or {}))
    return true
end

function PM.load_state()
    local decoded = nil
    if PM.storage then
        local raw = PM.storage:get_string(SAVE_KEY)
        if raw and raw ~= "" then
            decoded = minetest.deserialize(raw)
        end
    end
    PM.state = sanitize_state(decoded)
    PM.save_state()
end

local function plot_spacing()
    return math.max(10, as_int((PM.config or {}).plot_size, 48) + as_int((PM.config or {}).plot_gap, 14) + 2)
end

local function center_for_plot_id(id)
    local cfg = PM.config or {}
    local spacing = plot_spacing()
    local col_count = math.max(1, as_int(cfg.grid_columns, 64))
    local idx = math.max(1, as_int(id, 1)) - 1
    local col = idx % col_count
    local row = math.floor(idx / col_count)
    local origin = cfg.origin or {x = 4000, y = 6000, z = 4000}
    return {
        x = as_int(origin.x, 4000) + (col * spacing),
        y = as_int(origin.y, 6000),
        z = as_int(origin.z, 4000) + (row * spacing),
    }
end

local function normalize_access(plot)
    plot.add = ensure_access_table(plot.add)
    plot.trust = ensure_access_table(plot.trust)
    plot.deny = ensure_access_table(plot.deny)
end

function PM.get_plot(plot_id)
    local id = as_int(plot_id, 0)
    if id <= 0 then
        return nil
    end
    return (PM.state.plots or {})[tostring(id)]
end

function PM.owned_plot_ids(owner_name)
    local owner = ensure_player_name(owner_name)
    local row = (PM.state.player_plots or {})[owner]
    if type(row) ~= "table" then
        return {}
    end
    local out = {}
    for i, id in ipairs(row) do
        out[i] = as_int(id, 0)
    end
    table.sort(out)
    return out
end

function PM.get_plot_by_owner_index(owner_name, index)
    local ids = PM.owned_plot_ids(owner_name)
    local idx = math.max(1, as_int(index, 1))
    local id = ids[idx]
    if not id then
        return nil
    end
    return PM.get_plot(id)
end

function PM.plot_radius(plot)
    local size = math.max(8, as_int(plot and plot.size, (PM.config or {}).plot_size or 48))
    return math.max(4, math.floor(size * 0.5))
end

function PM.plot_bounds(plot)
    local center = (plot and plot.center) or {x = 0, y = 0, z = 0}
    local radius = PM.plot_radius(plot)
    local cfg = PM.config or {}
    local base_y = as_int(center.y, 12)
    local min_y = base_y - math.max(8, as_int(cfg.build_depth, 32))
    local max_y = PM.plot_ceiling_y(plot)
    return {
        min = {
            x = center.x - radius - 1,
            y = min_y,
            z = center.z - radius - 1,
        },
        max = {
            x = center.x + radius + 1,
            y = max_y,
            z = center.z + radius + 1,
        },
    }
end

local function plot_layout_rev(plot)
    return math.max(1, as_int(plot and plot.layout_rev, 1))
end

local function is_legacy_layout(plot)
    return plot_layout_rev(plot) < PLOT_LAYOUT_REV
end

local function mark_layout_current(plot)
    if type(plot) == "table" then
        plot.layout_rev = PLOT_LAYOUT_REV
    end
end

function PM.plot_surface_y(plot)
    local center = (plot and plot.center) or {x = 0, y = 0, z = 0}
    local cfg = PM.config or {}
    local build_h = math.max(8, as_int(cfg.build_height, 96))
    return center.y + build_h
end

function PM.plot_ceiling_y(plot)
    local cfg = PM.config or {}
    local build_h = math.max(8, as_int(cfg.build_height, 96))
    return PM.plot_surface_y(plot) + build_h
end

local function pos_in_plot_shape(plot, pos)
    if not plot or type(pos) ~= "table" then
        return false
    end
    local center = plot.center or {x = 0, y = 0, z = 0}
    local radius = PM.plot_radius(plot)
    local cfg = PM.config or {}
    local min_y = center.y - math.max(8, as_int(cfg.build_depth, 32))
    local max_y = PM.plot_ceiling_y(plot)
    if pos.y < min_y or pos.y > max_y then
        return false
    end
    local dx = pos.x - center.x
    local dz = pos.z - center.z
    if sanitize_shape(plot.shape, cfg.shape) == "sphere" then
        return ((dx * dx) + (dz * dz)) <= (radius * radius)
    end
    return math.abs(dx) <= radius and math.abs(dz) <= radius
end

local function id_from_cell(col, row)
    local cfg = PM.config or {}
    local cols = math.max(1, as_int(cfg.grid_columns, 64))
    if col < 0 or row < 0 then
        return nil
    end
    return (row * cols) + col + 1
end

local function cell_from_pos(pos)
    local cfg = PM.config or {}
    local origin = cfg.origin or {x = 4000, y = 6000, z = 4000}
    local spacing = plot_spacing()
    local xf = (pos.x - origin.x) / spacing
    local zf = (pos.z - origin.z) / spacing
    return math.floor(xf), math.floor(zf)
end

function PM.plot_at_pos(pos)
    if type(pos) ~= "table" then
        return nil
    end
    local base_col, base_row = cell_from_pos(pos)
    for row = base_row - 1, base_row + 1 do
        for col = base_col - 1, base_col + 1 do
            local id = id_from_cell(col, row)
            local plot = id and PM.get_plot(id) or nil
            if plot and pos_in_plot_shape(plot, pos) then
                return plot
            end
        end
    end
    return nil
end

function PM.plot_for_player(player_or_name)
    local player = player_or_name
    if type(player_or_name) == "string" then
        player = minetest.get_player_by_name(player_or_name)
    end
    if not player or not player.is_player or not player:is_player() then
        return nil
    end
    return PM.plot_at_pos(player:get_pos())
end

function PM.can_player_visit(plot, player_or_name)
    local pname = ensure_player_name(player_or_name)
    if not plot or pname == "" then
        return false
    end
    if pname == plot.owner then
        return true
    end
    return not ((plot.deny or {})[pname] == true)
end

local function owner_is_on_plot(plot)
    local owner = plot and plot.owner or ""
    if owner == "" then
        return false
    end
    local player = minetest.get_player_by_name(owner)
    if not player then
        return false
    end
    return pos_in_plot_shape(plot, player:get_pos())
end

function PM.can_player_build(plot, player_or_name)
    local pname = ensure_player_name(player_or_name)
    if not plot or pname == "" then
        return false
    end
    if not PM.can_player_visit(plot, pname) then
        return false
    end
    if pname == plot.owner then
        return true
    end
    if (plot.trust or {})[pname] == true then
        return true
    end
    if (plot.add or {})[pname] == true and owner_is_on_plot(plot) then
        return true
    end
    return false
end

function PM.get_plot_spawn_pos()
    local cfg = PM.config or {}
    local spawn = type(cfg.spawn) == "table" and cfg.spawn or {}
    local origin = type(cfg.origin) == "table" and cfg.origin or {x = 4000, y = 6000, z = 4000}
    return {
        x = as_int(spawn.x, as_int(origin.x, 4000)),
        y = as_int(spawn.y, as_int(origin.y, 6000) + 2),
        z = as_int(spawn.z, as_int(origin.z, 4000)),
    }
end

function PM.in_plot_dimension(pos)
    if type(pos) ~= "table" then
        return false
    end
    local dim = ((PM.config or {}).dimension) or {}
    local y_min = as_int(dim.y_min, -31000)
    local y_max = as_int(dim.y_max, 31000)
    return pos.y >= y_min and pos.y <= y_max
end

local function get_content_id(name, fallback)
    local node = trim(name)
    if node == "" or not minetest.registered_nodes[node] then
        node = fallback
    end
    return minetest.get_content_id(node)
end

local function fill_box(area, data, minp, maxp, cid, read_min, read_max)
    local minx = math.max(minp.x, read_min.x)
    local miny = math.max(minp.y, read_min.y)
    local minz = math.max(minp.z, read_min.z)
    local maxx = math.min(maxp.x, read_max.x)
    local maxy = math.min(maxp.y, read_max.y)
    local maxz = math.min(maxp.z, read_max.z)
    if minx > maxx or miny > maxy or minz > maxz then
        return
    end
    for z = minz, maxz do
        for y = miny, maxy do
            local vi = area:index(minx, y, z)
            for _ = minx, maxx do
                data[vi] = cid
                vi = vi + 1
            end
        end
    end
end

local function write_vm_with_lighting(vm, minp, maxp)
    if type(vm.calc_lighting) == "function" then
        if type(minp) == "table" and type(maxp) == "table" then
            vm:calc_lighting(minp, maxp)
        else
            vm:calc_lighting()
        end
    end
    vm:write_to_map()
    if type(vm.update_liquids) == "function" then
        vm:update_liquids()
    end
    if type(minetest.fix_light) == "function" and type(minp) == "table" and type(maxp) == "table" then
        minetest.fix_light(minp, maxp)
    end
end

local function rebuild_read_bounds(plot)
    local bounds = PM.plot_bounds(plot)
    local cfg = PM.config or {}
    local gap = math.max(2, as_int(cfg.plot_gap, 14))
    local pad = math.max(1, math.floor(gap * 0.5))
    return {
        min = {
            x = bounds.min.x - pad,
            y = bounds.min.y,
            z = bounds.min.z - pad,
        },
        max = {
            x = bounds.max.x + pad,
            y = bounds.max.y,
            z = bounds.max.z + pad,
        },
    }
end

local function clear_plot_neighborhood(plot, area, data, read_min, read_max)
    local bounds = PM.plot_bounds(plot)
    local cfg = PM.config or {}
    local gap = math.max(2, as_int(cfg.plot_gap, 14))
    local pad = math.max(1, math.floor(gap * 0.5))
    local c_air = minetest.get_content_id("air")
    fill_box(
        area,
        data,
        {x = bounds.min.x - pad, y = bounds.min.y, z = bounds.min.z - pad},
        {x = bounds.max.x + pad, y = bounds.max.y, z = bounds.max.z + pad},
        c_air,
        read_min,
        read_max
    )
end

local function regen_square_plot(plot, vm, area, data, read_min, read_max)
    local cfg = PM.config or {}
    local center = plot.center
    local r = PM.plot_radius(plot)
    local ground_y = PM.plot_surface_y(plot)
    local dirt_low_y = ground_y - 6
    local stone_top_y = ground_y - 7
    local min_y = center.y - math.max(8, as_int(cfg.build_depth, 32))
    local top_y = PM.plot_ceiling_y(plot)
    local wall_top_y = ground_y
    local c_air = minetest.get_content_id("air")
    local c_top = get_content_id(cfg.terrain_top_node, "default:dirt_with_grass")
    local c_dirt = get_content_id(cfg.terrain_dirt_node, "default:dirt")
    local c_stone = get_content_id(cfg.terrain_stone_node, "default:stone")
    local c_wall = minetest.get_content_id("plots:void")

    fill_box(area, data,
        {x = center.x - r, y = ground_y + 1, z = center.z - r},
        {x = center.x + r, y = top_y, z = center.z + r},
        c_air,
        read_min, read_max
    )
    fill_box(area, data,
        {x = center.x - r, y = ground_y, z = center.z - r},
        {x = center.x + r, y = ground_y, z = center.z + r},
        c_top,
        read_min, read_max
    )
    fill_box(area, data,
        {x = center.x - r, y = dirt_low_y, z = center.z - r},
        {x = center.x + r, y = ground_y - 1, z = center.z + r},
        c_dirt,
        read_min, read_max
    )
    fill_box(area, data,
        {x = center.x - r, y = min_y, z = center.z - r},
        {x = center.x + r, y = stone_top_y, z = center.z + r},
        c_stone,
        read_min, read_max
    )
    fill_box(area, data,
        {x = center.x - r, y = min_y, z = center.z - r},
        {x = center.x + r, y = min_y, z = center.z + r},
        c_wall,
        read_min, read_max
    )

    if cfg.border_enabled then
        fill_box(area, data,
            {x = center.x - r, y = min_y, z = center.z - r},
            {x = center.x - r, y = wall_top_y, z = center.z + r},
            c_wall,
            read_min, read_max
        )
        fill_box(area, data,
            {x = center.x + r, y = min_y, z = center.z - r},
            {x = center.x + r, y = wall_top_y, z = center.z + r},
            c_wall,
            read_min, read_max
        )
        fill_box(area, data,
            {x = center.x - r, y = min_y, z = center.z - r},
            {x = center.x + r, y = wall_top_y, z = center.z - r},
            c_wall,
            read_min, read_max
        )
        fill_box(area, data,
            {x = center.x - r, y = min_y, z = center.z + r},
            {x = center.x + r, y = wall_top_y, z = center.z + r},
            c_wall,
            read_min, read_max
        )
    end

    local grass_ids = {}
    for i = 1, 5 do
        local name = "default:grass_" .. tostring(i)
        if minetest.registered_nodes[name] then
            grass_ids[#grass_ids + 1] = minetest.get_content_id(name)
        end
    end
    if #grass_ids > 0 and ground_y + 1 >= read_min.y and ground_y + 1 <= read_max.y then
        local chance = math.max(0, math.min(1, tonumber(cfg.terrain_grass_plant_chance) or 0.13))
        for z = math.max(center.z - r + 1, read_min.z), math.min(center.z + r - 1, read_max.z) do
            for x = math.max(center.x - r + 1, read_min.x), math.min(center.x + r - 1, read_max.x) do
                if math.random() < chance then
                    local top_i = area:index(x, ground_y, z)
                    local plant_i = area:index(x, ground_y + 1, z)
                    if data[top_i] == c_top and data[plant_i] == c_air then
                        data[plant_i] = grass_ids[math.random(1, #grass_ids)]
                    end
                end
            end
        end
    end
end

local function regen_sphere_plot(plot, vm, area, data, read_min, read_max)
    local cfg = PM.config or {}
    local center = plot.center
    local r = PM.plot_radius(plot)
    local rr = r * r
    local edge_r = math.max(0, r - 1)
    local edge_rr = edge_r * edge_r
    local ground_y = PM.plot_surface_y(plot)
    local dirt_low_y = ground_y - 6
    local stone_top_y = ground_y - 7
    local min_y = center.y - math.max(8, as_int(cfg.build_depth, 32))
    local top_y = PM.plot_ceiling_y(plot)
    local c_air = minetest.get_content_id("air")
    local c_top = get_content_id(cfg.terrain_top_node, "default:dirt_with_grass")
    local c_dirt = get_content_id(cfg.terrain_dirt_node, "default:dirt")
    local c_stone = get_content_id(cfg.terrain_stone_node, "default:stone")
    local c_wall = minetest.get_content_id("plots:void")
    local grass_ids = {}
    for i = 1, 5 do
        local name = "default:grass_" .. tostring(i)
        if minetest.registered_nodes[name] then
            grass_ids[#grass_ids + 1] = minetest.get_content_id(name)
        end
    end
    local grass_chance = math.max(0, math.min(1, tonumber(cfg.terrain_grass_plant_chance) or 0.13))

    local minx = math.max(center.x - r, read_min.x)
    local maxx = math.min(center.x + r, read_max.x)
    local minz = math.max(center.z - r, read_min.z)
    local maxz = math.min(center.z + r, read_max.z)
    for z = minz, maxz do
        local dz = z - center.z
        for x = minx, maxx do
            local dx = x - center.x
            local dist2 = (dx * dx) + (dz * dz)
            if dist2 <= rr then
                if stone_top_y >= min_y then
                    local y1 = math.max(min_y, read_min.y)
                    local y2 = math.min(stone_top_y, read_max.y)
                    if y1 <= y2 then
                        for y = y1, y2 do
                            data[area:index(x, y, z)] = c_stone
                        end
                    end
                end
                do
                    local y1 = math.max(dirt_low_y, read_min.y)
                    local y2 = math.min(ground_y - 1, read_max.y)
                    if y1 <= y2 then
                        for y = y1, y2 do
                            data[area:index(x, y, z)] = c_dirt
                        end
                    end
                end
                if ground_y >= read_min.y and ground_y <= read_max.y then
                    data[area:index(x, ground_y, z)] = c_top
                end
                local y1 = math.max(ground_y + 1, read_min.y)
                local y2 = math.min(top_y, read_max.y)
                if y1 <= y2 then
                    for y = y1, y2 do
                        data[area:index(x, y, z)] = c_air
                    end
                end
                if min_y >= read_min.y and min_y <= read_max.y then
                    data[area:index(x, min_y, z)] = c_wall
                end
                if cfg.border_enabled and dist2 >= edge_rr then
                    local wy1 = math.max(min_y, read_min.y)
                    local wy2 = math.min(ground_y, read_max.y)
                    if wy1 <= wy2 then
                        for y = wy1, wy2 do
                            data[area:index(x, y, z)] = c_wall
                        end
                    end
                elseif #grass_ids > 0 and ground_y + 1 >= read_min.y and ground_y + 1 <= read_max.y then
                    if dist2 < edge_rr and math.random() < grass_chance then
                        local plant_i = area:index(x, ground_y + 1, z)
                        if data[plant_i] == c_air then
                            data[plant_i] = grass_ids[math.random(1, #grass_ids)]
                        end
                    end
                end
            end
        end
    end
end

function PM.rebuild_plot(plot)
    if not plot then
        return false, "Plot not found."
    end
    normalize_access(plot)
    local bounds = rebuild_read_bounds(plot)
    local vm = VoxelManip()
    local read_min, read_max = vm:read_from_map(bounds.min, bounds.max)
    local area = VoxelArea:new({MinEdge = read_min, MaxEdge = read_max})
    local data = vm:get_data()
    clear_plot_neighborhood(plot, area, data, read_min, read_max)
    if sanitize_shape(plot.shape, (PM.config or {}).shape) == "sphere" then
        regen_sphere_plot(plot, vm, area, data, read_min, read_max)
    else
        regen_square_plot(plot, vm, area, data, read_min, read_max)
    end
    vm:set_data(data)
    write_vm_with_lighting(vm, read_min, read_max)
    mark_layout_current(plot)
    return true
end

function PM.rebuild_plot_async(plot, done_cb)
    if not plot then
        if done_cb then
            done_cb(false, "Plot not found.")
        end
        return false
    end

    local function finish()
        local ok, err = PM.rebuild_plot(plot)
        if done_cb then
            done_cb(ok, err)
        end
    end

    if minetest.emerge_area then
        local bounds = rebuild_read_bounds(plot)
        minetest.emerge_area(bounds.min, bounds.max, function(_, _, remaining)
            if remaining == 0 then
                finish()
            end
        end)
    else
        finish()
    end
    return true
end

local function wipe_square_plot(plot, vm, area, data, read_min, read_max)
    local center = plot.center
    local r = PM.plot_radius(plot)
    local top_y = PM.plot_ceiling_y(plot)
    local floor_y = center.y - math.max(8, as_int((PM.config or {}).build_depth, 32))
    local c_air = minetest.get_content_id("air")
    fill_box(area, data,
        {x = center.x - r, y = floor_y, z = center.z - r},
        {x = center.x + r, y = top_y, z = center.z + r},
        c_air,
        read_min, read_max
    )
end

local function wipe_sphere_plot(plot, vm, area, data, read_min, read_max)
    local center = plot.center
    local r = PM.plot_radius(plot)
    local rr = r * r
    local top_y = PM.plot_ceiling_y(plot)
    local floor_y = center.y - math.max(8, as_int((PM.config or {}).build_depth, 32))
    local c_air = minetest.get_content_id("air")

    local minx = math.max(center.x - r, read_min.x)
    local maxx = math.min(center.x + r, read_max.x)
    local minz = math.max(center.z - r, read_min.z)
    local maxz = math.min(center.z + r, read_max.z)
    local y1 = math.max(floor_y, read_min.y)
    local y2 = math.min(top_y, read_max.y)
    for z = minz, maxz do
        local dz = z - center.z
        for x = minx, maxx do
            local dx = x - center.x
            if ((dx * dx) + (dz * dz)) <= rr then
                for y = y1, y2 do
                    data[area:index(x, y, z)] = c_air
                end
            end
        end
    end
end

function PM.wipe_plot(plot)
    if not plot then
        return false, "Plot not found."
    end
    local bounds = PM.plot_bounds(plot)
    local vm = VoxelManip()
    local read_min, read_max = vm:read_from_map(bounds.min, bounds.max)
    local area = VoxelArea:new({MinEdge = read_min, MaxEdge = read_max})
    local data = vm:get_data()
    if sanitize_shape(plot.shape, (PM.config or {}).shape) == "sphere" then
        wipe_sphere_plot(plot, vm, area, data, read_min, read_max)
    else
        wipe_square_plot(plot, vm, area, data, read_min, read_max)
    end
    vm:set_data(data)
    write_vm_with_lighting(vm, read_min, read_max)
    return true
end

local function save_plot_ref(owner, id)
    local row = PM.state.player_plots[owner]
    if type(row) ~= "table" then
        row = {}
        PM.state.player_plots[owner] = row
    end
    for _, existing in ipairs(row) do
        if as_int(existing, 0) == id then
            return
        end
    end
    row[#row + 1] = id
    table.sort(row)
end

local function remove_plot_ref(owner, id)
    local row = PM.state.player_plots[owner]
    if type(row) ~= "table" then
        return
    end
    for i = #row, 1, -1 do
        if as_int(row[i], 0) == id then
            table.remove(row, i)
        end
    end
    if #row <= 0 then
        PM.state.player_plots[owner] = nil
    end
end

function PM.create_plot(owner_name)
    local owner = ensure_player_name(owner_name)
    if owner == "" then
        return false, "Invalid owner."
    end
    local ids = PM.owned_plot_ids(owner)
    if #ids >= math.max(1, as_int((PM.config or {}).max_plots_per_player, 1)) then
        return false, "Plot limit reached (" .. tostring((PM.config or {}).max_plots_per_player or 1) .. ")."
    end

    local id = math.max(1, as_int(PM.state.next_id, 1))
    while PM.state.plots[tostring(id)] do
        id = id + 1
    end

    local plot = {
        id = id,
        owner = owner,
        center = center_for_plot_id(id),
        size = math.max(8, as_int((PM.config or {}).plot_size, 48)),
        shape = sanitize_shape((PM.config or {}).shape, "square"),
        layout_rev = PLOT_LAYOUT_REV,
        created_at = now(),
        add = {},
        trust = {},
        deny = {},
    }
    PM.state.plots[tostring(id)] = plot
    PM.state.next_id = id + 1
    save_plot_ref(owner, id)
    PM.save_state()
    return true, "Created plot #" .. tostring(id) .. ".", plot
end

function PM.clear_plot(plot_or_id)
    local plot = type(plot_or_id) == "table" and plot_or_id or PM.get_plot(plot_or_id)
    if not plot then
        return false, "Plot not found."
    end
    local ok, err = PM.rebuild_plot(plot)
    if not ok then
        return false, "Failed to clear plot: " .. tostring(err or "unknown error")
    end
    PM.save_state()
    return true, "Plot #" .. tostring(plot.id) .. " cleared."
end

function PM.delete_plot(plot_or_id)
    local plot = type(plot_or_id) == "table" and plot_or_id or PM.get_plot(plot_or_id)
    if not plot then
        return false, "Plot not found."
    end

    local id = as_int(plot.id, 0)
    if id <= 0 then
        return false, "Invalid plot id."
    end

    PM.wipe_plot(plot)
    PM.state.plots[tostring(id)] = nil
    remove_plot_ref(plot.owner, id)
    PM.save_state()
    return true, "Deleted plot #" .. tostring(id) .. "."
end

function PM.set_access(plot, mode, target_name, enabled)
    if not plot then
        return false, "Plot not found."
    end
    local mode_key = tostring(mode or "")
    if mode_key ~= "add" and mode_key ~= "trust" and mode_key ~= "deny" then
        return false, "Invalid access mode."
    end
    local target = ensure_player_name(target_name)
    if target == "" then
        return false, "Invalid player."
    end
    if target == plot.owner then
        return false, "You cannot target the plot owner."
    end
    normalize_access(plot)
    local on = enabled == true
    if mode_key == "add" then
        if on then
            plot.add[target] = true
            plot.trust[target] = nil
            plot.deny[target] = nil
        else
            plot.add[target] = nil
        end
    elseif mode_key == "trust" then
        if on then
            plot.trust[target] = true
            plot.add[target] = nil
            plot.deny[target] = nil
        else
            plot.trust[target] = nil
        end
    elseif mode_key == "deny" then
        if on then
            plot.deny[target] = true
            plot.add[target] = nil
            plot.trust[target] = nil
        else
            plot.deny[target] = nil
        end
    end
    PM.save_state()
    return true
end

local function safe_spawn_for_kick(player)
    local spawn = PM.get_plot_spawn_pos()
    local floor_node = ((PM.config or {}).floor_node) or "air"
    for dx = -1, 1 do
        for dz = -1, 1 do
            minetest.set_node({x = spawn.x + dx, y = spawn.y - 1, z = spawn.z + dz}, {name = floor_node})
            minetest.set_node({x = spawn.x + dx, y = spawn.y, z = spawn.z + dz}, {name = "air"})
            minetest.set_node({x = spawn.x + dx, y = spawn.y + 1, z = spawn.z + dz}, {name = "air"})
        end
    end
    player:set_pos(spawn)
end

function PM.kick_player_from_plot(target_name, source_plot, reason)
    local target = minetest.get_player_by_name(ensure_player_name(target_name))
    if not target then
        return false
    end
    local pos = target:get_pos()
    if source_plot and not pos_in_plot_shape(source_plot, pos) then
        return false
    end
    safe_spawn_for_kick(target)
    local msg = trim(reason)
    if msg ~= "" then
        minetest.chat_send_player(target:get_player_name(), msg)
    end
    return true
end

local function resolve_plot_floor_node()
    local floor_node = trim((PM.config or {}).terrain_top_node)
    if floor_node == "" or not minetest.registered_nodes[floor_node] then
        floor_node = trim((PM.config or {}).floor_node)
    end
    if floor_node == "" or not minetest.registered_nodes[floor_node] then
        floor_node = "default:stone"
    end
    return floor_node
end

local function prepare_plot_spawn(plot)
    local center = plot.center
    local floor_y = PM.plot_surface_y(plot)
    local floor_node = resolve_plot_floor_node()
    for dz = -1, 1 do
        for dx = -1, 1 do
            minetest.set_node({x = center.x + dx, y = floor_y, z = center.z + dz}, {name = floor_node})
            minetest.set_node({x = center.x + dx, y = floor_y + 1, z = center.z + dz}, {name = "air"})
            minetest.set_node({x = center.x + dx, y = floor_y + 2, z = center.z + dz}, {name = "air"})
        end
    end
end

local function node_def_at(pos)
    local node = minetest.get_node_or_nil(pos)
    if not node or node.name == "ignore" then
        return nil
    end
    return minetest.registered_nodes[node.name]
end

local function is_blocking_node(pos)
    local def = node_def_at(pos)
    if not def then
        return true
    end
    if def.walkable == true then
        return true
    end
    local liquid = tostring(def.liquidtype or "none")
    if liquid ~= "none" then
        return true
    end
    return false
end

local function is_standable_node(pos)
    local def = node_def_at(pos)
    if not def then
        return false
    end
    if def.walkable ~= true then
        return false
    end
    local liquid = tostring(def.liquidtype or "none")
    return liquid == "none"
end

local function find_safe_plot_spawn(plot)
    local center = plot.center or {x = 0, y = 0, z = 0}
    local floor_y = PM.plot_surface_y(plot)
    local start_y = floor_y + 1
    local end_y = PM.plot_ceiling_y(plot) + 6
    local offsets = {
        {0, 0},
        {1, 0}, {-1, 0}, {0, 1}, {0, -1},
        {1, 1}, {1, -1}, {-1, 1}, {-1, -1},
        {2, 0}, {-2, 0}, {0, 2}, {0, -2},
    }
    for _, off in ipairs(offsets) do
        local sx = center.x + off[1]
        local sz = center.z + off[2]
        for y = start_y, end_y do
            local floor = {x = sx, y = y - 1, z = sz}
            local feet = {x = sx, y = y, z = sz}
            local head = {x = sx, y = y + 1, z = sz}
            if is_standable_node(floor) and (not is_blocking_node(feet)) and (not is_blocking_node(head)) then
                return feet
            end
        end
    end
    return {x = center.x, y = start_y, z = center.z}
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
        local was_legacy = is_legacy_layout(plot)
        local ok, err = PM.rebuild_plot(plot)
        if not ok then
            return false, "Failed to refresh plot terrain: " .. tostring(err or "unknown error")
        end
        if was_legacy then
            PM.save_state()
        end
    end

    local bounds = PM.plot_bounds(plot)
    if type(minetest.load_area) == "function" then
        minetest.load_area(bounds.min, bounds.max)
    end

    if options.prepare_spawn == true then
        prepare_plot_spawn(plot)
    end
    local spawn_pos = find_safe_plot_spawn(plot)
    local floor_pos = {x = spawn_pos.x, y = spawn_pos.y - 1, z = spawn_pos.z}
    local floor_node = resolve_plot_floor_node()
    minetest.set_node(floor_pos, {name = floor_node})
    minetest.set_node(spawn_pos, {name = "air"})
    minetest.set_node({x = spawn_pos.x, y = spawn_pos.y + 1, z = spawn_pos.z}, {name = "air"})
    local meta = player:get_meta()
    if meta then
        meta:set_int(PLOT_TP_GRACE_KEY, now() + PLOT_TP_GRACE_SECONDS)
    end
    player:set_pos(spawn_pos)
    player:set_velocity({x = 0, y = 0, z = 0})
    if type(minetest.fix_light) == "function" then
        minetest.fix_light(bounds.min, bounds.max)
    end
    return true
end

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

function PM.install_protection_wrapper()
    local current = minetest.is_protected
    if current == PM._is_protected_wrapper_fn then
        return
    end
    PM._is_protected_base_fn = current
    PM._is_protected_wrapper_fn = function(pos, name)
        local plot = PM.plot_at_pos(pos)
        if plot then
            if name and name ~= "" and PM.can_player_build(plot, name) then
                return false
            end
            return true
        end
        return PM._is_protected_base_fn(pos, name)
    end
    minetest.is_protected = PM._is_protected_wrapper_fn
end

PM.install_protection_wrapper()
minetest.register_on_mods_loaded(function()
    PM.install_protection_wrapper()
end)

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
