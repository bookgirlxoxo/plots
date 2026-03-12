local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local C = PM._core
if type(C) ~= "table" then
    return
end

local trim = C.trim
local as_int = C.as_int
local sanitize_shape = C.sanitize_shape
local cell_bounds_for_plot_id = C.cell_bounds_for_plot_id
local normalize_access = C.normalize_access
local snap_plot_center_to_layout = C.snap_plot_center_to_layout
local CLAIMED_BORDER_NODE = "plots:claimed"
local UNCLAIMED_BORDER_NODE = "plots:unclaimed"

local function get_content_id(name, fallback)
    local node = trim(name)
    if node == "" or not minetest.registered_nodes[node] then
        node = fallback
    end
    return minetest.get_content_id(node)
end

local function resolve_node_name(name, fallback)
    local node = trim(name)
    if node == "" or not minetest.registered_nodes[node] then
        node = trim(fallback)
    end
    if node == "" or not minetest.registered_nodes[node] then
        node = "default:stone"
    end
    return node
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

local function write_vm(vm, minp, maxp, do_light)
    vm:write_to_map()
    if do_light == true and type(minetest.fix_light) == "function" and type(minp) == "table" and type(maxp) == "table" then
        minetest.fix_light(minp, maxp)
    end
end

local function paint_cell_surface(plot_id, mode)
    local id = as_int(plot_id, 0)
    if id <= 0 then
        return false, "Invalid plot id."
    end

    local center, read_bounds = cell_bounds_for_plot_id(id)
    local cfg = PM.config or {}
    local c_air = minetest.get_content_id("air")
    local c_road = get_content_id(cfg.road_node, "default:stonebrick")
    local c_unowned = get_content_id(cfg.unowned_plot_node, "default:dirt_with_grass")
    local c_outline = get_content_id(UNCLAIMED_BORDER_NODE, UNCLAIMED_BORDER_NODE)
    local shape = sanitize_shape(cfg.shape, "square")
    local radius = math.max(4, math.floor(math.max(8, as_int(cfg.plot_size, 48)) * 0.5))
    local inner = math.max(1, radius - 1)
    local rr = radius * radius
    local inner_rr = inner * inner
    local ground_y = read_bounds.min.y

    local vm = VoxelManip()
    local read_min, read_max = vm:read_from_map(read_bounds.min, read_bounds.max)
    local area = VoxelArea:new({MinEdge = read_min, MaxEdge = read_max})
    local data = vm:get_data()

    local minx = math.max(read_bounds.min.x, read_min.x)
    local maxx = math.min(read_bounds.max.x, read_max.x)
    local minz = math.max(read_bounds.min.z, read_min.z)
    local maxz = math.min(read_bounds.max.z, read_max.z)

    if ground_y < read_min.y or ground_y > read_max.y then
        return false, "Plot surface not loaded."
    end

    for z = minz, maxz do
        local dz = z - center.z
        local adz = math.abs(dz)
        for x = minx, maxx do
            local dx = x - center.x
            local adx = math.abs(dx)
            local inside
            local outline

            if shape == "sphere" then
                local d2 = (dx * dx) + (dz * dz)
                inside = d2 <= rr
                outline = inside and d2 >= inner_rr
            else
                inside = adx <= radius and adz <= radius
                outline = inside and (adx == radius or adz == radius)
            end

            if mode == "road_only" then
                if not inside then
                    data[area:index(x, ground_y, z)] = c_road
                end
            else
                local surface = c_road
                if inside then
                    surface = outline and c_outline or c_unowned
                end
                data[area:index(x, ground_y, z)] = surface
            end

            for y = ground_y + 1, math.min(ground_y + 3, read_max.y) do
                if y >= read_min.y then
                    data[area:index(x, y, z)] = c_air
                end
            end
        end
    end

    vm:set_data(data)
    write_vm(vm, read_min, read_max, false)
    return true
end

function PM.render_unowned_cell(plot_id)
    local id = as_int(plot_id, 0)
    if id <= 0 then
        return false, "Invalid plot id."
    end
    if PM.get_plot(id) then
        return false, "Plot is claimed."
    end
    return paint_cell_surface(id, "unowned")
end

