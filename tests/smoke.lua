local project = vim.fn.getcwd()
assert(vim.fn.executable("lazygit") == 1, "lazygit is required for the smoke test")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/config/lazygit", "p")
local repo = tmp .. "/repo with spaces"
vim.fn.mkdir(repo, "p")
local result = vim.system({ "git", "init", "-q", repo }, { text = true }):wait()
assert(result.code == 0, result.stderr)
local filename = [[hello ' $world # % |.txt]]
local file = repo .. "/" .. filename
vim.fn.writefile({ "hello", "from Neovim" }, file)
local config = tmp .. "/config/lazygit/config.yml"
vim.fn.writefile({
  vim.json.encode({
    disableStartupPopups = true,
    git = { autoFetch = false },
    gui = { showRandomTip = false },
    customCommands = {
      {
        key = "<f9>",
        context = "files",
        command = "git config --local --edit",
        subprocess = true,
        description = "Exercise the external Git editor without creating a commit",
      },
      {
        key = "<f10>",
        context = "files",
        command = vim.fn.shellescape(vim.v.progpath) .. " --headless -u NONE -i NONE -n -l "
          .. vim.fn.shellescape(project .. "/lua/lazygit/client.lua") .. " wait -- .git/config",
        subprocess = true,
        description = "Exercise a blocking editor failure",
      },
    },
  }),
}, config)

local user_config = vim.env.LAZYGIT_TEST_CONFIG
local host = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", user_config or "NONE", "-i", "NONE", "-n" }, {
  rpc = true,
  env = { CONFIG_DIR = tmp .. "/config/lazygit", LG_CONFIG_FILE = config, XDG_STATE_HOME = tmp .. "/state" },
})
assert(host > 0, "failed to start host Neovim")

local function lua(code, args)
  return vim.rpcrequest(host, "nvim_exec_lua", code, args or {})
end

local function screen()
  return lua([[
    local status = require("lazygit").status()[1]
    if not status then return "NO SESSION" end
    return table.concat(vim.api.nvim_buf_get_lines(status.buffer, 0, -1, false), "\n")
  ]])
end

local function wait(predicate, message)
  if not vim.wait(10000, predicate, 25) then
    error(message .. "\nMode: " .. vim.inspect(vim.rpcrequest(host, "nvim_get_mode"))
      .. "\n" .. screen())
  end
end

local function input(keys)
  vim.rpcrequest(host, "nvim_input", keys)
end

