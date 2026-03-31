local M = {}
local http = require("socket.http")

local bor = bit.bor

local main_window = require("kissmp.ui.main")
M.chat = require("kissmp.ui.chat")
M.download_window = require("kissmp.ui.download")
local names = require("kissmp.ui.names")

M.tabs = {
  server_list = require("kissmp.ui.tabs.server_list"),
  favorites = require("kissmp.ui.tabs.favorites"),
  settings = require("kissmp.ui.tabs.settings"),
  direct_connect = require("kissmp.ui.tabs.direct_connect"),
  create_server = require("kissmp.ui.tabs.create_server"),
}

M.dependencies = {"ui_imgui"}

local function default_master_servers()
  return {
    {
      id = "kissmp_official",
      alias = "KissMP Official",
      master_url = "http://kissmp.online:3692",
      master_p2p_host = "kissmp.online:3691",
      enabled_for_query = true,
    },
    {
      id = "beamapex",
      alias = "BeamApex",
      master_url = "http://152.53.82.215:3692",
      master_p2p_host = "152.53.82.215:3691",
      enabled_for_query = true,
    }
  }
end

local function sanitize_master_entry(entry)
  if type(entry) ~= "table" then return nil end

  local alias = tostring(entry.alias or ""):gsub("^%s*(.-)%s*$", "%1")
  local master_url = tostring(entry.master_url or ""):gsub("^%s*(.-)%s*$", "%1")
  local master_p2p_host = tostring(entry.master_p2p_host or ""):gsub("^%s*(.-)%s*$", "%1")
  local id = tostring(entry.id or ""):gsub("^%s*(.-)%s*$", "%1")
  local enabled_for_query = true
  if entry.enabled_for_query ~= nil then
    enabled_for_query = not not entry.enabled_for_query
  end

  if alias == "" or master_url == "" then
    return nil
  end
  if id == "" then
    id = alias:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if id == "" then
      id = "custom_master"
    end
  end

  return {
    id = id,
    alias = alias,
    master_url = master_url,
    master_p2p_host = master_p2p_host,
    enabled_for_query = enabled_for_query,
  }
end

M.master_servers = default_master_servers()
M.selected_master_id = "kissmp_official"
M.master_addr = "http://kissmp.online:3692"
M.master_p2p_host = "kissmp.online:3691"
M.aggregate_master_lists = true
M.bridge_launched = false

M.show_download = false
M.downloads_info = {}

-- Color constants
M.COLOR_YELLOW = {r = 1, g = 1, b = 0}
M.COLOR_RED = {r = 1, g = 0, b = 0}

M.force_disable_nametags = false

local gui_module = require("ge/extensions/editor/api/gui")
M.gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui

local ui_showing = false

-- TODO: Move all this somewhere else. Some of settings aren't even related to UI
M.addr = imgui.ArrayChar(128)
M.player_name = imgui.ArrayChar(32, "Unknown")
M.show_nametags = imgui.BoolPtr(true)
M.show_drivers = imgui.BoolPtr(true)
M.window_opacity = imgui.FloatPtr(0.8)
M.enable_view_distance = imgui.BoolPtr(true)
M.view_distance = imgui.IntPtr(300)
M.voice_range = imgui.FloatPtr(120)
M.voice_input_volume = imgui.FloatPtr(1.0)
M.voice_input_device = ""
M.voice_input_devices = {}
M.voice_player_volumes = {}
M.voice_curve_profile = "Balanced"
M.voice_curve_profiles = {"Realistic", "Balanced", "Arcade"}
M.voice_walkie_enabled = imgui.BoolPtr(true)
M.voice_frequency = imgui.IntPtr(0)
M.voice_noise_suppression = imgui.BoolPtr(true)
M.voice_echo_suppression = imgui.BoolPtr(true)
M.voice_noise_gate_strength = imgui.FloatPtr(0.5)
M.voice_echo_ducking_strength = imgui.FloatPtr(0.8)

-- Backwards compatibility aliases for older code/config keys.
M.voice_noise_suppression_level = M.voice_noise_gate_strength
M.voice_echo_suppression_level = M.voice_echo_ducking_strength

