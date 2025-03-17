local LPM = {
  config = {
    registry_url = "https://zhrexx.github.io/files/lush_registry.json",
    install_dir = "lpm_packages/",
    bundle_dir = "lpm_bundle/",
    cache_dir = ".lpm_cache/",
    output_file = "luac.out",
    config_file = "lpm.config",
    log_level = "info",
  },
  
  registry = nil,
  cache = {},
  
  log_config = {
    levels = {debug = 1, info = 2, warn = 3, error = 4},
    colors = {debug = "\27[36m", info = "\27[32m", warn = "\27[33m", error = "\27[31m"},
    reset = "\27[0m",
  }
}

function LPM:log(level, message, ...)
  if self.log_config.levels[level] >= self.log_config.levels[self.config.log_level] then
    local formatted = string.format(message, ...)
    print(self.log_config.colors[level] .. "[" .. level:upper() .. "]" .. self.log_config.reset .. " " .. formatted)
  end
end

function LPM:ensure_directory(path)
  local success = os.execute("mkdir -p " .. path)
  if not success then
    self:log("error", "Failed to create directory: %s", path)
    return false
  end
  return true
end

function LPM:file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

function LPM:read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    self:log("error", "Failed to open file: %s (%s)", path, err)
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

function LPM:write_file(path, content)
  local file, err = io.open(path, "wb")
  if not file then
    self:log("error", "Failed to write to file: %s (%s)", path, err)
    return false
  end
  file:write(content)
  file:close()
  return true
end

function LPM:execute(command)
  self:log("debug", "Executing: %s", command)
  local handle = io.popen(command .. " 2>&1", "r")
  if not handle then
    self:log("error", "Failed to execute command: %s", command)
    return nil
  end
  local result = handle:read("*a")
  local success = handle:close()
  if not success then
    self:log("error", "Command failed: %s", command)
    self:log("debug", "Output: %s", result)
    return nil
  end
  return result
end

function LPM:json_decode(str)
  local success, json = pcall(require, "cjson")
  if success then
    local success, result = pcall(json.decode, str)
    if success then
      return result
    end
  end
  
  local function parse_value(s, start)
    s = s:match("^%s*(.-)%s*$", start)
    
    local first_char = s:sub(1, 1)
    if first_char == '"' then
      local value, end_pos = s:match('^"([^"]*)"()', 1)
      return value, end_pos
    end
    
    local num, end_pos = s:match('^(-?%d+%.?%d*)()', 1)
    if num then return tonumber(num), end_pos end
    
    if s:sub(1, 4) == "true" then return true, 5 end
    if s:sub(1, 5) == "false" then return false, 6 end
    
    if s:sub(1, 4) == "null" then return nil, 5 end
    
    if first_char == '{' then
      local obj = {}
      local pos = 2
      while true do
        local c = s:match("^%s*(.)", pos)
        if c == '}' then return obj, pos + 1 end
        if c ~= '"' then pos = pos + 1 goto continue end
        
        local key, key_end = s:match('^"([^"]*)"()', pos)
        pos = key_end
        
        pos = s:match('^%s*:%s*()', pos)
        
        local val, val_end = parse_value(s:sub(pos))
        obj[key] = val
        pos = pos + val_end - 1
        
        c = s:match("^%s*(.)", pos)
        if c == ',' then pos = pos + 1
        elseif c == '}' then return obj, pos + 1 end
        
        ::continue::
      end
    end
    
    if first_char == '[' then
      local arr = {}
      local pos = 2
      local index = 1
      while true do
        local c = s:match("^%s*(.)", pos)
        if c == ']' then return arr, pos + 1 end
        
        local val, val_end = parse_value(s:sub(pos))
        arr[index] = val
        index = index + 1
        pos = pos + val_end - 1
        
        c = s:match("^%s*(.)", pos)
        if c == ',' then pos = pos + 1
        elseif c == ']' then return arr, pos + 1 end
      end
    end
    
    return nil, 0
  end
  
  local result, _ = parse_value(str)
  return result
end

