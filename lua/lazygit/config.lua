local M = {}

M.defaults = {
  executable = "lazygit",
  args = {},
  config_files = nil,
  window = {
    type = "tab",
    width = 0.9,
    height = 0.9,
    border = "rounded",
    title = " LazyGit ",
    title_pos = "center",
    winblend = 0,
    zindex = 50,
  },
  keys = {
    hide = "<C-g>",
  },
}

M.options = vim.deepcopy(M.defaults)

local function strings(value, name)
  assert(type(value) == "table" and vim.islist(value), name .. " must be a list")
  for _, item in ipairs(value) do
    assert(type(item) == "string" and item ~= "", name .. " must contain nonempty strings")
  end
end

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "lazygit.setup expects a table")
  local options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(type(options.executable) == "string" and options.executable ~= "", "executable must be a string")
  strings(options.args, "args")
  for _, arg in ipairs(options.args) do
    assert(
      not arg:match("^%-%-?use%-config") and not arg:match("^%-uc[fd]"),
      "use config_files instead of passing config flags in args"
    )
  end
  if options.config_files ~= nil then
    strings(options.config_files, "config_files")
  end
  assert(options.window.type == "tab" or options.window.type == "float", "window.type must be 'tab' or 'float'")
  for _, dimension in ipairs({ "width", "height" }) do
    local value = options.window[dimension]
    assert(type(value) == "number" and value > 0, "window." .. dimension .. " must be positive")
    assert(value <= 1 or value % 1 == 0, "window." .. dimension .. " must be a fraction or integer")
  end
  assert(
    type(options.window.winblend) == "number"
      and options.window.winblend % 1 == 0
      and options.window.winblend >= 0
      and options.window.winblend <= 100,
    "window.winblend must be an integer from 0 to 100"
  )
  assert(
    type(options.window.zindex) == "number" and options.window.zindex > 0 and options.window.zindex % 1 == 0,
    "window.zindex must be a positive integer"
  )
  assert(
    options.keys.hide == false or (type(options.keys.hide) == "string" and options.keys.hide ~= ""),
    "keys.hide must be a nonempty string or false"
  )
  M.options = options
end

return M