local function show_ui()
  M.gui.showWindow("KissMP")
  M.gui.showWindow("Chat")
  M.gui.showWindow("Downloads")
  ui_showing = true
end

local function hide_ui()
  M.gui.hideWindow("KissMP")
  M.gui.hideWindow("Chat")
  M.gui.hideWindow("Downloads")
  M.gui.hideWindow("Add Favorite")
  ui_showing = false
end

local function toggle_ui()
  if not ui_showing then
    show_ui()
  else
    hide_ui()
  end
end

local function open_ui()
  M.ensure_master_server_config()
  main_window.init(M)
  gui_module.initialize(M.gui)
  M.gui.registerWindow("KissMP", imgui.ImVec2(256, 256))
  M.gui.registerWindow("Chat", imgui.ImVec2(256, 256))
  M.gui.registerWindow("Downloads", imgui.ImVec2(512, 512))
  M.gui.registerWindow("Add Favorite", imgui.ImVec2(256, 128))
  M.gui.registerWindow("Incorrect install detected", imgui.ImVec2(256, 128))
  M.gui.hideWindow("Add Favorite")
  show_ui()
end

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function draw_incorrect_install()
  if imgui.Begin("Incorrect install detected") then
    imgui.Text("Incorrect KissMP install. Please, check if mod path is correct")
  end
  imgui.End()
end

local function onUpdate(dt)
  if getMissionFilename() ~= '' and not vehiclemanager.is_network_session then
    return
  end
  main_window.draw(dt)
  M.chat.draw()
  M.download_window.draw()
  if M.incorrect_install then
     draw_incorrect_install()
  end
  if (not M.force_disable_nametags) and M.show_nametags[0] then
    names.draw()
  end
end

function M.get_selected_master_server()
  for _, entry in ipairs(M.master_servers or {}) do
    if entry.id == M.selected_master_id then
      return entry
    end
  end
  return nil
end

function M.ensure_master_server_config()
  local defaults = default_master_servers()
  local by_id = {}
  local custom_order = {}

  local configured = {}
  if type(M.master_servers) == "table" then
    for _, raw_entry in ipairs(M.master_servers) do
      local entry = sanitize_master_entry(raw_entry)
      if entry and not by_id[entry.id] then
        by_id[entry.id] = entry
        if entry.id ~= "kissmp_official" and entry.id ~= "beamapex" then
          table.insert(custom_order, entry.id)
        end
      end
    end
  end

  for _, default_entry in ipairs(defaults) do
    if not by_id[default_entry.id] then
      by_id[default_entry.id] = sanitize_master_entry(default_entry)
    end
  end

  for _, default_entry in ipairs(defaults) do
    table.insert(configured, by_id[default_entry.id])
    by_id[default_entry.id] = nil
  end

  -- Keep custom entries in stable insertion order to avoid UI flicker.
  for _, id in ipairs(custom_order) do
    local entry = by_id[id]
    if entry then
      table.insert(configured, entry)
      by_id[id] = nil
    end
  end

  -- Fallback for unexpected leftovers (should be rare), keep deterministic output.
  local leftover_ids = {}
  for id, _ in pairs(by_id) do
    table.insert(leftover_ids, id)
  end
  table.sort(leftover_ids)
  for _, id in ipairs(leftover_ids) do
    table.insert(configured, by_id[id])
  end

  M.master_servers = configured

  local selected = M.get_selected_master_server()
  if not selected and #M.master_servers > 0 then
    M.selected_master_id = M.master_servers[1].id
    selected = M.master_servers[1]
  end

  if selected then
    M.master_addr = selected.master_url
    M.master_p2p_host = selected.master_p2p_host
  end
end

M.onExtensionLoaded = open_ui
M.onUpdate = onUpdate

-- Backwards compatability
M.add_message = M.chat.add_message
M.draw_download = M.download_window.draw

M.show_ui = show_ui
M.hide_ui = hide_ui
M.toggle_ui = toggle_ui

return M
