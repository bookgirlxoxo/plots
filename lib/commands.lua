local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local runtime = {
    pending_confirm = {},
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

local ensure_player_name = (type(PM._core) == "table" and type(PM._core.ensure_player_name) == "function")
    and PM._core.ensure_player_name or trim
local player_exists = (type(PM._core) == "table" and type(PM._core.player_exists) == "function")
    and PM._core.player_exists or function(target_name)
        if type(minetest.player_exists) == "function" then
            return minetest.player_exists(ensure_player_name(target_name)) == true
        end
        return minetest.get_player_by_name(ensure_player_name(target_name)) ~= nil
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

local function is_plot_owner_target(plot, target_name)
    local target = ensure_player_name(target_name)
    local owner = ensure_player_name(plot and plot.owner or "")
    return target ~= "" and owner ~= "" and target == owner
end

local function player_has_transfer_slot(owner_name, target_name)
    local owner = ensure_player_name(owner_name)
    local target = ensure_player_name(target_name)
    if owner == "" then
        return false, target, "Invalid player."
    end
    if target == "" then
        return false, target, "Invalid player."
    end
    if not player_exists(target) then
        return false, target, "Player does not exist."
    end
    if not minetest.get_player_by_name(owner) or not minetest.get_player_by_name(target) then
        return false, target, "Both players must be online."
    end
    local owned = PM.owned_plot_ids(target)
    local max_allowed = math.max(1, as_int(PM.get_max_plots_per_player(target), 1))
    if #owned > 0 or #owned >= max_allowed then
        return false, target, "User has no plots available"
    end
    return true, target, ""
end

local function kick_target_from_plot(owner_name, plot, target_name)
    local target = ensure_player_name(target_name)
    if target == "" then
        return false, "Usage: /plot kick <player>"
    end
    if is_plot_owner_target(plot, target) then
        return false, "You cannot target the plot owner."
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

local function eject_players_from_plot(plot, reason)
    if not plot then
        return
    end
    local msg = trim(reason)
    for _, player in ipairs(minetest.get_connected_players()) do
        PM.kick_player_from_plot(player:get_player_name(), plot, msg)
    end
end

local function remove_build_access(plot, target)
    local ok, err = PM.set_access(plot, "add", target, false)
    if not ok then
        return false, err
    end
    ok, err = PM.set_access(plot, "trust", target, false)
    if not ok then
        return false, err
    end
    ok, err = PM.set_access(plot, "deny", target, false)
    if not ok then
        return false, err
    end
    return true
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

local function fs_escape(text)
    local s = tostring(text or "")
    if type(minetest.formspec_escape) == "function" then
        return minetest.formspec_escape(s)
    end
    s = s:gsub("\\", "\\\\")
    s = s:gsub("%]", "\\]")
    s = s:gsub("%[", "\\[")
    s = s:gsub(";", "\\;")
    s = s:gsub(",", "\\,")
    return s
end

local function queue_confirmation(player_name, action, plot, target_name)
    local ttl = math.max(10, tonumber((PM.config or {}).confirm_ttl_seconds) or 45)
    runtime.pending_confirm[player_name] = {
        action = tostring(action or ""),
        plot_id = as_int(plot and plot.id, 0),
        target = ensure_player_name(target_name),
        expires_at = os.time() + ttl,
    }

    local label = ""
    local detail = ""
    local plot_label = "plot #" .. plot_id_label(plot)
    if action == "delete" then
        label = "Delete " .. plot_label .. "?"
        detail = "This cannot be undone."
    elseif action == "clear" then
        label = "Clear " .. plot_label .. "?"
        detail = "This will reset the plot terrain."
    elseif action == "transfer" then
        label = "Transfer " .. plot_label .. "?"
        detail = "New owner: " .. tostring(target_name or "")
    else
        label = "Confirm action?"
    end

    local formname = PM.formname_confirm or "plots:confirm"
    local formspec = table.concat({
        "formspec_version[4]",
        "size[10,4]",
        "label[0.4,0.6;", fs_escape(label), "]",
        "label[0.4,1.3;", fs_escape(detail), "]",
        "button[1.7,2.7;2.8,0.9;confirm;Confirm]",
        "button[5.4,2.7;2.8,0.9;cancel;Cancel]",
    })
    minetest.show_formspec(player_name, formname, formspec)
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
        "/plot undeny <player>",
        "/plot deny <player>",
        "/plot kick <player>",
        "/plot transfer <player>",
        "/plot clear",
        "/plot delete",
    }, "\n")
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    local confirm_formname = PM.formname_confirm or "plots:confirm"
    if formname ~= confirm_formname then
        return
    end
    if not player or not player.is_player or not player:is_player() then
        return true
    end

    local name = player:get_player_name()
    local pending = runtime.pending_confirm[name]
    if not pending then
        return true
    end

    local pressed_confirm = fields.confirm ~= nil
    local pressed_cancel = fields.cancel ~= nil
    if pressed_cancel or (fields.quit and not pressed_confirm) then
        runtime.pending_confirm[name] = nil
        return true
    end
    if not pressed_confirm then
        return true
    end
    runtime.pending_confirm[name] = nil

    if os.time() > as_int(pending.expires_at, 0) then
        minetest.chat_send_player(name, "Confirmation expired. Run the command again.")
        return true
    end

    local plot = PM.get_plot(pending.plot_id)
    if not plot then
        minetest.chat_send_player(name, "Plot not found.")
        return true
    end
    if ensure_player_name(plot.owner) ~= name then
        minetest.chat_send_player(name, "You no longer own that plot.")
        return true
    end

    local ok = false
    local msg = "Unknown action."
    if pending.action == "delete" then
        ok, msg = PM.delete_plot(plot)
        if ok then
            eject_players_from_plot(plot, "")
        end
    elseif pending.action == "clear" then
        ok, msg = PM.clear_plot(plot)
        if ok then
            eject_players_from_plot(plot, "")
        end
    elseif pending.action == "transfer" then
        local target = ensure_player_name(pending.target)
        if target == "" then
            ok, msg = false, "Usage: /plot transfer <player>"
        elseif is_plot_owner_target(plot, target) then
            ok, msg = false, "You cannot target the plot owner."
        else
            local has_slot = false
            local slot_msg = ""
            has_slot, target, slot_msg = player_has_transfer_slot(name, target)
            if not has_slot then
                ok, msg = false, slot_msg
            else
                ok, msg = PM.transfer_plot_owner(plot, target)
                if ok then
                    local target_player = minetest.get_player_by_name(target)
                    if target_player then
                        minetest.chat_send_player(
                            target,
                            "You now own plot #" .. plot_id_label(plot) .. "."
                        )
                    end
                end
            end
        end
    end

    if msg and msg ~= "" then
        minetest.chat_send_player(name, msg)
    end
    return true
