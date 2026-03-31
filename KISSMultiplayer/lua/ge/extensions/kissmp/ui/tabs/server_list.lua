local M = {}
local imgui = ui_imgui
local http = require("socket.http")

local filter_servers_notfull = imgui.BoolPtr(false)
local filter_servers_notempty = imgui.BoolPtr(false)
local filter_servers_online = imgui.BoolPtr(false)

local prev_search_text = ""
local prev_filter_notfull = false
local prev_filter_notempty = false
local prev_filter_online = false

local search_buffer = imgui.ArrayChar(64)
local time_since_filters_change = 0
local filter_queued = false

local filtered_servers = {}
local filtered_favorite_servers = {}
local next_bridge_status_update = 0
local add_master_alias = imgui.ArrayChar(64)
local add_master_url = imgui.ArrayChar(256)
local add_master_p2p_host = imgui.ArrayChar(128)
local add_master_error = nil
local edit_master_alias = imgui.ArrayChar(64)
local edit_master_url = imgui.ArrayChar(256)
local edit_master_p2p_host = imgui.ArrayChar(128)
local edit_master_error = nil
local edit_master_loaded_id = nil
local refresh_job_id = nil
local refresh_job_elapsed = 0
local refresh_poll_elapsed = 0
local refresh_poll_interval = 0.15
local refresh_job_timeout_seconds = 20
local refresh_poll_failures = 0
local refresh_last_state = nil
local refresh_last_logged_error = nil
M.refresh_in_progress = false
M.last_refresh_stats = nil

local refresh_server_list

local function http_request_with_timeout(url, timeout_seconds)
  local previous_timeout = http.TIMEOUT
  http.TIMEOUT = timeout_seconds
  local body, code, headers, status_line = http.request(url)
  http.TIMEOUT = previous_timeout
  return body, code, headers, status_line
end

