local M = {}
local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local client = vim.fs.dirname(source) .. "/client.lua"

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.build(options)
  assert(vim.fn.has("win32") == 0, "the editor bridge currently supports Linux and macOS")
  local server = vim.v.servername
  if server == "" then
    server = vim.fn.serverstart()
  end
  local command = quote(vim.v.progpath) .. " --headless -u NONE -i NONE -n -l " .. quote(client)
  local wait = command .. " wait --"
  local files = vim.deepcopy(options.config_files)
  if files == nil and vim.env.LG_CONFIG_FILE and vim.env.LG_CONFIG_FILE ~= "" then
    files = vim.split(vim.env.LG_CONFIG_FILE, ",", { plain = true })
  end
  if files == nil then
    local result = vim.system({ options.executable, "--print-config-dir" }, { text = true }):wait()
    assert(result.code == 0, "could not locate LazyGit config: " .. (result.stderr or ""))
    local directory = result.stdout:gsub("\n$", "")
    assert(directory ~= "", "LazyGit returned an empty config directory")
    local global = directory .. "/config.yml"
    files = vim.fn.filereadable(global) == 1 and { global } or {}
  end
  for i, path in ipairs(files) do
    files[i] = vim.fn.fnamemodify(path, ":p")
    assert(not files[i]:find(",", 1, true), "LazyGit config paths cannot contain commas")
    assert(vim.fn.filereadable(files[i]) == 1, "config file does not exist: " .. files[i])
  end
  local path = vim.fn.tempname() .. "-lazygit.yml"
  local overrides = {
    promptToReturnFromSubprocess = false,
    os = {
      editPreset = "",
      edit = command .. " open -- {{filename}}",
      editAtLine = command .. " open --line {{line}} -- {{filename}}",
      editAtLineAndWait = command .. " wait --line {{line}} -- {{filename}}",
      editInTerminal = false,
      openDirInEditor = command .. " open -- {{dir}}",
      open = command .. " open -- {{filename}}",
    },
  }
  vim.fn.writefile({ vim.json.encode(overrides) }, path)
  files[#files + 1] = path
  local argv = { options.executable }
  vim.list_extend(argv, options.args)
  vim.list_extend(argv, { "--use-config-file", table.concat(files, ",") })
  return {
    path = path,
    command = argv,
    env = {
      LAZYGIT_NVIM_SERVER = server,
      EDITOR = wait,
      VISUAL = wait,
      GIT_EDITOR = wait,
      GIT_SEQUENCE_EDITOR = wait,
    },
  }
end

return M