end)

minetest.register_on_leaveplayer(function(player)
    if not player or not player.is_player or not player:is_player() then
        return
    end
    runtime.pending_confirm[player:get_player_name()] = nil
end)

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
            queue_confirmation(name, "delete", plot)
            return true, "Delete confirmation opened."
        end

        if sub == "clear" then
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            queue_confirmation(name, "clear", plot)
            return true, "Clear confirmation opened."
        end

        if sub == "kick" then
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            return kick_target_from_plot(name, plot, words[2])
        end

        if sub == "deny" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot deny <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local ok, set_err = PM.set_access(plot, "deny", target, true)
            if not ok then
                return false, set_err
            end
            PM.kick_player_from_plot(target, plot, minetest.colorize("#ff7777", "You are denied from this plot."))
            return true, "Denied " .. target .. " from plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "add" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot add <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local ok, set_err = PM.set_access(plot, "add", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Added " .. target .. " to plot #" .. plot_id_label(plot) .. " (builds only while owner is on plot)."
        end

        if sub == "trust" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot trust <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local ok, set_err = PM.set_access(plot, "trust", target, true)
            if not ok then
                return false, set_err
            end
            return true, "Trusted " .. target .. " on plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "remove" or sub == "revoke" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot " .. sub .. " <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local ok, revoke_err = remove_build_access(plot, target)
            if not ok then
                return false, revoke_err
            end
            return true, "Removed add/trust/deny for " .. target .. " on plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "undeny" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot undeny <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local ok, set_err = PM.set_access(plot, "deny", target, false)
            if not ok then
                return false, set_err
            end
            return true, "Undenied " .. target .. " on plot #" .. plot_id_label(plot) .. "."
        end

        if sub == "transfer" then
            local target = ensure_player_name(words[2])
            if target == "" then
                return false, "Usage: /plot transfer <player>"
            end
            local plot, err = require_owner_plot_for_management(player)
            if not plot then
                return false, err
            end
            if is_plot_owner_target(plot, target) then
                return false, "You cannot target the plot owner."
            end
            local has_slot = false
            local slot_msg = ""
            has_slot, target, slot_msg = player_has_transfer_slot(name, target)
            if not has_slot then
                return false, slot_msg
            end
            queue_confirmation(name, "transfer", plot, target)
            return true, "Transfer confirmation opened."
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