function LPM:json_encode(data)
  local success, json = pcall(require, "cjson")
  if success then
    local success, result = pcall(json.encode, data)
    if success then
      return result
    end
  end
  
  local function encode_value(val)
    local t = type(val)
    if t == "nil" then
      return "null"
    elseif t == "boolean" then
      return val and "true" or "false"
    elseif t == "number" then
      return tostring(val)
    elseif t == "string" then
      return '"' .. val:gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "table" then
      local is_array = true
      local i = 0
      for k, _ in pairs(val) do
        i = i + 1
        if type(k) ~= "number" or k ~= i then
          is_array = false
          break
        end
      end
      
      local result = {}
      if is_array then
        for _, v in ipairs(val) do
          table.insert(result, encode_value(v))
        end
        return "[" .. table.concat(result, ",") .. "]"
      else
        for k, v in pairs(val) do
          if type(k) == "string" then
            table.insert(result, '"' .. k .. '":' .. encode_value(v))
          end
        end
        return "{" .. table.concat(result, ",") .. "}"
      end
    end
  end
  
  return encode_value(data)
end

function LPM:http_request(url, method, headers, body)
  method = method or "GET"
  headers = headers or {}
  
  local header_str = ""
  for k, v in pairs(headers) do
    header_str = header_str .. " -H '" .. k .. ": " .. v .. "'"
  end
  
  local cmd = "curl -s -X " .. method .. header_str
  
  if body then
    cmd = cmd .. " -d '" .. body .. "'"
  end
  
  cmd = cmd .. " '" .. url .. "'"
  
  return self:execute(cmd)
end

function LPM:download(url, file)
  self:log("info", "Downloading %s to %s", url, file)
  local content = self:http_request(url)
  if not content then
    self:log("error", "Failed to download from %s", url)
    return false
  end
  return self:write_file(file, content)
end


function LPM:extract_archive(file, dest)
  -- self:log("info", "Extracting %s to %s", file, dest)
  
  if not self:ensure_directory(dest) then
    self:log("error", "Failed to create extraction directory: %s", dest)
    return false
  end
  
  local cmd = string.format("tar -xf '%s' -C '%s'", file, dest)
  local result = self:execute(cmd)
  
  return result ~= nil
end

function LPM:read_config()
  local path = self.config.config_file
  if not self:file_exists(path) then
    self:log("warn", "Config file %s not found", path)
    return {
      name = "unknown",
      version = "0.0.1",
      dependencies = {}
    }
  end
  
  local content = self:read_file(path)
  if not content then
    return nil
  end
  
  local config = self:json_decode(content)
  if config then
    return config
  end
  
  local chunk, err = load("return " .. content)
  if not chunk then
    self:log("error", "Failed to parse config: %s", err)
    return nil
  end
  
  local success, result = pcall(chunk)
  if not success then
    self:log("error", "Failed to execute config: %s", result)
    return nil
  end
  
  return result
end

function LPM:write_config(config)
  local content = self:json_encode(config)
  return self:write_file(self.config.config_file, content)
end

function LPM:load_registry()
  local cache_file = self.config.cache_dir .. "registry.json"
  
  if self:file_exists(cache_file) then
    local content = self:read_file(cache_file)
    if content then
      local registry = self:json_decode(content)
      if registry then
        self.registry = registry
        self:log("debug", "Loaded registry from cache")
        return true
      end
    end
  end
  
  self:log("info", "Fetching registry from %s", self.config.registry_url)
  local content = self:http_request(self.config.registry_url)
  if not content then
    self:log("error", "Failed to fetch registry")
    return false
  end
  
  local registry = self:json_decode(content)
  if not registry then
    self:log("error", "Failed to parse registry")
    return false
  end
  
  self.registry = registry
  
  self:ensure_directory(self.config.cache_dir)
  self:write_file(cache_file, content)
  
  return true
end

