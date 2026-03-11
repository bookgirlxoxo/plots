local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local runtime = {
    confirm = {},
}

local function split_words(param)
    local out = {}
    for token in tostring(param or ""):gmatch("%S+") do
        out[#out + 1] = token
    end
    return out
end

local function esc(value)
    return minetest.formspec_escape(tostring(value or ""))
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

local function find_owner_plot_for_management(player)
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
        minetest.colorize("#ff7777", "You were kicked from plot #" .. tostring(plot.id) .. ".")
    )
    if not ok then
        return false, target .. " is not on your plot."
    end
    return true, "Kicked " .. target .. " from plot #" .. tostring(plot.id) .. "."
end

local function remove_build_access(plot, target)
    PM.set_access(plot, "add", target, false)
    PM.set_access(plot, "trust", target, false)
end

local function open_confirm(player, action, plot)
    if not player or not player:is_player() or not plot then
        return false
    end
    local pname = player:get_player_name()
    local action_key = tostring(action or "")
    if action_key ~= "delete" and action_key ~= "clear" then
        return false
    end
    runtime.confirm[pname] = {
        action = action_key,
        plot_id = plot.id,
        expires_at = os.time() + math.max(10, tonumber((PM.config or {}).confirm_ttl_seconds) or 45),
    }

    local verb = action_key == "delete" and "Delete" or "Clear"
    local line = action_key == "delete"
        and "Delete plot #" .. tostring(plot.id) .. " and remove ownership?"
        or "Clear all builds in plot #" .. tostring(plot.id) .. "?"
    local fs = table.concat({
        "formspec_version[4]",
        "size[7.5,4.0]",
        "label[0.45,0.45;" .. esc(verb .. " Plot") .. "]",
        "label[0.45,1.20;" .. esc(line) .. "]",
        "button[0.7,2.6;2.5,0.9;plot_confirm_yes;Confirm]",
        "button[3.5,2.6;2.5,0.9;plot_confirm_no;Cancel]",
    })
    minetest.show_formspec(pname, PM.formname_confirm, fs)
    return true
end

local function close_confirm_form(pname)
    if type(minetest.close_formspec) == "function" then
        minetest.close_formspec(pname, PM.formname_confirm)
        return
    end
    minetest.show_formspec(pname, PM.formname_confirm, "")
end

local function expire_confirm_if_needed(row)
    if type(row) ~= "table" then
        return nil
    end
    local expires_at = tonumber(row.expires_at) or 0
    if expires_at <= os.time() then
        return nil
    end
    return row
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= PM.formname_confirm then
        return false
    end
    if not player or not player:is_player() then
        return true
    end
    local pname = player:get_player_name()
    local row = expire_confirm_if_needed(runtime.confirm[pname])
    runtime.confirm[pname] = nil
    if not row then
        return true
    end
    if fields.quit or fields.plot_confirm_no then
        close_confirm_form(pname)
        return true
    end
    if not fields.plot_confirm_yes then
        return true
    end
    close_confirm_form(pname)
    local plot = PM.get_plot(row.plot_id)
    if not plot or plot.owner ~= pname then
        minetest.chat_send_player(pname, minetest.colorize("#ff5555", "Plot changed or no longer exists."))
        return true
    end

    if row.action == "clear" then
        local ok, msg = PM.clear_plot(plot)
        minetest.chat_send_player(pname, ok and msg or minetest.colorize("#ff5555", tostring(msg)))
        return true
    end
    if row.action == "delete" then
        local current = PM.plot_for_player(player)
        if not current or current.owner ~= pname or as_int(current.id, 0) ~= as_int(plot.id, 0) then
            minetest.chat_send_player(pname, minetest.colorize("#ff5555", "Stand inside your plot to delete it."))
            return true
        end
        local ok, msg = PM.delete_plot(plot)
        minetest.chat_send_player(pname, ok and msg or minetest.colorize("#ff5555", tostring(msg)))
        if ok then
            PM.kick_player_from_plot(pname, plot, "")
        end
        return true
    end
    return true
end)

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

local function command_help()
    return table.concat({
        "/plot create",
        "/plot auto",
        "/plot deny <player>",
        "/plot kick <player>",
        "/plot delete",
        "/plot clear",
        "/plot add <player>",
        "/plot trust <player>",
        "/plot remove <player>",
        "/plot revoke <player>",
        "/plot h [index] [player]",
        "/plot home [index] [player]",
        "/plot hid <plot_id>",
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

        if sub == "create" or sub == "auto" then
            if type(PM.apply_config) == "function" then
                PM.apply_config()
            end
            local ok, msg, plot = PM.create_plot(name)
            if not ok then
                return false, msg
            end
            local t_ok, t_err = PM.teleport_to_plot(player, plot, {
                prepare_spawn = true,
            })
            if not t_ok then
                return false, t_err or "Failed to teleport to new plot."
            end
            if type(PM.rebuild_plot_async) == "function" then
                PM.rebuild_plot_async(plot, function(rebuild_ok, rebuild_err)
                    if rebuild_ok then
                        return
                    end
                    minetest.chat_send_player(
                        name,
                        minetest.colorize("#ff5555", "Plot generation failed: " .. tostring(rebuild_err or "unknown error"))
                    )
                end)
            end
            return true, msg .. " Teleported to your plot. Generating terrain..."
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
            return true, "Teleported to plot #" .. tostring(plot.id) .. "."
        end

        if sub == "hid" then
            local id = as_int(words[2], 0)
            if id <= 0 then
                return false, "Usage: /plot hid <plot id>"
            end
            local plot = PM.get_plot(id)
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
            return true, "Teleported to plot #" .. tostring(id) .. "."
        end

        if sub == "delete" then
            local plot = PM.plot_for_player(player)
            if not plot or plot.owner ~= name then
                return false, "Stand inside your plot to delete it."
            end
            open_confirm(player, "delete", plot)
            return true, "Confirm delete in the GUI."
        end

        if sub == "clear" then
            local plot, err = find_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            open_confirm(player, "clear", plot)
            return true, "Confirm clear in the GUI."
        end

        if sub == "kick" then
            local plot, err = find_owner_plot_for_management(player)
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
            local plot, err = find_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "deny", target, true)
            if not ok then
                return false, set_err
            end
            PM.kick_player_from_plot(target, plot, minetest.colorize("#ff7777", "You are denied from this plot."))
            return true, "Denied " .. target .. " from plot #" .. tostring(plot.id) .. "."
        end

        if sub == "add" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot add <player>"
            end
            local plot, err = find_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "add", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Added " .. target .. " to plot #" .. tostring(plot.id) .. " (builds only while owner is on plot)."
        end

        if sub == "trust" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot trust <player>"
            end
            local plot, err = find_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            local ok, set_err = PM.set_access(plot, "trust", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Trusted " .. target .. " on plot #" .. tostring(plot.id) .. "."
        end

        if sub == "remove" or sub == "revoke" then
            local target = trim(words[2])
            if target == "" then
                return false, "Usage: /plot " .. sub .. " <player>"
            end
            local plot, err = find_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            remove_build_access(plot, target)
            PM.save_state()
            return true, "Revoked build access for " .. target .. " on plot #" .. tostring(plot.id) .. "."
        end

        return false, "Unknown subcommand. Use /plot for help."
    end,
})
