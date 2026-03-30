local M = {}
M.mods = {}

local function normalize_hash(value, algo)
  if not value or not algo then return nil end
  local s = string.lower(tostring(value))
  s = s:gsub("^" .. algo .. "[:=]", "")
  if algo == "crc32" then
    s = s:gsub("^crc[:=]", "")
  end
  s = s:gsub("[^0-9a-f]", "")

  local expected_len = nil
  if algo == "sha1" then
    expected_len = 40
  elseif algo == "crc32" then
    expected_len = 8
  end

  if expected_len and #s == expected_len then
    return s
  end
  return nil
end

local function parse_server_hash(value)
  if not value then return nil, nil end
  local s = string.lower(tostring(value))
  local algo, raw = s:match("^([a-z0-9_%-]+)[:=](.+)$")

  if not algo then
    raw = s
    if raw:match("^[0-9a-f]+$") and #raw == 8 then
      algo = "crc32"
    elseif raw:match("^[0-9a-f]+$") and #raw == 40 then
      algo = "sha1"
    else
      return nil, nil
    end
  end

  if algo == "crc" then
    algo = "crc32"
  end

  return algo, normalize_hash(raw, algo)
end

local function get_file_hash(path, algo)
  if algo == "sha1" and type(hashFileSHA1) == "function" then
    return normalize_hash(hashFileSHA1(path), algo)
  elseif type(hashFile) == "function" then
    return normalize_hash(hashFile(path, algo) or hashFile(path), algo)
  elseif FS and type(FS.hashFile) == "function" then
    return normalize_hash(FS:hashFile(path, algo) or FS:hashFile(path), algo)
  end
  return nil
end

local function build_local_size_index()
  local size_index = {}
  local candidates = {}

  for _, p in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    candidates[p] = true
  end
  for _, p in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    candidates[p] = true
  end

  for path, _ in pairs(candidates) do
    local stat = FS:stat(path)
    if stat and stat.filesize then
      local size_key = tonumber(stat.filesize)
      if size_key and not size_index[size_key] then
        size_index[size_key] = path
      end
    end
  end

  return size_index
end

local function build_local_hash_index(algo)
  local hash_index = {}
  local candidates = {}

  for _, p in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    candidates[p] = true
  end
  for _, p in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    candidates[p] = true
  end

  for path, _ in pairs(candidates) do
    local h = get_file_hash(path, algo)
    if h then
      if not hash_index[h] then
        hash_index[h] = path
      end
    end
  end

  return hash_index
end

local function is_special_mod(mod_path)
  local special_mods = {"kissmultiplayer.zip", "translations.zip"}
  local mod_path_lower = string.lower(mod_path)
  for _, special_mod in pairs(special_mods) do
    if string.endswith(mod_path_lower, special_mod) then
      return true
    end
  end
  return false
end

local function get_mod_name(name)
  local name = string.lower(name)
  name = name:gsub('.zip$', '')
  return "kissmp_mods"..name
end

local function deactivate_mod(name)
  local filename = "/kissmp_mods/"..name
  if FS:isMounted(filename) then
    FS:unmount(filename)
  end
  core_vehicles.clearCache()
end

local function is_app_mod(path)
  local pattern = "([^/]+)%.zip$"
  if string.sub(path, -4) ~= ".zip" then
      pattern = "([^/]+)$"
  end
  
  path = string.match(path, pattern)
  local mod = core_modmanager.getModDB(path)
  if not mod then return false end

  return mod.modType == "app"
end

local function deactivate_all_mods()
  for k, mod_path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    if not is_special_mod(mod_path) and not is_app_mod(mod_path) then
      FS:unmount(string.lower(mod_path))
    end
  end
  for k, mod_path in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    FS:unmount(mod_path)
  end
  for k, mod_path in pairs(FS:directoryList("/mods/unpacked/", "*", 1)) do
    if not is_app_mod(mod_path) then
      FS:unmount(mod_path.."/")
    end
  end
  core_vehicles.clearCache()
end

local function mount_mod(name)
  --local mode = mode or "added"
  --extensions.core_modmanager.workOffChangedMod("/kissmp_mods/"..name, mode)
  if FS:fileExists("/kissmp_mods/"..name) then
    FS:mount("/kissmp_mods/"..name)
  else
    files = FS:findFiles("/mods/", name, 1000)
    if files[1] then
      FS:mount(files[1])
    else
      local mod_data = M.mods[name]
      if mod_data and mod_data.local_path and FS:fileExists(mod_data.local_path) then
        FS:mount(mod_data.local_path)
      else
        kissui.chat.add_message("Failed to mount mod "..name..", file not found", kissui.COLOR_RED)
      end
    end
  end
  core_vehicles.clearCache()