function LPM:install_package(name, version, optional)
  if not self.registry then
    if not self:load_registry() then
      return false
    end
  end
  
  local pkg = self.registry.packages and self.registry.packages[name]
  if not pkg then
    if optional then
      self:log("warn", "Package %s not found in registry (optional)", name)
      return true
    else
      self:log("error", "Package %s not found in registry", name)
      return false
    end
  end
  
  version = version or pkg.latest
  if not version then
    self:log("error", "No version specified for package %s and no latest version available", name)
    return false
  end
  
  local info = pkg.versions and pkg.versions[version]
  if not info then
    self:log("error", "Version %s not found for package %s", version, name)
    return false
  end
  
  self:log("info", "Installing %s version %s", name, version)
  
  local install_path = self.config.install_dir .. name .. "-" .. version
  if self:file_exists(install_path .. "/lpm.manifest") then
    self:log("info", "Package %s version %s already installed", name, version)
    return true
  end
  
  self:ensure_directory(self.config.install_dir)
  self:ensure_directory(self.config.cache_dir)
  
  local filename = name .. "-" .. version .. ".tar.gz"
  local cache_file = self.config.cache_dir .. filename
  
  if not self:file_exists(cache_file) then
    if not self:download(info.url, cache_file) then
      return false
    end
    
  else
    self:log("debug", "Using cached version of %s", filename)
  end
  
  if not self:extract_archive(cache_file, self.config.install_dir) then
    return false
  end
  
  local manifest_path = install_path .. "/lpm.manifest"
  if self:file_exists(manifest_path) then
    local content = self:read_file(manifest_path)
    if content then
      local manifest = self:json_decode(content)
      if manifest and manifest.dependencies then
        for dep_name, dep_info in pairs(manifest.dependencies) do
          local dep_version = type(dep_info) == "string" and dep_info or dep_info.version
          local dep_optional = type(dep_info) == "table" and dep_info.optional or false
          
          if not self:install_package(dep_name, dep_version, dep_optional) then
            if not dep_optional then
              return false
            end
          end
        end
      end
    end
  end
  
  return true
end

function LPM:install_dependencies()
  local config = self:read_config()
  if not config then
    return false
  end
  
  if not config.dependencies then
    self:log("info", "No dependencies to install")
    return true
  end
  
  for name, version_info in pairs(config.dependencies) do
    local version = type(version_info) == "string" and version_info or version_info.version
    local optional = type(version_info) == "table" and version_info.optional or false
    
    if not self:install_package(name, version, optional) then
      if not optional then
        return false
      end
    end
  end
  
  return true
end

