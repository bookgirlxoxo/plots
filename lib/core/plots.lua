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
local trim = C.trim
local as_int = C.as_int
local ensure_player_name = C.ensure_player_name
local sanitize_shape = C.sanitize_shape
local ensure_access_table = C.ensure_access_table
local layout_info = C.layout_info
local pregenerate_plot_count = C.pregenerate_plot_count
local center_for_plot_id = C.center_for_plot_id
local normalize_access = C.normalize_access
local pos_in_plot_shape = C.pos_in_plot_shape

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

local function claim_order_for_limit(limit)
    local layout = layout_info()
    local cols = math.max(1, as_int(layout.cols, 1))
    local rows = math.max(1, as_int(layout.rows, 1))
    local max_ids = math.max(1, math.min(as_int(limit, 1), cols * rows))

    PM.runtime = PM.runtime or {}
    local cache_key = tostring(max_ids) .. ":" .. tostring(cols) .. ":" .. tostring(rows)
    if PM.runtime.claim_order_key == cache_key and type(PM.runtime.claim_order) == "table" then
        return PM.runtime.claim_order
    end

    local center_col = math.floor((cols - 1) * 0.5)
    local center_row = math.floor((rows - 1) * 0.5)
    local order = {}
    for id = 1, max_ids do
        order[#order + 1] = id
    end

    table.sort(order, function(a, b)
        local ai = a - 1
        local bi = b - 1
        local ac = ai % cols
        local ar = math.floor(ai / cols)
        local bc = bi % cols
        local br = math.floor(bi / cols)

        local ad = math.abs(ac - center_col) + math.abs(ar - center_row)
        local bd = math.abs(bc - center_col) + math.abs(br - center_row)
        if ad ~= bd then
            return ad < bd
        end

        local asq = ((ac - center_col) * (ac - center_col)) + ((ar - center_row) * (ar - center_row))
        local bsq = ((bc - center_col) * (bc - center_col)) + ((br - center_row) * (br - center_row))
        if asq ~= bsq then
            return asq < bsq
        end

        return a < b
    end)

    PM.runtime.claim_order = order
    PM.runtime.claim_order_key = cache_key
    return order
end

local function next_unclaimed_plot_id()
    local limit = pregenerate_plot_count()
    for _, id in ipairs(claim_order_for_limit(limit)) do
        if not PM.get_plot(id) then
            return id
        end
    end
    return nil
end

function PM.create_plot(owner_name)
    local owner = ensure_player_name(owner_name)
    if owner == "" then
        return false, "Invalid owner."
    end

    local ids = PM.owned_plot_ids(owner)
    local max_count = math.max(1, as_int(PM.get_max_plots_per_player(owner), 1))
    if #ids >= max_count then
        return false, "Plot limit reached (" .. tostring(max_count) .. ")."
    end

    local id = next_unclaimed_plot_id()
    if not id then
        return false, "No unclaimed plots are available. Increase grid_world_size or pregenerate_plot_count."
    end

    local plot = {
        id = id,
        owner = owner,
        center = center_for_plot_id(id),
        public_id = math.max(1, as_int(PM.state.next_public_id, 1)),
        size = math.max(8, as_int((PM.config or {}).plot_size, 48)),
        shape = sanitize_shape((PM.config or {}).shape, "square"),
        created_at = now(),
        add = {},
        trust = {},
        deny = {},
    }

    PM.state.plots[tostring(id)] = plot
    PM.state.next_id = math.max(as_int(PM.state.next_id, 1), id + 1)
    PM.state.next_public_id = math.max(as_int(PM.state.next_public_id, 1), as_int(plot.public_id, 1) + 1)
    save_plot_ref(owner, id)
    PM.save_state()
    return true, "Created plot #" .. tostring(plot.public_id) .. ".", plot
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
    return true, "Plot #" .. tostring(PM.public_plot_id(plot)) .. " cleared."
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
    PM.render_unowned_cell(id)
    PM.save_state()
    return true, "Deleted plot #" .. tostring(PM.public_plot_id(plot)) .. "."
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
    local floor_node = trim((PM.config or {}).floor_node)
    if floor_node == "" or not minetest.registered_nodes[floor_node] then
        floor_node = "default:stone"
    end
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

C.claim_order_for_limit = claim_order_for_limit