end

local function mount_mods(list)
  for _, mod in pairs(list) do
    -- Demount mod in case it was mounted before, to refresh it
    deactivate_mod(mod)
    mount_mod(mod)
    --activate_mod(mod)
  end
  core_vehicles.clearCache()
end

local function update_status(mod, local_hash_index_by_algo, local_size_index)
  mod.debug_reason = nil
  mod.local_hash = nil
  mod.local_path = nil

  local search_results = FS:findFiles("/kissmp_mods/", mod.name, 1)
  local search_results2 = FS:findFiles("/mods/", mod.name, 99)

  for _, v in pairs(search_results2) do
    table.insert(search_results, v)
  end
  
  local server_algo, server_hash = parse_server_hash(mod.hash)
  local local_hash_index = nil
  if server_algo and local_hash_index_by_algo then
    local_hash_index = local_hash_index_by_algo[server_algo]
  end

  if not search_results[1] then
    if server_hash and local_hash_index then
      local hash_key = server_hash
      local hash_match_path = local_hash_index[hash_key]
      if hash_match_path then
        mod.status = "ok"
        mod.debug_reason = "hash_match_renamed"
        mod.local_hash = hash_key
        mod.local_path = hash_match_path
        return
      end
    end

    -- If hashes cannot be compared reliably, use file size as a rename fallback.
    if local_size_index and mod.size then
      local size_match_path = local_size_index[tonumber(mod.size)]
      if size_match_path then
        mod.status = "ok"
        mod.debug_reason = "size_match_renamed"
        mod.local_path = size_match_path
        return
      end
    end

    mod.status = "missing"
    mod.debug_reason = "file_not_found"
  else
    mod.local_path = search_results[1]
    if server_hash then
      local local_hash = get_file_hash(search_results[1], server_algo)

      mod.local_hash = local_hash

      if local_hash and local_hash == server_hash then
        mod.status = "ok"
        mod.debug_reason = "hash_match"
      else
        local hash_match_path = nil
        if local_hash_index then
          hash_match_path = local_hash_index[server_hash]
        end

        if hash_match_path then
          mod.status = "ok"
          mod.debug_reason = "hash_match_renamed"
          mod.local_hash = server_hash
          mod.local_path = hash_match_path
        else
          -- Fallback for environments where BeamNG hash APIs use a different digest format.
          local len = FS:stat(search_results[1]).filesize
          if len == mod.size then
            mod.status = "ok"
            mod.debug_reason = "hash_mismatch_size_match"
          else
            mod.status = "different"
            if local_hash then
              mod.debug_reason = "hash_mismatch"
            else
              mod.debug_reason = "hash_unavailable"
            end
          end
        end
      end
      return
    end

    local len = FS:stat(search_results[1]).filesize
    if len ~= mod.size then
      mod.status = "different"
      mod.debug_reason = "size_mismatch"
    else
      mod.status = "ok"
      mod.debug_reason = "size_match"
    end
  end
end

local function update_status_all()
  local local_hash_index = {
    sha1 = build_local_hash_index("sha1"),
    crc32 = build_local_hash_index("crc32"),
  }
  local local_size_index = build_local_size_index()
  for name, mod in pairs(M.mods) do
    update_status(mod, local_hash_index, local_size_index)
  end
end

local function set_mods_list(mod_list)
  M.mods = {}
  for _, mod in pairs(mod_list) do
    local mod_name = mod[1]
    local mod_table = {
      name = mod_name,
      size = mod[2],
      hash = mod[3],
      status = "unknown"
    }
    M.mods[mod_name] = mod_table
  end
end

local function open_file(name)
  if not string.endswith(name, ".zip") then return end
  if not FS:directoryExists("/kissmp_mods/") then
    FS:directoryCreate("/kissmp_mods/")
  end
  local path = "/kissmp_mods/"..name
  print(path)
  local file = io.open(path, "wb")
  return file
end

M.open_file = open_file
M.check_mods = check_mods
M.is_special_mod = is_special_mod
M.mount_mod = mount_mod
M.mount_mods = mount_mods
M.deactivate_all_mods = deactivate_all_mods
M.set_mods_list = set_mods_list
M.update_status_all = update_status_all
M.update_status = update_status

return M