local ok, err = xpcall(function()
  local origin = vim.rpcrequest(host, "nvim_get_current_win")
  local origin_tab = vim.rpcrequest(host, "nvim_get_current_tabpage")
  lua([[
    local project, repo = ...
    vim.opt.runtimepath:prepend(project)
    vim.cmd("runtime plugin/lazygit.lua")
    vim.o.columns = 140
    vim.o.lines = 45
    require("lazygit").setup()
    assert(require("lazygit").open({ cwd = repo }))
  ]], { project, repo })
  wait(function()
    return screen():find("hello", 1, true) ~= nil
  end, "LazyGit did not render the file")
  wait(function()
    return vim.rpcrequest(host, "nvim_get_mode").mode == "t"
  end, "opening the LazyGit tab did not enter terminal mode")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 2, "LazyGit did not create its own tab")
  assert(lua("return vim.api.nvim_win_get_config(0).relative") == "", "LazyGit opened a popup instead of a tab")
  local job = lua("return require('lazygit').status()[1].job")
  input("2e")
  wait(function()
    return lua("return vim.api.nvim_buf_get_name(0)") == file and vim.rpcrequest(host, "nvim_get_mode").mode == "n"
  end, "LazyGit edit did not open the selected file in the host Neovim")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 1, "opening a file left the LazyGit tab behind")
  assert(vim.rpcrequest(host, "nvim_get_current_tabpage") == origin_tab, "file opened in the wrong tab")
  assert(vim.rpcrequest(host, "nvim_get_current_win") == origin, "file opened in the wrong window")
  assert(vim.rpcrequest(host, "nvim_get_mode").mode == "n", "file did not open in normal mode")
  assert(lua("return require('lazygit').status()[1].job") == job, "file opening restarted LazyGit")
  lua("require('lazygit').toggle()")
  wait(function()
    return vim.rpcrequest(host, "nvim_get_mode").mode == "t" and screen():find("hello", 1, true) ~= nil
  end, "LazyGit did not resume in terminal mode")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 2, "resuming did not recreate one LazyGit tab")
  input("2<f9>")
  wait(function()
    return lua("return require('lazygit').status()[1].editing") and vim.rpcrequest(host, "nvim_get_mode").mode == "n"
  end, "Git's external editor did not open in the host")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 1, "external editing left the LazyGit tab behind")
  assert(lua("return vim.api.nvim_buf_get_name(0)") == repo .. "/.git/config", "wrong external editor buffer")
  assert(vim.rpcrequest(host, "nvim_get_mode").mode == "n", "external editor did not enter normal mode")
  lua("vim.cmd('wq')")
  wait(function()
    return lua("return require('lazygit').status()[1].visible")
      and vim.rpcrequest(host, "nvim_get_mode").mode == "t"
      and screen():find("hello", 1, true) ~= nil
  end, "saving the external edit did not resume LazyGit without an extra Enter")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 2, "finishing the editor did not recreate the LazyGit tab")
  input("2<f10>")
  wait(function()
    return lua("return require('lazygit').status()[1].editing") and vim.rpcrequest(host, "nvim_get_mode").mode == "n"
  end, "the second external editor did not open")
  lua("assert(require('lazygit').edit_abort())")
  wait(function()
    return screen():lower():find("press enter", 1, true) ~= nil and vim.rpcrequest(host, "nvim_get_mode").mode == "t"
  end, "LazyGit did not surface the cancelled editor's failure")
  input("<CR>")
  wait(function()
    return screen():find("hello", 1, true) ~= nil and not screen():lower():find("press enter", 1, true)
  end, "Enter did not acknowledge LazyGit's native error prompt")
  input("<C-g>")
  wait(function()
    return not lua("return require('lazygit').status()[1].visible")
  end, "Ctrl-g did not hide LazyGit")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 1, "Ctrl-g left the LazyGit tab behind")
  assert(vim.rpcrequest(host, "nvim_get_current_tabpage") == origin_tab, "Ctrl-g returned to the wrong tab")
  assert(vim.rpcrequest(host, "nvim_get_mode").mode == "n", "hide did not restore normal mode")
  lua("require('lazygit').toggle()")
  wait(function()
    return vim.rpcrequest(host, "nvim_get_mode").mode == "t"
  end, "toggle did not restore terminal input")

  -- Search consumes Escape inside LazyGit rather than leaving terminal mode.
  input("/")
  input("hello<Esc>")
  assert(vim.rpcrequest(host, "nvim_get_mode").mode == "t", "Escape escaped the terminal instead of the LazyGit search")
  input("q")
  -- LazyGit may consume the first q to clear the search filter.
  if not vim.wait(1000, function()
    return lua("return #require('lazygit').status()") == 0
  end, 25) then
    lua("vim.api.nvim_chan_send(require('lazygit').status()[1].job, 'q')")
  end
  wait(function()
    return lua("return #require('lazygit').status()") == 0
  end, "native LazyGit quit did not clean up the session")
  assert(lua("return #vim.api.nvim_list_tabpages()") == 1, "quitting left the LazyGit tab behind")
  assert(vim.rpcrequest(host, "nvim_get_current_win") == origin, "quitting did not restore the editor window")
  assert(vim.rpcrequest(host, "nvim_get_mode").mode == "n", "quit left Neovim in terminal input mode")
  lua("assert(require('lazygit').open())")
  wait(function()
    return screen():find("hello", 1, true) ~= nil
  end, "LazyGit did not restart after quitting")
  assert(lua("return require('lazygit').status()[1].job") ~= job, "quit reused a dead terminal")
end, debug.traceback)

lua("require('lazygit').close()")
vim.fn.jobstop(host)
vim.fn.jobwait({ host }, 3000)
vim.fn.delete(tmp, "rf")
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
io.stdout:write("PASS real LazyGit: dedicated tab, file navigation, Git editor save/abort, return tab, modes, hide, quit, restart\n")
vim.cmd("qa!")