function LPM:collect_modules()
  local modules = {}
  local config = self:read_config()
  if not config then
    return nil
  end
  
  local function collect_from_dir(dir, prefix)
    prefix = prefix or ""
   
    local files = self:execute("find " .. dir .. " -type f -name '*.lua'")
    if not files then return false end
    
    for file in files:gmatch("[^\r\n]+") do
      local rel_path = file:sub(#dir + 2)
      local module_name = prefix .. rel_path:gsub("%.lua$", ""):gsub("/", ".")
      modules[module_name] = file
    end
    return true
  end
  
  collect_from_dir(".", "")
  
  if self:file_exists(self.config.install_dir) then
    local deps = self:execute("find " .. self.config.install_dir .. " -maxdepth 1 -type d | grep -v '^" .. self.config.install_dir .. "$'")
    if deps then
      for dep_dir in deps:gmatch("[^\r\n]+") do
        local dep_name = dep_dir:match("/([^/]+)$")
        collect_from_dir(dep_dir .. "/src", dep_name:gsub("%-[^-]+$", "") .. ".")
      end
    end
  end
  
  return modules
end

function LPM:compile_bundle()
  self:log("info", "Compiling bundle")
  
  local modules = self:collect_modules()
  if not modules then
    self:log("error", "Failed to collect modules")
    return false
  end
  
  self:ensure_directory(self.config.bundle_dir)
  
  local bundle_file = self.config.bundle_dir .. "bundle.lua"
  local f, err = io.open(bundle_file, "w")
  if not f then
    self:log("error", "Failed to create bundle file: %s", err)
    return false
  end
  
  f:write("-- LPM bundled modules\n")
  f:write("local __lpm_modules = {}\n\n")
  
  for module_name, file_path in pairs(modules) do
    self:log("debug", "Adding module %s from %s", module_name, file_path)
    local content = self:read_file(file_path)
    if not content then
      f:close()
      return false
    end
    
    f:write(string.format("__lpm_modules[%q] = function()\n", module_name))
    f:write("  local module = {}\n")
    f:write("  local require = function(path) return __lpm_require(path) end\n")
    f:write("  local function __lpm_run_module()\n")
    f:write(content)
    f:write("\n  end\n")
    f:write("  local success, result = pcall(__lpm_run_module)\n")
    f:write("  if not success then error('Error in module " .. module_name .. ": ' .. result) end\n")
    f:write("  return module\n")
    f:write("end\n\n")
  end
  
  f:write("local __lpm_loaded = {}\n\n")
  f:write("function __lpm_require(name)\n")
  f:write("  if __lpm_loaded[name] then return __lpm_loaded[name] end\n")
  f:write("  if not __lpm_modules[name] then\n")
  f:write("    return require(name) -- Fall back to regular require\n")
  f:write("  end\n")
  f:write("  local module = __lpm_modules[name]()\n")
  f:write("  __lpm_loaded[name] = module\n")
  f:write("  return module\n")
  f:write("end\n\n")
  
  local config = self:read_config()
  if config and config.main then
    f:write("-- Execute main module\n")
    f:write("return __lpm_require('" .. config.main .. "')\n")
  else
    f:write("-- No main module specified\n")
    f:write("return __lpm_modules\n")
  end
  
  f:close()
  return true
end

function LPM:build()
  if not self:install_dependencies() then
    return false
  end
  
  if not self:compile_bundle() then
    return false
  end
  
  local bundle_file = self.config.bundle_dir .. "bundle.lua"
  
  self:log("info", "Building executable")
  local cmd = string.format("luac -o %s %s", self.config.output_file, bundle_file)
  local result = self:execute(cmd)
  
  if not result then
    self:log("error", "Build failed")
    return false
  end
  
  self:log("info", "Build succeeded")
  return true
end

function LPM:run_command(cmd, args)
  if cmd == "init" then
    local name = args[1] or "myproject"
    local version = args[2] or "0.0.1"
    
    local config = {
      name = name,
      version = version,
      main = "main",
      dependencies = {}
    }
    
    self:ensure_directory(".")
    if not self:write_config(config) then
      return false
    end
    
    self:log("info", "Initialized new project: %s v%s", name, version)
    return true
  elseif cmd == "install" then
    if #args == 0 then
      return self:install_dependencies()
    else
      local name = args[1]
      local version = args[2]
      return self:install_package(name, version, false)
    end
  elseif cmd == "add" then
    local name = args[1]
    local version = args[2]
    
    if not name then
      self:log("error", "Package name required")
      return false
    end
    
    local config = self:read_config()
    if not config then
      return false
    end
    
    config.dependencies = config.dependencies or {}
    config.dependencies[name] = version or true
    
    if not self:write_config(config) then
      return false
    end
    
    return self:install_package(name, version, false)
  elseif cmd == "remove" then
    local name = args[1]
    
    if not name then
      self:log("error", "Package name required")
      return false
    end
    
    local config = self:read_config()
    if not config then
      return false
    end
    
    if not config.dependencies or not config.dependencies[name] then
      self:log("warn", "Package %s is not in dependencies", name)
      return true
    end
    
    config.dependencies[name] = nil
    
    return self:write_config(config)
  elseif cmd == "build" then
    return self:build()
  elseif cmd == "clean" then
    self:log("info", "Cleaning build artifacts")
    os.execute("rm -rf " .. self.config.bundle_dir)
    os.execute("rm -f " .. self.config.output_file)
    return true
  elseif cmd == "bundle" then 
      self:log("info", "Bundling project")
      self:compile_bundle();
  else
    self:log("error", "Unknown command: %s", cmd)
    self:log("info", "Available commands: init, install, add, remove, build, clean")
    return false
  end
end

local function main(args)
  local cmd = table.remove(args, 1)
  
  if not cmd then
    print("Usage: lpm COMMAND [ARGS]")
    print("Commands:")
    print("  init [name] [version]    Initialize a new project")
    print("  install                  Install all dependencies")
    print("  install NAME [VERSION]   Install a specific package")
    print("  add NAME [VERSION]       Add a dependency and install it")
    print("  remove NAME              Remove a dependency")
    print("  build                    Build the project")
    print("  clean                    Clean build artifacts")
    print("  bundle                   Bundle a project");
    return 1
  end
  
  if not LPM:run_command(cmd, args) then
    return 1
  end
  
  return 0
end

local pargs = {...}
return main(pargs)