local function url_encode(text)
  return (tostring(text):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function log_refresh(message)
  print("[KissMP][ServerList] " .. tostring(message))
end

M.server_list = {}
M.last_master_error = nil
M.last_master_status = nil

-- Server list update and search
-- spairs from https://stackoverflow.com/a/15706820
local function spairs(t, order)
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  if order then
    table.sort(keys, function(a,b) return order(t, a, b) end)
  else
    table.sort(keys)
  end
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

local function filter_server_list(list, term, filter_notfull, filter_notempty, filter_online, m)
  local kissui = kissui or m
  local return_servers = {}

  local term_trimmed = term:gsub("^%s*(.-)%s*$", "%1")
  local term_lower = term_trimmed:lower()
  local textual_search = term_trimmed:len() > 0

  for addr, server in pairs(list) do
    local server_from_list = M.server_list[addr]
    local server_found_in_list = server_from_list ~= nil

    local discard = false
    if textual_search and not discard then
      local name_lower = server.name:lower()
      discard = discard or not string.find(name_lower, term_lower)
    end
    if filter_notfull and server_found_in_list and not discard then
      discard = discard or server_from_list.player_count >= server_from_list.max_players
    end
    if filter_notempty and server_found_in_list and not discard then
      discard = discard or server_from_list.player_count == 0
    end
    if filter_online and not discard then
      discard = discard or not server_found_in_list
    end

    if not discard then
      return_servers[addr] = server
    end
  end

  return return_servers
end

local function update_filtered_servers(m)
  local kissui = kissui or m
  local term = ffi.string(search_buffer)
  local filter_notfull = filter_servers_notfull[0]
  local filter_notempty = filter_servers_notempty[0]
  local filter_online = filter_servers_online[0]

  filtered_servers = filter_server_list(M.server_list, term, filter_notfull, filter_notempty, filter_online, m)
  --filtered_favorite_servers = filter_server_list(kissui.tabs.favorites.favorite_servers, term, filter_notfull, filter_online, m)
end

local function get_master_version_path()
  local version = "latest"
  if network and type(network.VERSION_STR) == "string" and network.VERSION_STR ~= "" then
    version = network.VERSION_STR
  end

  version = tostring(version):gsub("^/+", ""):gsub("/+$", "")
  if version == "" then
    version = "latest"
  end
  return version
end

local function collect_target_masters(kissui)
  if kissui.ensure_master_server_config then
    kissui.ensure_master_server_config()
  end

  local masters = {}
  local seen = {}
  for _, entry in ipairs(kissui.master_servers or {}) do
    local enabled = true
    if entry.enabled_for_query ~= nil then
      enabled = not not entry.enabled_for_query
    end
    local url = tostring(entry.master_url or "")
      :gsub("^%s*(.-)%s*$", "%1")
      :gsub("/+$", "")
    if enabled and url ~= "" and not seen[url] then
      seen[url] = true
      table.insert(masters, url)
    end
  end

  if #masters == 0 then
    local selected_master = nil
    if kissui.get_selected_master_server then
      selected_master = kissui.get_selected_master_server()
    end
    local url = tostring((selected_master and selected_master.master_url) or kissui.master_addr or "")
      :gsub("^%s*(.-)%s*$", "%1")
      :gsub("/+$", "")
    if url ~= "" then
      table.insert(masters, url)
    end
  end

  return masters
end

local function build_batch_start_url(kissui)
  local payload = {
    masters = collect_target_masters(kissui),
    version = get_master_version_path(),
  }
  return "http://127.0.0.1:3693/master_batch/start/" .. url_encode(jsonEncode(payload))
end

local function poll_refresh_job(dt, m)
  if not M.refresh_in_progress or not refresh_job_id then
    return
  end

  refresh_job_elapsed = refresh_job_elapsed + dt
  refresh_poll_elapsed = refresh_poll_elapsed + dt

  if refresh_job_elapsed > refresh_job_timeout_seconds then
    M.refresh_in_progress = false
    refresh_job_id = nil
    M.last_master_error = "Master request timed out"
    local kissui = kissui or m
    kissui.bridge_launched = false
    return
  end

  if refresh_poll_elapsed < refresh_poll_interval then
    return
  end
  refresh_poll_elapsed = 0

  local status_url = "http://127.0.0.1:3693/master_batch/status/" .. tostring(refresh_job_id)
  local body, code, _, _ = http_request_with_timeout(status_url, 1.0)
  if not body then
    refresh_poll_failures = refresh_poll_failures + 1
    M.last_master_error = "Master status polling failed: " .. tostring(code)
    if M.last_master_error ~= refresh_last_logged_error then
      log_refresh("poll failed for request_id=" .. tostring(refresh_job_id) .. " code=" .. tostring(code))
      refresh_last_logged_error = M.last_master_error
    end
    if refresh_poll_failures >= 8 then
      M.refresh_in_progress = false
      local kissui = kissui or m
      kissui.bridge_launched = false
      refresh_job_id = nil
      M.last_master_error = "Master status polling failed too often"
      log_refresh("aborting refresh after repeated polling failures")
    end
    return
  end
  refresh_poll_failures = 0

  local decoded = jsonDecode(body)
  if not decoded then
    M.last_master_error = "Master status returned invalid JSON"
    if M.last_master_error ~= refresh_last_logged_error then
      log_refresh("poll returned invalid JSON for request_id=" .. tostring(refresh_job_id) .. " body=" .. tostring(body))
      refresh_last_logged_error = M.last_master_error
    end
    return
  end

  if decoded.state ~= refresh_last_state then
    log_refresh("request_id=" .. tostring(refresh_job_id) .. " state=" .. tostring(decoded.state))
    refresh_last_state = decoded.state
  end

  if decoded.state == "pending" then
    return
  end

  if decoded.state == "missing" then
    M.refresh_in_progress = false
    refresh_job_id = nil
    M.last_master_error = "Master request job expired"
    return
  end

  if decoded.state == "done" then
    M.refresh_in_progress = false
    refresh_job_id = nil
    local kissui = kissui or m
    kissui.bridge_launched = true

    M.last_refresh_stats = {
      masters_ok = tonumber(decoded.masters_ok) or 0,
      masters_total = tonumber(decoded.masters_total) or 0,
    }

    local server_list = decoded.server_list
    if type(server_list) == "table" then
      M.server_list = server_list
      update_filtered_servers(kissui)
      local server_count = 0
      for _ in pairs(server_list) do server_count = server_count + 1 end
      log_refresh(
        "request_id done; servers="
          .. tostring(server_count)
          .. ", masters_ok="
          .. tostring(M.last_refresh_stats.masters_ok)
          .. "/"
          .. tostring(M.last_refresh_stats.masters_total)
      )
    else
      M.last_master_error = "Master batch result missing server_list"
      if M.last_master_error ~= refresh_last_logged_error then
        log_refresh("done result missing server_list for request_id=" .. tostring(refresh_job_id))
        refresh_last_logged_error = M.last_master_error
      end
      return
    end

    if type(decoded.errors) == "table" and #decoded.errors > 0 then
      M.last_master_error = table.concat(decoded.errors, " | ")
      log_refresh("request_id done with partial errors: " .. tostring(M.last_master_error))
    else
      M.last_master_error = nil
      refresh_last_logged_error = nil
    end
    return
  end

  M.last_master_error = "Unexpected master job state: " .. tostring(decoded.state)
  if M.last_master_error ~= refresh_last_logged_error then
    log_refresh(M.last_master_error)
    refresh_last_logged_error = M.last_master_error
  end
end

local function current_master_alias(kissui)
  if kissui.get_selected_master_server then
    local selected = kissui.get_selected_master_server()
    if selected then
      return tostring(selected.alias or selected.master_url or "Unknown")
    end
  end
  return "Unknown"
end

local function find_master_by_id(master_servers, id)
  for _, entry in ipairs(master_servers or {}) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

local function is_protected_master_id(id)
  return id == "kissmp_official" or id == "beamapex"
end

local function select_fallback_master(kissui)
  local official = find_master_by_id(kissui.master_servers, "kissmp_official")
  if official then
    return official.id
  end
  if kissui.master_servers and #kissui.master_servers > 0 then
    return kissui.master_servers[1].id
  end
  return nil
end

local function load_edit_buffers_from_selected(selected)
  edit_master_alias = imgui.ArrayChar(64, tostring(selected.alias or ""))
  edit_master_url = imgui.ArrayChar(256, tostring(selected.master_url or ""))
  edit_master_p2p_host = imgui.ArrayChar(128, tostring(selected.master_p2p_host or ""))
  edit_master_loaded_id = selected.id
  edit_master_error = nil
end

local function make_unique_master_id(alias, master_servers)
  local base = tostring(alias or "")
    :lower()
    :gsub("[^%w]+", "_")
    :gsub("^_+", "")
    :gsub("_+$", "")

  if base == "" then
    base = "custom_master"
  end

  local candidate = base
  local counter = 1
  while find_master_by_id(master_servers, candidate) do
    candidate = base .. "_" .. tostring(counter)
    counter = counter + 1
  end
  return candidate
end

local function draw_master_selector(m)
  local kissui = kissui or m
  if kissui.ensure_master_server_config then
    kissui.ensure_master_server_config()
  end

  imgui.Text("Master Server:")
  if imgui.BeginCombo("##master_server_select", current_master_alias(kissui)) then
    for i, entry in ipairs(kissui.master_servers or {}) do
      local selected = (entry.id == kissui.selected_master_id)
      local label = tostring(entry.alias) .. "###master_server_" .. tostring(i)
      if imgui.Selectable1(label, selected) then
        kissui.selected_master_id = entry.id
        if kissui.ensure_master_server_config then
          kissui.ensure_master_server_config()
        end
        kissconfig.save_config()
        refresh_server_list(kissui)
        update_filtered_servers(kissui)
      end
    end
    imgui.EndCombo()
  end

  local selected = nil
  if kissui.get_selected_master_server then
    selected = kissui.get_selected_master_server()
  end

  if selected then
    imgui.Text("URL: " .. tostring(selected.master_url or ""))
  end

  imgui.Text("List Sources")
  for i, entry in ipairs(kissui.master_servers or {}) do
    local enabled = true
    if entry.enabled_for_query ~= nil then
      enabled = not not entry.enabled_for_query
    end
    local enabled_ptr = imgui.BoolPtr(enabled)
    local label = tostring(entry.alias or entry.id or "Master") .. "###master_source_enabled_" .. tostring(i)
    if imgui.Checkbox(label, enabled_ptr) then
      entry.enabled_for_query = enabled_ptr[0]
      kissconfig.save_config()
      refresh_server_list(kissui)
    end
  end

  if imgui.CollapsingHeader1("Master Server Management###master_server_management") then
    if selected then
      if edit_master_loaded_id ~= selected.id then
        load_edit_buffers_from_selected(selected)
      end

      imgui.Text("Edit Selected Master")
      if is_protected_master_id(selected.id) then
        imgui.Text("This default entry is read-only and can not be deleted")
      else
        imgui.InputText("Alias##edit_master_alias", edit_master_alias)
        imgui.InputText("Master URL##edit_master_url", edit_master_url)
        imgui.InputText("Master P2P Host##edit_master_p2p", edit_master_p2p_host)

        if imgui.Button("Save Changes##save_master_changes") then
          local alias = tostring(ffi.string(edit_master_alias)):gsub("^%s*(.-)%s*$", "%1")
          local master_url = tostring(ffi.string(edit_master_url)):gsub("^%s*(.-)%s*$", "%1")
          local master_p2p_host = tostring(ffi.string(edit_master_p2p_host)):gsub("^%s*(.-)%s*$", "%1")

          if alias == "" then
            edit_master_error = "Alias darf nicht leer sein"
          elseif master_url == "" then
            edit_master_error = "Master URL darf nicht leer sein"
          else
            selected.alias = alias
            selected.master_url = master_url
            selected.master_p2p_host = master_p2p_host
            if kissui.ensure_master_server_config then
              kissui.ensure_master_server_config()
            end
            kissconfig.save_config()
            edit_master_error = nil
            refresh_server_list(kissui)
            update_filtered_servers(kissui)
          end
        end

        imgui.SameLine()
        if imgui.Button("Delete##delete_master") then
          for i = #kissui.master_servers, 1, -1 do
            if kissui.master_servers[i].id == selected.id then
              table.remove(kissui.master_servers, i)
              break
            end
          end
          kissui.selected_master_id = select_fallback_master(kissui)
          if kissui.ensure_master_server_config then
            kissui.ensure_master_server_config()
          end
          kissconfig.save_config()
          edit_master_loaded_id = nil
          edit_master_error = nil
          refresh_server_list(kissui)
          update_filtered_servers(kissui)
        end

        if edit_master_error then
          imgui.Text("Fehler: " .. tostring(edit_master_error))
        end
      end
    end

    imgui.Separator()
    imgui.Text("Add Master Server")
    imgui.InputText("Alias##master_alias", add_master_alias)
    imgui.InputText("Master URL##master_url", add_master_url)
    imgui.InputText("Master P2P Host##master_p2p", add_master_p2p_host)

    if imgui.Button("Add Master##add_master") then
      local alias = tostring(ffi.string(add_master_alias)):gsub("^%s*(.-)%s*$", "%1")
      local master_url = tostring(ffi.string(add_master_url)):gsub("^%s*(.-)%s*$", "%1")
      local master_p2p_host = tostring(ffi.string(add_master_p2p_host)):gsub("^%s*(.-)%s*$", "%1")

      if alias == "" then
        add_master_error = "Alias darf nicht leer sein"
      elseif master_url == "" then
        add_master_error = "Master URL darf nicht leer sein"
      else
        local id = make_unique_master_id(alias, kissui.master_servers)
        table.insert(kissui.master_servers, {
          id = id,
          alias = alias,
          master_url = master_url,
          master_p2p_host = master_p2p_host,
          enabled_for_query = true,
        })
        kissui.selected_master_id = id
        if kissui.ensure_master_server_config then
          kissui.ensure_master_server_config()
        end
        kissconfig.save_config()
        add_master_alias = imgui.ArrayChar(64)
        add_master_url = imgui.ArrayChar(256)
        add_master_p2p_host = imgui.ArrayChar(128)
        add_master_error = nil
        refresh_server_list(kissui)
        update_filtered_servers(kissui)
      end
    end

    if add_master_error then
      imgui.Text("Fehler: " .. tostring(add_master_error))
    end
  end

  imgui.Separator()
end

refresh_server_list = function(m)
  local kissui = kissui or m
  local target_masters = collect_target_masters(kissui)
  if #target_masters == 0 then
    M.last_master_error = "No master servers configured"
    log_refresh("refresh requested without any target masters")
    return
  end

  log_refresh("starting async refresh; masters=" .. table.concat(target_masters, ", "))

  local start_url = build_batch_start_url(kissui)
  local body, code, _, status_line = http_request_with_timeout(start_url, 1.2)
  M.last_master_status = status_line

  if not body then
    kissui.bridge_launched = false
    M.last_master_error = "Could not start async master request: " .. tostring(code)
    log_refresh("failed to start async refresh: " .. tostring(code))
    return
  end

  local decoded = jsonDecode(body)
  if not decoded or type(decoded.request_id) ~= "string" then
    kissui.bridge_launched = false
    M.last_master_error = "Invalid async start response"
    log_refresh("invalid start response body=" .. tostring(body))
    return
  end

  refresh_job_id = decoded.request_id
  refresh_job_elapsed = 0
  refresh_poll_elapsed = 0
  refresh_poll_failures = 0
  refresh_last_state = nil
  refresh_last_logged_error = nil
  M.refresh_in_progress = true
  M.last_master_error = nil
  M.last_refresh_stats = nil
  log_refresh("started request_id=" .. tostring(refresh_job_id))
end

local function draw_list_search_and_filters(show_online_filter)
  imgui.Text("Search:")
  imgui.SameLine()
  imgui.PushItemWidth(-1)
  imgui.InputText("##server_search", search_buffer)
  imgui.PopItemWidth()

  imgui.Text("Filters:")
  imgui.SameLine()

  imgui.Checkbox("Not Full", filter_servers_notfull)

  imgui.SameLine()

  imgui.Checkbox("Not Empty", filter_servers_notempty)

  if show_online_filter then
    imgui.SameLine()
    imgui.Checkbox("Online", filter_servers_online)
  end
end

local function draw_server_description(description)
  local min_height = 64
  local rect_color = imgui.GetColorU322(imgui.ImVec4(0.15, 0.15, 0.15, 1))

  local bg_size = imgui.CalcTextSize(description, nil, false, imgui.GetWindowContentRegionWidth())
  bg_size.y = math.max(min_height, bg_size.y)
  bg_size.x = imgui.GetWindowContentRegionWidth()

  local cursor_pos_before = imgui.GetCursorPos()
  imgui.Dummy(bg_size)
  local r_min = imgui.GetItemRectMin()
  local r_max = imgui.GetItemRectMax()
  local cursor_pos_after = imgui.GetCursorPos()

  imgui.ImDrawList_AddRectFilled(imgui.GetWindowDrawList(), r_min, r_max, rect_color)

  imgui.SetCursorPos(cursor_pos_before)
  imgui.Text(description)
  imgui.SetCursorPos(cursor_pos_after)
  imgui.Spacing(2)
end

local function draw(dt)
  -- Search update
  local search_text = ffi.string(search_buffer)
  local filter_notfull = filter_servers_notfull[0]
  local filter_notempty = filter_servers_notempty[0]
  local filter_online = filter_servers_online[0]

  if search_text ~= prev_search_text or filter_notfull ~= prev_filter_notfull or filter_notempty ~= prev_filter_notempty or filter_online ~= prev_filter_online then
    time_since_filters_change = 0
    filter_queued = true
  end

  prev_search_text = search_text
  prev_filter_notfull = filter_notfull
  prev_filter_notempty = filter_notempty
  prev_filter_online = filter_online

  if time_since_filters_change > 0.5 and filter_queued then
    update_filtered_servers()
    filter_queued = false
  end

  time_since_filters_change = time_since_filters_change + dt
  poll_refresh_job(dt)

  draw_master_selector()
  draw_list_search_and_filters(false)

  local server_count = 0

  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
  for addr, server in spairs(filtered_servers, function(t,a,b) return t[a].player_count > t[b].player_count end) do
    server_count = server_count + 1

    local header = server.name.." ["..server.player_count.."/"..server.max_players.."]"
    header = header .. "###server_header_"..tostring(server_count)

    if imgui.CollapsingHeader1(header) then
      imgui.PushTextWrapPos(0)
      imgui.Text("Address: "..addr)
      imgui.Text("Map: "..server.map)
      draw_server_description(server.description)
      imgui.PopTextWrapPos()
      if imgui.Button("Connect###connect_button_" .. tostring(server_count)) then
        kissconfig.save_config()
        local player_name = ffi.string(kissui.player_name)
        network.connect(addr, player_name, true)
      end

      local in_favorites_list = kissui.tabs.favorites.favorite_servers[addr] ~= nil
      if not in_favorites_list then
        imgui.SameLine()
        if imgui.Button("Add to Favorites###add_favorite_button_" .. tostring(server_count)) then
          kissui.tabs.favorites.add_server_to_favorites(addr, server)
          update_filtered_servers()
        end
      end
    end
  end

  imgui.PushTextWrapPos(0)
  if M.refresh_in_progress then
    imgui.Text("Refreshing server list asynchronously...")
  elseif not kissui.bridge_launched then
    imgui.Text("Bridge is not launched. Please, launch the bridge and then hit 'Refresh list' button")
  elseif M.last_master_error then
    imgui.Text("Could not refresh server list: " .. tostring(M.last_master_error))
  elseif M.last_refresh_stats and M.last_refresh_stats.masters_total and M.last_refresh_stats.masters_total > 1 then
    imgui.Text(
      "Loaded masters: "
        .. tostring(M.last_refresh_stats.masters_ok)
        .. "/"
        .. tostring(M.last_refresh_stats.masters_total)
    )
  elseif server_count == 0 then
    imgui.Text("Server list is empty")
  end
  imgui.PopTextWrapPos()

  imgui.EndChild()

  if imgui.Button("Refresh List", imgui.ImVec2(-1, 0)) then
    refresh_server_list()
  end
end

M.draw = draw
M.refresh = refresh_server_list
M.update_filtered = update_filtered_servers

return M
