local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local C = PM._core
if type(C) ~= "table" then
    return
end

local SAVE_KEY = C.SAVE_KEY
local PREGEN_SIGNATURE_REV = C.PREGEN_SIGNATURE_REV
local CLAIMED_BORDER_NODE = "plots:claimed"
local UNCLAIMED_BORDER_NODE = "plots:unclaimed"

local trim = C.trim
local as_int = C.as_int
local round_int = C.round_int
local copy_vec3 = C.copy_vec3
local ensure_player_name = C.ensure_player_name
local ensure_access_table = C.ensure_access_table
local sanitize_shape = C.sanitize_shape
local get_player_priv_table = C.get_player_priv_table
local player_has_plot_admin_others = C.player_has_plot_admin_others
local read_text = C.read_text

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
    local dim = type(cfg.dimension) == "table" and cfg.dimension or {}
    local dim_y = as_int(dim.y, as_int((type(cfg.origin) == "table" and cfg.origin.y), 6000))
    local origin = copy_vec3(cfg.origin, {x = 0, y = dim_y, z = 0})
    local build_height = math.max(8, as_int(cfg.build_height, 96))
    local build_depth = math.max(8, as_int(cfg.build_depth, 32))
    local dim_min = as_int(dim.y_min, dim_y - build_depth - 128)
    local dim_max = as_int(dim.y_max, dim_y + (build_height * 2) + 256)
    if dim_min > dim_max then
        dim_min, dim_max = dim_max, dim_min
    end

    local spawn = copy_vec3(cfg.spawn, {x = origin.x, y = origin.y + 2, z = origin.z})
    local spawn_mode = trim(cfg.spawn_mode):lower()
    if spawn_mode ~= "center" and spawn_mode ~= "fixed" then
        spawn_mode = "center"
    end

    PM.config = {
        plot_size = math.max(8, as_int(cfg.plot_size, 48)),
        plot_gap = math.max(2, as_int(cfg.plot_gap, 14)),
        shape = sanitize_shape(cfg.shape, "square"),
        grid_columns = math.max(1, as_int(cfg.grid_columns, 64)),
        grid_world_size = math.max(0, as_int(cfg.grid_world_size, 2000)),
        pregenerate_plot_count = math.max(1, as_int(cfg.pregenerate_plot_count, 256)),
        pregenerate_batch_size = math.max(1, as_int(cfg.pregenerate_batch_size, 16)),
        origin = origin,
        spawn = spawn,
        spawn_mode = spawn_mode,
        dimension = {
            y_min = dim_min,
            y_max = dim_max,
        },
        build_height = build_height,
        build_depth = build_depth,
        max_plots_per_player = math.max(1, as_int(cfg.max_plots_per_player, 1)),
        floor_node = trim(cfg.floor_node) ~= "" and trim(cfg.floor_node) or "default:stone",
        terrain_top_node = trim(cfg.terrain_top_node) ~= "" and trim(cfg.terrain_top_node) or "default:dirt_with_grass",
        terrain_dirt_node = trim(cfg.terrain_dirt_node) ~= "" and trim(cfg.terrain_dirt_node) or "default:dirt",
        terrain_stone_node = trim(cfg.terrain_stone_node) ~= "" and trim(cfg.terrain_stone_node) or "default:stone",
        terrain_grass_plant_chance = math.max(0, math.min(1, tonumber(cfg.terrain_grass_plant_chance) or 0.13)),
        road_node = trim(cfg.road_node) ~= "" and trim(cfg.road_node) or "default:stonebrick",
        unowned_plot_node = trim(cfg.unowned_plot_node) ~= "" and trim(cfg.unowned_plot_node) or "default:dirt_with_grass",
        border_enabled = cfg.border_enabled ~= false,
        confirm_ttl_seconds = math.max(10, as_int(cfg.confirm_ttl_seconds, 45)),
        deny_check_interval = math.max(0.2, tonumber(cfg.deny_check_interval) or 1.0),
    }
end

local function plot_spacing()
    return math.max(10, as_int((PM.config or {}).plot_size, 48) + as_int((PM.config or {}).plot_gap, 14) + 2)
end

local function configured_pregenerate_plot_count()
    return math.max(1, as_int((PM.config or {}).pregenerate_plot_count, 256))
end