function PM.paint_cell_road_layer(plot_id)
    local id = as_int(plot_id, 0)
    if id <= 0 then
        return false, "Invalid plot id."
    end
    return paint_cell_surface(id, "road_only")
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

local function regen_square_plot(plot, area, data, read_min, read_max, options)
    local cfg = PM.config or {}
    local center = plot.center
    local r = PM.plot_radius(plot)
    local surface_y = PM.plot_surface_y(plot)
    local floor_y = center.y - math.max(8, as_int(cfg.build_depth, 32))
    local top_y = PM.plot_ceiling_y(plot)
    local preserve_surface = type(options) == "table" and options.preserve_surface == true

    local c_air = minetest.get_content_id("air")
    local c_top = get_content_id(cfg.terrain_top_node, "default:dirt_with_grass")
    local c_dirt = get_content_id(cfg.terrain_dirt_node, "default:dirt")
    local c_stone = get_content_id(cfg.terrain_stone_node, "default:stone")
    local c_wall = get_content_id(CLAIMED_BORDER_NODE, CLAIMED_BORDER_NODE)
    local border_on = cfg.border_enabled ~= false

    fill_box(
        area,
        data,
        {x = center.x - r, y = surface_y + 1, z = center.z - r},
        {x = center.x + r, y = top_y, z = center.z + r},
        c_air,
        read_min,
        read_max
    )

    local minx = math.max(center.x - r, read_min.x)
    local maxx = math.min(center.x + r, read_max.x)
    local minz = math.max(center.z - r, read_min.z)
    local maxz = math.min(center.z + r, read_max.z)
    local y1 = math.max(floor_y, read_min.y)
    local y2 = math.min(surface_y, read_max.y)
    if y1 > y2 then
        return
    end

    for z = minz, maxz do
        local dz = math.abs(z - center.z)
        for x = minx, maxx do
            local dx = math.abs(x - center.x)
            local at_edge = dx == r or dz == r
            for y = y1, y2 do
                if preserve_surface and y == surface_y and not at_edge then
                    goto continue_square_y
                end
                local cid
                if y == surface_y then
                    cid = c_top
                elseif y >= surface_y - 3 then
                    cid = c_dirt
                else
                    cid = c_stone
                end
                if border_on and (at_edge or y == floor_y) then
                    cid = c_wall
                end
                data[area:index(x, y, z)] = cid
                ::continue_square_y::
            end
        end
    end
end

local function regen_sphere_plot(plot, area, data, read_min, read_max, options)
    local cfg = PM.config or {}
    local center = plot.center
    local r = PM.plot_radius(plot)
    local rr = r * r
    local surface_y = PM.plot_surface_y(plot)
    local floor_y = center.y - math.max(8, as_int(cfg.build_depth, 32))
    local top_y = PM.plot_ceiling_y(plot)
    local preserve_surface = type(options) == "table" and options.preserve_surface == true

    local c_air = minetest.get_content_id("air")
    local c_top = get_content_id(cfg.terrain_top_node, "default:dirt_with_grass")
    local c_dirt = get_content_id(cfg.terrain_dirt_node, "default:dirt")
    local c_stone = get_content_id(cfg.terrain_stone_node, "default:stone")
    local c_wall = get_content_id(CLAIMED_BORDER_NODE, CLAIMED_BORDER_NODE)
    local border_on = cfg.border_enabled ~= false
    local inner = math.max(1, r - 1)
    local inner_rr = inner * inner

    fill_box(
        area,
        data,
        {x = center.x - r, y = surface_y + 1, z = center.z - r},
        {x = center.x + r, y = top_y, z = center.z + r},
        c_air,
        read_min,
        read_max
    )

    local minx = math.max(center.x - r, read_min.x)
    local maxx = math.min(center.x + r, read_max.x)
    local minz = math.max(center.z - r, read_min.z)
    local maxz = math.min(center.z + r, read_max.z)
    local y1 = math.max(floor_y, read_min.y)
    local y2 = math.min(surface_y, read_max.y)
    if y1 > y2 then
        return
    end

    for z = minz, maxz do
        local dz = z - center.z
        for x = minx, maxx do
            local dx = x - center.x
            local d2 = (dx * dx) + (dz * dz)
            if d2 <= rr then
                local at_edge = d2 >= inner_rr
                for y = y1, y2 do
                    if preserve_surface and y == surface_y and not at_edge then
                        goto continue_sphere_y
                    end
                    local cid
                    if y == surface_y then
                        cid = c_top
                    elseif y >= surface_y - 3 then
                        cid = c_dirt
                    else
                        cid = c_stone
                    end
                    if border_on and (at_edge or y == floor_y) then
                        cid = c_wall
                    end
                    data[area:index(x, y, z)] = cid
                    ::continue_sphere_y::
                end
            end
        end
    end
