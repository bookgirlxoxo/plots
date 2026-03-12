local PM = rawget(_G, "plots_mod")
if type(PM) ~= "table" then
    return
end

local C = PM._core
if type(C) ~= "table" then
    C = {}
    PM._core = C
end

C.SAVE_KEY = "plots_state"
C.PLOT_TP_GRACE_KEY = "plots:tp_grace_until"
C.PLOT_TP_GRACE_SECONDS = 20
C.PREGEN_SIGNATURE_REV = 4

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

local function round_int(v)
    return math.floor((tonumber(v) or 0) + 0.5)
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
    if shape == "square" or shape == "sphere" then
        return shape
    end
    local fb = trim(fallback):lower()
    if fb == "square" or fb == "sphere" then
        return fb
    end
    return "square"
end

local function get_player_priv_table(name)
    local player_name = ensure_player_name(name)
    if player_name == "" then
        return {}
    end

    local online = minetest.get_player_by_name(player_name)
    if online then
        return minetest.get_player_privs(player_name)
    end

    local handler = minetest.get_auth_handler and minetest.get_auth_handler()
    if not handler or not handler.get_auth then
        return {}
    end

    local auth = handler.get_auth(player_name)
    if not auth or type(auth.privileges) ~= "table" then
        return {}
    end
    return auth.privileges
end

local function player_has_priv(player_name, priv_name)
    if player_name == "" or priv_name == "" then
        return false
    end
    return get_player_priv_table(player_name)[priv_name] == true
end

local function player_has_plot_admin_others(player_name)
    return player_has_priv(player_name, "plots.admin.others")
end

local function player_has_plot_admin_road(player_name)
    return player_has_priv(player_name, "plots.admin.road")
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

C.now = now
C.trim = trim
C.as_int = as_int
C.round_int = round_int
C.copy_vec3 = copy_vec3
C.ensure_player_name = ensure_player_name
C.ensure_access_table = ensure_access_table
C.sanitize_shape = sanitize_shape
C.get_player_priv_table = get_player_priv_table
C.player_has_priv = player_has_priv
C.player_has_plot_admin_others = player_has_plot_admin_others
C.player_has_plot_admin_road = player_has_plot_admin_road
C.read_text = read_text