local function layout_info()
    local cfg = PM.config or {}
    local spacing = plot_spacing()
    local world_size = math.max(0, as_int(cfg.grid_world_size, 2000))
    local cols
    local rows
    local count

    if world_size > 0 then
        local per_axis = math.max(1, math.floor(world_size / spacing))
        cols = per_axis
        rows = per_axis
        count = cols * rows
    else
        cols = math.max(1, as_int(cfg.grid_columns, 64))
        count = configured_pregenerate_plot_count()
        rows = math.max(1, math.ceil(count / cols))
    end

    local origin = cfg.origin or {x = 0, y = 6000, z = 0}
    local ox = as_int(origin.x, 0)
    local oy = as_int(origin.y, 6000)
    local oz = as_int(origin.z, 0)
    local start_x = round_int(ox - ((cols - 1) * spacing * 0.5))
    local start_z = round_int(oz - ((rows - 1) * spacing * 0.5))

    return {
        spacing = spacing,
        cols = cols,
        rows = rows,
        count = count,
        origin_x = ox,
        origin_y = oy,
        origin_z = oz,
        start_x = start_x,
        start_z = start_z,
    }
end

local function pregenerate_plot_count()
    return layout_info().count
end

local function center_for_plot_id(id)
    local layout = layout_info()
    local idx = math.max(1, as_int(id, 1)) - 1
    local col = idx % layout.cols
    local row = math.floor(idx / layout.cols)
    return {
        x = layout.start_x + (col * layout.spacing),
        y = layout.origin_y,
        z = layout.start_z + (row * layout.spacing),
    }
end

local function snap_plot_center_to_layout(plot)
    if type(plot) ~= "table" then
        return false
    end
    local id = as_int(plot.id, 0)
    if id <= 0 then
        return false
    end
    local target = center_for_plot_id(id)
    local current = type(plot.center) == "table" and plot.center or {}
    if as_int(current.x, 0) == target.x
        and as_int(current.y, 0) == target.y
        and as_int(current.z, 0) == target.z then
        return false
    end
    plot.center = target
    return true
end

local function pregen_signature()
    local cfg = PM.config or {}
    local layout = layout_info()
    local origin = type(cfg.origin) == "table" and cfg.origin or {x = 0, y = 0, z = 0}
    local values = {
        tostring(PREGEN_SIGNATURE_REV),
        tostring(as_int(cfg.plot_size, 48)),
        tostring(as_int(cfg.plot_gap, 14)),
        tostring(sanitize_shape(cfg.shape, "square")),
        tostring(configured_pregenerate_plot_count()),
        tostring(layout.cols),
        tostring(layout.rows),
        tostring(layout.count),
        tostring(as_int(origin.x, 0)),
        tostring(as_int(origin.y, 0)),
        tostring(as_int(origin.z, 0)),
        tostring(as_int(cfg.build_height, 96)),
        tostring(trim(cfg.road_node)),
        tostring(trim(cfg.unowned_plot_node)),
        UNCLAIMED_BORDER_NODE,
        CLAIMED_BORDER_NODE,
    }
    return table.concat(values, ":")
end

