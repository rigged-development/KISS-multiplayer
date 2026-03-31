local M = {}
local imgui = ui_imgui

local context = {
  server_name = "Unknown server",
  missing_mods = {},
}

local function set_context(server_name, missing_mods)
  context.server_name = tostring(server_name or "Unknown server")
  context.missing_mods = {}

  if type(missing_mods) == "table" then
    for _, mod_name in ipairs(missing_mods) do
      table.insert(context.missing_mods, tostring(mod_name))
    end
  end
end

local function draw()
  if not kissui.show_mod_download_risk then
    return
  end

  local display_size = imgui.GetIO().DisplaySize
  imgui.SetNextWindowPos(
    imgui.ImVec2(display_size.x * 0.5, display_size.y * 0.5),
    imgui.Cond_Always,
    imgui.ImVec2(0.5, 0.5)
  )
  imgui.SetNextWindowSize(imgui.ImVec2(560, 360), imgui.Cond_Always)
  imgui.SetNextWindowBgAlpha(kissui.window_opacity[0])

  local flags = bit.bor(
    imgui.WindowFlags_NoResize,
    imgui.WindowFlags_NoCollapse,
    imgui.WindowFlags_NoSavedSettings
  )

  if imgui.Begin("Mod Download Risk Warning", nil, flags) then
    imgui.TextWrapped("This server requires missing mods to join:")
    imgui.TextWrapped(context.server_name)
    imgui.Separator()

    imgui.TextWrapped("Downloading mods from community servers can be risky. Only continue if you trust this server and its content.")
    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.Text(string.format("Missing mods: %d", #context.missing_mods))

    imgui.BeginChild1("MissingModsList", imgui.ImVec2(0, -112), true)
    for _, mod_name in ipairs(context.missing_mods) do
      imgui.BulletText(mod_name)
    end
    imgui.EndChild()

    local button_width = math.max(imgui.GetContentRegionAvailWidth(), 1)
    if imgui.Button("Accept and download", imgui.ImVec2(button_width, 0)) then
      network.accept_mod_download(false)
    end

    if imgui.Button("Accept for all servers", imgui.ImVec2(button_width, 0)) then
      network.accept_mod_download(true)
    end

    if imgui.Button("Decline and abort connection", imgui.ImVec2(button_width, 0)) then
      network.decline_mod_download()
    end
  end

  imgui.End()
end

M.set_context = set_context
M.draw = draw

return M

