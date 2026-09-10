-- Run by a separate, clean Neovim process, not loaded by the host editor.
local function fail(message)
  io.stderr:write("lazygit.nvim: " .. tostring(message) .. "\n")
  vim.cmd("cquit 1")
end

local args = _G.arg
local wait = args[1] == "wait"
if args[1] ~= "open" and not wait then
  fail("expected open or wait")
end

local line, first = nil, 2
if args[first] == "--line" then
  line = tonumber(args[first + 1])
  if not line or line < 1 or line % 1 ~= 0 then
    fail("invalid line number")
  end
  first = first + 2
end
if args[first] == "--" then
  first = first + 1
end

local files = {}
for i = first, #args do
  files[#files + 1] = vim.fn.fnamemodify(args[i], ":p")
end
if #files == 0 then
  fail("no file provided")
end

local server = vim.env.LAZYGIT_NVIM_SERVER
local session = vim.env.LAZYGIT_NVIM_SESSION
if not server or not session then
  fail("missing parent editor environment")
end
local connected, channel = pcall(vim.fn.sockconnect, "pipe", server, { rpc = true })
if not connected or channel == 0 then
  fail("could not connect to the parent Neovim: " .. tostring(channel))
end

local called, response = pcall(
  vim.rpcrequest,
  channel,
  "nvim_exec_lua",
  "return require('lazygit')._request(...)",
  { { session = session, files = files, line = line, wait = wait, cwd = vim.uv.cwd() } }
)
if not called or type(response) ~= "table" or response.error then
  fail(type(response) == "table" and response.error or response)
end

if wait then
  local finished, code, message = false, 1, nil
  while not finished do
    local ok, result = pcall(
      vim.rpcrequest,
      channel,
      "nvim_exec_lua",
      "return require('lazygit')._poll(...)",
      { session, response.id }
    )
    if not ok or type(result) ~= "table" then
      fail("lost connection to the parent Neovim: " .. tostring(result))
    end
    if result.done then
      finished, code, message = true, result.code, result.error
    else
      vim.wait(100, function()
        return false
      end)
    end
  end
  if code ~= 0 then
    fail(message or "editing cancelled")
  end
end

vim.fn.chanclose(channel)
vim.cmd("qa!")
