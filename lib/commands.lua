local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local runtime = {
    confirm = {},
}

for _, row in ipairs({
    {
        name = "plots.admin.others",
        description = "Allows interacting with other players' claimed plots.",
    },
    {
        name = "plots.admin.road",
        description = "Allows interacting with plot roads in the managed plot world.",
    },
}) do
    if not minetest.registered_privileges[row.name] then
        minetest.register_privilege(row.name, {
            description = row.description,
            give_to_singleplayer = false,
        })
    end
end

local MAX_MULTIPLE_PRIV = 64
for i = 1, MAX_MULTIPLE_PRIV do
    local priv_name = "plots.multiple." .. tostring(i)
    if not minetest.registered_privileges[priv_name] then
        minetest.register_privilege(priv_name, {
            description = "Allows owning up to " .. tostring(i) .. " plots.",
            give_to_singleplayer = false,
        })
    end
end

local function split_words(param)
    local out = {}
    for token in tostring(param or ""):gmatch("%S+") do
        out[#out + 1] = token
    end
    return out
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

local function sorted_access_names(row)
    local out = {}
    for name, enabled in pairs(type(row) == "table" and row or {}) do
        if enabled == true then
            out[#out + 1] = tostring(name)
        end
    end
    table.sort(out)
    return out
end

local function join_or_dash(values)
    if #values <= 0 then
        return "-"
    end
    return table.concat(values, ", ")
end

local function plot_id_label(plot)
    if type(PM.public_plot_id) == "function" then
        return tostring(PM.public_plot_id(plot))
    end
    return tostring(as_int(plot and plot.id, 0))
end

local function require_owner_plot_for_management(player)
    if not player or not player:is_player() then
        return nil, "Player not found."
    end
    local name = player:get_player_name()
    local current = PM.plot_for_player(player)
    if current and current.owner == name then
        return current
    end

    local ids = PM.owned_plot_ids(name)
    if #ids == 0 then
        return nil, "You do not own a plot. Use /plot create."
    end
    if #ids == 1 then
        return PM.get_plot(ids[1])
    end
    return nil, "Stand on one of your plots, or use /plot hid <id> first."
end

local function kick_target_from_plot(owner_name, plot, target_name)
    local target = trim(target_name)
    if target == "" then
        return false, "Usage: /plot kick <player>"
    end
    if target == owner_name then
        return false, "You cannot kick yourself."
    end
    local ok = PM.kick_player_from_plot(
        target,
        plot,
        minetest.colorize("#ff7777", "You were kicked from plot #" .. plot_id_label(plot) .. ".")
    )
    if not ok then
        return false, target .. " is not on your plot."
    end
    return true, "Kicked " .. target .. " from plot #" .. plot_id_label(plot) .. "."
end

local function remove_build_access(plot, target)
    PM.set_access(plot, "add", target, false)
    PM.set_access(plot, "trust", target, false)
end

local function parse_home_args(words, caller)
    local idx = 1
    local owner = caller
    local w2 = tostring(words[2] or "")
    local w3 = tostring(words[3] or "")

    if w2 ~= "" then
        local n2 = tonumber(w2)
        if n2 then
            idx = math.max(1, as_int(n2, 1))
            if w3 ~= "" then
                owner = w3
            end
        else
            owner = w2
            if w3 ~= "" and tonumber(w3) then
                idx = math.max(1, as_int(w3, 1))
            end
        end
    end

    return idx, trim(owner)
end

local function confirm_action(name, action, plot_id)
    local ttl = math.max(10, tonumber((PM.config or {}).confirm_ttl_seconds) or 45)
    local stamp = os.time()
    local row = runtime.confirm[name]
    if row and row.action == action and as_int(row.plot_id, 0) == as_int(plot_id, 0) and stamp <= as_int(row.expires_at, 0) then
        runtime.confirm[name] = nil
        return true
    end
    runtime.confirm[name] = {
        action = action,
        plot_id = as_int(plot_id, 0),
        expires_at = stamp + ttl,
    }
    return false
end

local function command_help()
    return table.concat({
        "/plot (create|auto|claim)",
        "/plot info [plot_id]",
        "/plot (h|home) [index] [player]",
        "/plot home [index] [player]",
        "/plot hid <plot_id>",
        "/plot add <player>",
        "/plot trust <player>",
        "/plot (revoke|remove) <player>",
        "/plot deny <player>",
        "/plot kick <player>",
        "/plot clear",
        "/plot delete",
    }, "\n")
end

minetest.register_chatcommand("plot", {
    params = "<subcommand>",
    description = "Plot commands. Use /plot for help.",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end

        local words = split_words(param)
        local sub = tostring(words[1] or ""):lower()
        if sub == "home" then
            sub = "h"
        end
        if sub == "" then
            return true, command_help()
        end

        if sub == "claim" then
            sub = "create"
        end

        if sub == "create" or sub == "auto" then
            if type(PM.apply_config) == "function" then
                PM.apply_config()
            end
            if type(PM.schedule_unowned_pregen) == "function" then
                PM.schedule_unowned_pregen(false)
            end

            local ok, msg, plot = PM.create_plot(name)
            if not ok then
                return false, msg
            end

            local create_rebuild_opts = {preserve_surface = false}
            if type(PM.rebuild_plot_async) == "function" then
                PM.rebuild_plot_async(plot, function(rebuild_ok, rebuild_err)
                    local online = minetest.get_player_by_name(name)
                    if not online then
                        return
                    end
                    if not rebuild_ok then
                        minetest.chat_send_player(
                            name,
                            minetest.colorize("#ff5555", "Plot generation failed: " .. tostring(rebuild_err or "unknown error"))
                        )
                        return
                    end
                    local t_ok, t_err = PM.teleport_to_plot(name, plot)
                    if not t_ok then
                        minetest.chat_send_player(
                            name,
                            minetest.colorize("#ff5555", "Failed to teleport to new plot: " .. tostring(t_err or "unknown error"))
                        )
                        return
                    end
                    minetest.chat_send_player(
                        name,
                        "Teleported to plot #" .. plot_id_label(plot) .. "."
                    )
                end, create_rebuild_opts)
                return true, msg .. " Generating terrain..."
            end

            local r_ok, r_err = PM.rebuild_plot(plot, create_rebuild_opts)
            if not r_ok then
                return false, "Plot generation failed: " .. tostring(r_err or "unknown error")
            end
            local t_ok, t_err = PM.teleport_to_plot(player, plot)
            if not t_ok then
                return false, t_err or "Failed to teleport to new plot."
            end
            return true, msg .. " Teleported to plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "h" then
            local idx, owner = parse_home_args(words, name)
            if owner == "" then
                return false, "Invalid player."
            end
            local plot = PM.get_plot_by_owner_index(owner, idx)
            if not plot then
                return false, "Plot not found for that index/player."
            end
            if not PM.can_player_visit(plot, name) then
                return false, "You are denied from that plot."
            end
            local ok, err = PM.teleport_to_plot(player, plot)
            if not ok then
                return false, err
            end
            return true, "Teleported to plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "info" then
            local plot = nil
            local wanted = as_int(words[2], 0)
            if wanted > 0 then
                if type(PM.get_plot_by_public_id) == "function" then
                    plot = PM.get_plot_by_public_id(wanted)
                else
                    plot = PM.get_plot(wanted)
                end
            else
                plot = PM.plot_for_player(player)
            end

            if not plot then
                if wanted <= 0 and PM.in_plot_grid_area(player:get_pos()) then
                    return true, "this plot isnt claimed yet! claim it with /plot claim"
                end
                return false, "Stand in a plot or use /plot info <plot_id>."
            end

            local trusted = sorted_access_names(plot.trust)
            local members = sorted_access_names(plot.add)
            local denied = sorted_access_names(plot.deny)
            return true, table.concat({
                "ID: " .. plot_id_label(plot),
                "Owner: " .. tostring(plot.owner or "-"),
                "Trusted: " .. join_or_dash(trusted),
                "Members: " .. join_or_dash(members),
                "Denied: " .. join_or_dash(denied),
            }, "\n")
        end

        if sub == "hid" then
            local id = as_int(words[2], 0)
            if id <= 0 then
                return false, "Usage: /plot hid <plot id>"
            end
            local plot = nil
            if type(PM.get_plot_by_public_id) == "function" then
                plot = PM.get_plot_by_public_id(id)
            else
                plot = PM.get_plot(id)
            end
            if not plot then
                return false, "Plot not found: " .. tostring(id)
            end
            if not PM.can_player_visit(plot, name) then
                return false, "You are denied from that plot."
            end
            local ok, err = PM.teleport_to_plot(player, plot)
            if not ok then
                return false, err
            end
            return true, "Teleported to plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "delete" then
            local plot = PM.plot_for_player(player)
            if not plot or plot.owner ~= name then
                return false, "Stand inside your plot to delete it."
            end
            if not confirm_action(name, "delete", PM.public_plot_id(plot)) then
                return true, "Run /plot delete again to confirm."
            end
            local ok, msg = PM.delete_plot(plot)
            if ok then
                PM.kick_player_from_plot(name, plot, "")
            end
            return ok, msg
        end

        if sub == "clear" then
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if not confirm_action(name, "clear", PM.public_plot_id(plot)) then
                return true, "Run /plot clear again to confirm."
            end
            return PM.clear_plot(plot)
        end

        if sub == "kick" then
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            return kick_target_from_plot(name, plot, words[2])
        end

        if sub == "deny" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot deny <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "deny", target, true)
            if not ok then
                return false, set_err
            end
            PM.kick_player_from_plot(target, plot, minetest.colorize("#ff7777", "You are denied from this plot."))
            return true, "Denied " .. target .. " from plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "add" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot add <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "add", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Added " .. target .. " to plot #" .. plot_id_label(plot) .. " (builds only while owner is on plot)."
        end

        if sub == "trust" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot trust <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "trust", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Trusted " .. target .. " on plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "remove" or sub == "revoke" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot " .. sub .. " <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            remove_build_access(plot, target)
            PM.save_state()
            return true, "Revoked build access for " .. target .. " on plot #" .. plot_id_label(plot) .. "."
        end

        return false, "Unknown subcommand. Use /plot for help."
    end,
})

minetest.register_chatcommand("p", {
    params = "<subcommand>",
    description = "Alias for /plot",
    func = function(name, param)
        local cmd = minetest.registered_chatcommands and minetest.registered_chatcommands.plot
        if not cmd or type(cmd.func) ~= "function" then
            return false, "Plot command is unavailable."
        end
        return cmd.func(name, param)
    end,
})