end

local function paint_claimed_road_layer(plot, area, data, read_min, read_max, bounds)
    local cfg = PM.config or {}
    local c_road = get_content_id(cfg.road_node, "default:stonebrick")
    local center = plot.center
    local r = PM.plot_radius(plot)
    local rr = r * r
    local shape = sanitize_shape(plot.shape, cfg.shape)
    local ground_y = PM.plot_surface_y(plot)

    if ground_y < read_min.y or ground_y > read_max.y then
        return
    end

    local minx = math.max((bounds.min or {}).x or read_min.x, read_min.x)
    local maxx = math.min((bounds.max or {}).x or read_max.x, read_max.x)
    local minz = math.max((bounds.min or {}).z or read_min.z, read_min.z)
    local maxz = math.min((bounds.max or {}).z or read_max.z, read_max.z)
    if minx > maxx or minz > maxz then
        return
    end

    for z = minz, maxz do
        local dz = z - center.z
        local adz = math.abs(dz)
        for x = minx, maxx do
            local dx = x - center.x
            local adx = math.abs(dx)
            local inside
            if shape == "sphere" then
                inside = ((dx * dx) + (dz * dz)) <= rr
            else
                inside = adx <= r and adz <= r
            end
            if not inside then
                data[area:index(x, ground_y, z)] = c_road
            end
        end
    end
end

function PM.rebuild_plot(plot, options)
    if not plot then
        return false, "Plot not found."
    end

    normalize_access(plot)
    snap_plot_center_to_layout(plot)
    local opts = type(options) == "table" and options or {}
    local preserve_surface = opts.preserve_surface == true

    local bounds = rebuild_read_bounds(plot)
    local vm = VoxelManip()
    local read_min, read_max = vm:read_from_map(bounds.min, bounds.max)
    local area = VoxelArea:new({MinEdge = read_min, MaxEdge = read_max})
    local data = vm:get_data()

    if not preserve_surface then
        clear_plot_neighborhood(plot, area, data, read_min, read_max)
    end
    if sanitize_shape(plot.shape, (PM.config or {}).shape) == "sphere" then
        regen_sphere_plot(plot, area, data, read_min, read_max, opts)
    else
        regen_square_plot(plot, area, data, read_min, read_max, opts)
    end
    if not preserve_surface then
        paint_claimed_road_layer(plot, area, data, read_min, read_max, bounds)
    end

    vm:set_data(data)
    write_vm(vm, bounds.min, bounds.max, false)
    return true
end

function PM.rebuild_plot_async(plot, done_cb, options)
    if not plot then
        if done_cb then
            done_cb(false, "Plot not found.")
        end
        return false
    end

    local function finish()
        local ok, err = PM.rebuild_plot(plot, options)
        if done_cb then
            done_cb(ok, err)
        end
    end

    local bounds = rebuild_read_bounds(plot)
    if minetest.emerge_area then
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

local function wipe_square_plot(plot, area, data, read_min, read_max)
    local center = plot.center
    local r = PM.plot_radius(plot)
    local top_y = PM.plot_ceiling_y(plot)
    local floor_y = center.y - math.max(8, as_int((PM.config or {}).build_depth, 32))
    local c_air = minetest.get_content_id("air")

    fill_box(
        area,
        data,
        {x = center.x - r, y = floor_y, z = center.z - r},
        {x = center.x + r, y = top_y, z = center.z + r},
        c_air,
        read_min,
        read_max
    )
end

local function wipe_sphere_plot(plot, area, data, read_min, read_max)
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
        wipe_sphere_plot(plot, area, data, read_min, read_max)
    else
        wipe_square_plot(plot, area, data, read_min, read_max)
    end

    vm:set_data(data)
    write_vm(vm, bounds.min, bounds.max, false)
    return true
end