local function sanitize_plot(raw, fallback_shape, fallback_id)
    local src = type(raw) == "table" and raw or {}
    local id = as_int(src.id, as_int(fallback_id, 0))
    local owner = trim(src.owner)
    if id <= 0 or owner == "" then
        return nil
    end

    local center = center_for_plot_id(id)
    return {
        id = id,
        owner = owner,
        center = center,
        public_id = as_int(src.public_id, 0),
        size = math.max(8, as_int(src.size, as_int((PM.config or {}).plot_size, 48))),
        shape = sanitize_shape(src.shape, fallback_shape),
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
        next_public_id = math.max(1, as_int(src.next_public_id, 1)),
        plots = {},
        player_plots = {},
        pregen_signature = trim(src.pregen_signature),
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

    local plots = {}
    for _, row in pairs(out.plots) do
        plots[#plots + 1] = row
    end
    table.sort(plots, function(a, b)
        local ac = as_int(a and a.created_at, 0)
        local bc = as_int(b and b.created_at, 0)
        if ac ~= bc then
            if ac <= 0 then
                return false
            end
            if bc <= 0 then
                return true
            end
            return ac < bc
        end
        return as_int(a and a.id, 0) < as_int(b and b.id, 0)
    end)

    local used_public = {}
    local max_public = 0
    local next_public = 1
    for _, plot in ipairs(plots) do
        local pid = as_int(plot.public_id, 0)
        if pid > 0 and not used_public[pid] then
            used_public[pid] = true
            if pid > max_public then
                max_public = pid
            end
        else
            while used_public[next_public] do
                next_public = next_public + 1
            end
            plot.public_id = next_public
            used_public[next_public] = true
            if next_public > max_public then
                max_public = next_public
            end
            next_public = next_public + 1
        end
    end
    out.next_public_id = math.max(max_public + 1, out.next_public_id)

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

local function id_from_cell(col, row)
    local layout = layout_info()
    local cols = layout.cols
    if col < 0 or row < 0 then
        return nil
    end
    if col >= layout.cols or row >= layout.rows then
        return nil
    end
    local id = (row * cols) + col + 1
    if id > layout.count then
        return nil
    end
    return id
end

local function cell_from_pos(pos)
    local layout = layout_info()
    local xf = ((pos.x - layout.start_x) / layout.spacing) + 0.5
    local zf = ((pos.z - layout.start_z) / layout.spacing) + 0.5
    return math.floor(xf), math.floor(zf)
end

local function cell_bounds_for_plot_id(id)
    local center = center_for_plot_id(id)
    local layout = layout_info()
    local radius = math.max(4, math.floor(math.max(8, as_int((PM.config or {}).plot_size, 48)) * 0.5))
    local half = math.max(radius + 2, math.floor(layout.spacing * 0.5))
    local ground_y = center.y + math.max(8, as_int((PM.config or {}).build_height, 96))
    return center, {
        min = {x = center.x - half, y = ground_y, z = center.z - half},
        max = {x = center.x + half, y = ground_y + 3, z = center.z + half},
    }
end

function PM.get_plot(plot_id)
    local id = as_int(plot_id, 0)
    if id <= 0 then
        return nil
    end
    return (PM.state.plots or {})[tostring(id)]
end

function PM.public_plot_id(plot_or_id)
    local plot = type(plot_or_id) == "table" and plot_or_id or PM.get_plot(plot_or_id)
    if type(plot) ~= "table" then
        return as_int(plot_or_id, 0)
    end
    local pid = as_int(plot.public_id, 0)
    if pid > 0 then
        return pid
    end
    return as_int(plot.id, 0)
end

function PM.get_plot_by_public_id(plot_id)
    local wanted = as_int(plot_id, 0)
    if wanted <= 0 then
        return nil
    end
    for _, plot in pairs(PM.state.plots or {}) do
        if PM.public_plot_id(plot) == wanted then
            return plot
        end
    end
    return nil
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

function PM.get_max_plots_per_player(owner_name)
    local base = math.max(1, as_int((PM.config or {}).max_plots_per_player, 1))
    local privs = get_player_priv_table(owner_name)
    for priv, granted in pairs(privs) do
        if granted == true then
            local count = tonumber(tostring(priv):match("^plots%.multiple%.(%d+)$"))
            if count and count > base then
                base = count
            end
        end
    end
    return base
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

local function normalize_access(plot)
    plot.add = ensure_access_table(plot.add)
    plot.trust = ensure_access_table(plot.trust)
    plot.deny = ensure_access_table(plot.deny)
end

function PM.plot_radius(plot)
    local size = math.max(8, as_int(plot and plot.size, (PM.config or {}).plot_size or 48))
    return math.max(4, math.floor(size * 0.5))
end

function PM.plot_surface_y(plot)
    local center = (plot and plot.center) or {x = 0, y = 0, z = 0}
    local cfg = PM.config or {}
    local build_h = math.max(8, as_int(cfg.build_height, 96))
    return center.y + build_h
end

function PM.plot_ceiling_y(plot)
    local cfg = PM.config or {}
    return PM.plot_surface_y(plot) + math.max(8, as_int(cfg.build_height, 96))
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

function PM.plot_at_pos(pos)
    if type(pos) ~= "table" then
        return nil
    end
    local base_col, base_row = cell_from_pos(pos)
    local base_id = id_from_cell(base_col, base_row)
    if base_id then
        local base_plot = PM.get_plot(base_id)
        if base_plot and pos_in_plot_shape(base_plot, pos) then
            return base_plot
        end
    end

    -- Fallback for boundary edge-cases.
    for row = base_row - 1, base_row + 1 do
        for col = base_col - 1, base_col + 1 do
            if row ~= base_row or col ~= base_col then
                local id = id_from_cell(col, row)
                local plot = id and PM.get_plot(id) or nil
                if plot and pos_in_plot_shape(plot, pos) then
                    return plot
                end
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
    if pname == plot.owner or player_has_plot_admin_others(pname) then
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
    if player_has_plot_admin_others(pname) then
        return true
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
    local layout = layout_info()
    local dim = type(cfg.dimension) == "table" and cfg.dimension or {}
    local y_min = as_int(dim.y_min, layout.origin_y)
    local y_max = as_int(dim.y_max, y_min + 128)
    if y_min > y_max then
        y_min, y_max = y_max, y_min
    end

    if trim(cfg.spawn_mode):lower() == "fixed" then
        local spawn = copy_vec3(cfg.spawn, {x = layout.origin_x, y = y_min, z = layout.origin_z})
        if spawn.y < y_min then
            spawn.y = y_min
        elseif spawn.y > y_max then
            spawn.y = y_max
        end
        return spawn
    end

    return {
        x = layout.origin_x,
        y = math.floor((y_min + y_max) * 0.5),
        z = layout.origin_z,
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

function PM.in_plot_grid_area(pos)
    if type(pos) ~= "table" then
        return false
    end
    local layout = layout_info()
    if layout.count <= 0 then
        return false
    end
    local radius = math.max(4, math.floor(math.max(8, as_int((PM.config or {}).plot_size, 48)) * 0.5))
    local half = math.max(radius + 2, math.floor(layout.spacing * 0.5))
    local min_x = layout.start_x - half
    local max_x = layout.start_x + ((layout.cols - 1) * layout.spacing) + half
    local min_z = layout.start_z - half
    local max_z = layout.start_z + ((layout.rows - 1) * layout.spacing) + half
    return pos.x >= min_x and pos.x <= max_x and pos.z >= min_z and pos.z <= max_z
end

local function plot_grid_bounds_2d()
    local layout = layout_info()
    if layout.count <= 0 then
        return nil
    end
    local radius = math.max(4, math.floor(math.max(8, as_int((PM.config or {}).plot_size, 48)) * 0.5))
    local half = math.max(radius + 2, math.floor(layout.spacing * 0.5))
    return {
        min_x = layout.start_x - half,
        max_x = layout.start_x + ((layout.cols - 1) * layout.spacing) + half,
        min_z = layout.start_z - half,
        max_z = layout.start_z + ((layout.rows - 1) * layout.spacing) + half,
    }
end

local function pos_in_plot_cell_footprint(pos)
    if type(pos) ~= "table" then
        return false
    end

    local layout = layout_info()
    if layout.count <= 0 then
        return false
    end

    local spacing = math.max(1, as_int(layout.spacing, 1))
    local x = as_int(pos.x, 0)
    local z = as_int(pos.z, 0)
    local col = math.floor(((x - layout.start_x) / spacing) + 0.5)
    local row = math.floor(((z - layout.start_z) / spacing) + 0.5)
    if col < 0 or col >= layout.cols or row < 0 or row >= layout.rows then
        return false
    end

    local cell_id = (row * layout.cols) + col + 1
    if cell_id > layout.count then
        return false
    end

    local center_x = layout.start_x + (col * spacing)
    local center_z = layout.start_z + (row * spacing)
    local dx = x - center_x
    local dz = z - center_z
    local radius = math.max(4, math.floor(math.max(8, as_int((PM.config or {}).plot_size, 48)) * 0.5))
    local shape = sanitize_shape((PM.config or {}).shape, "square")

    if shape == "sphere" then
        return (dx * dx) + (dz * dz) <= (radius * radius)
    end
    return math.abs(dx) <= radius and math.abs(dz) <= radius
end

function PM.is_road_pos(pos)
    if not PM.in_plot_grid_area(pos) then
        return false
    end
    return not pos_in_plot_cell_footprint(pos)
end

C.layout_info = layout_info
C.configured_pregenerate_plot_count = configured_pregenerate_plot_count
C.pregenerate_plot_count = pregenerate_plot_count
C.center_for_plot_id = center_for_plot_id
C.snap_plot_center_to_layout = snap_plot_center_to_layout
C.pregen_signature = pregen_signature
C.id_from_cell = id_from_cell
C.cell_bounds_for_plot_id = cell_bounds_for_plot_id
C.normalize_access = normalize_access
C.plot_grid_bounds_2d = plot_grid_bounds_2d
C.pos_in_plot_shape = pos_in_plot_shape
