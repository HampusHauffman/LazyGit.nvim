local project = vim.fn.getcwd()
vim.opt.runtimepath:prepend(project)
vim.cmd("runtime plugin/lazygit.lua")

local git = require("lazygit")
local config = require("lazygit.config")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local failures, passed = {}, 0
local notifications = {}
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " != " .. vim.inspect(expected))
end

local function eventually(predicate, message)
  assert(vim.wait(5000, predicate, 10), message or "timed out")
end

local function run(argv, opts)
  local result = vim.system(argv, vim.tbl_extend("force", { text = true }, opts or {})):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function repo(name)
  local path = tmp .. "/" .. name
  vim.fn.mkdir(path, "p")
  run({ "git", "init", "-q", path })
  return path
end

local first_repo = repo("repo one")
local second_repo = repo("repo two")
local filename = [[quote's "file" $dollar ; | # % [x].lua]]
local file = first_repo .. "/" .. filename
vim.fn.writefile({ "one", "two", "three", "four", "five" }, file)
local other_file = first_repo .. "/other.lua"
vim.fn.writefile({ "unchanged" }, other_file)

local defaults = {
  executable = vim.v.progpath,
  args = { "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", project .. "/tests/fixtures/terminal.lua" },
  config_files = {},
}

local function reset()
  vim.o.hidden = true
  for _ = 1, 10 do
    if #git.status() == 0 then
      break
    end
    local status = git.status()[1]
    git.open({ cwd = status.root })
    git.close()
  end
  vim.cmd("stopinsert")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  git.setup(defaults)
end

local function test(name, callback)
  reset()
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    io.stdout:write("PASS " .. name .. "\n")
  else
    failures[#failures + 1] = name .. "\n" .. tostring(err)
    io.stdout:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n")
  end
end

local function start(path)
  local session, err = git.open({ cwd = path or first_repo })
  assert(session, err)
  eventually(function()
    return vim.api.nvim_buf_is_valid(session.buf)
      and table.concat(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), "\n"):find("FAKE_LAZYGIT_READY", 1, true)
  end, "terminal did not start")
  return session
end

local function client(session, mode, files, line)
  local args = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", project .. "/lua/lazygit/client.lua", mode }
  if line then
    vim.list_extend(args, { "--line", tostring(line) })
  end
  args[#args + 1] = "--"
  vim.list_extend(args, files)
  local result
  local process = vim.system(args, {
    cwd = session.root,
    env = { LAZYGIT_NVIM_SERVER = vim.v.servername, LAZYGIT_NVIM_SESSION = session.id },
    text = true,
  }, function(value)
    result = value
  end)
  return {
    process = process,
    result = function()
      return result
    end,
    wait = function()
      eventually(function()
        return result ~= nil
      end, "editor client did not finish")
      return result
    end,
  }
end

test("configuration validates dimensions and preserves defaults", function()
  git.setup({ window = { width = 70 }, keys = { hide = false } })
  equal(config.options.window.width, 70)
  equal(config.options.window.height, 0.9)
  equal(config.options.window.type, "tab")
  equal(config.options.keys.hide, false)
  assert(not pcall(git.setup, { window = { height = 0 } }))
  assert(not pcall(git.setup, { args = { "--use-config-file=bad" } }))
  assert(not pcall(git.setup, { window = { type = "invalid" } }))
end)

test("commands are registered without setup", function()
  for _, name in ipairs({ "LazyGit", "LazyGitOpen", "LazyGitHide", "LazyGitClose", "LazyGitEditDone", "LazyGitEditAbort" }) do
    equal(vim.fn.exists(":" .. name), 2)
  end
end)

test("hide and resume keep the same terminal job and original window", function()
  local origin = vim.api.nvim_get_current_win()
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local session = start()
  local job, buf = session.job, session.buf
  local tab = session.tab
  equal(#vim.api.nvim_list_tabpages(), 2)
  equal(vim.api.nvim_get_current_tabpage(), tab)
  equal(vim.api.nvim_win_get_config(session.win).relative, "")
  equal(git.open(), session)
  equal(#vim.api.nvim_list_tabpages(), 2)
  git.hide()
  equal(vim.api.nvim_get_current_win(), origin)
  equal(vim.api.nvim_get_current_tabpage(), origin_tab)
  equal(#vim.api.nvim_list_tabpages(), 1)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(vim.fn.jobwait({ job }, 0)[1], -1)
  equal(git.open({ cwd = first_repo }), session)
  equal(session.job, job)
  equal(session.buf, buf)
  assert(session.tab ~= tab)
  equal(#vim.api.nvim_list_tabpages(), 2)
  git.toggle()
  equal(git.status()[1].visible, false)
  equal(#vim.api.nvim_list_tabpages(), 1)
end)

test("independent worktrees retain independent jobs", function()
  local first = start()
  local second = start(second_repo)
  equal(#git.status(), 2)
  equal(first.win, nil)
  assert(first.job ~= second.job)
  equal(git.open({ cwd = first_repo }), first)
  equal(second.win, nil)
end)

test("resuming from another tab moves the popup without switching tabs", function()
  git.setup(vim.tbl_deep_extend("force", defaults, { window = { type = "float" } }))
  local session = start()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local origin = vim.api.nvim_get_current_win()
  equal(git.toggle({ cwd = first_repo }), session)
  equal(vim.api.nvim_get_current_tabpage(), tab)
  equal(vim.api.nvim_win_get_tabpage(session.win), tab)
  git.hide()
  equal(vim.api.nvim_get_current_win(), origin)
  equal(vim.api.nvim_get_current_tabpage(), tab)
end)

test("resizing clamps the popup to the available screen", function()
  git.setup(vim.tbl_deep_extend("force", defaults, { window = { type = "float" } }))
  local session = start()
  local columns, lines = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 40, 12
  vim.api.nvim_exec_autocmds("VimResized", {})
  local layout = vim.api.nvim_win_get_config(session.win)
  assert(layout.width <= 38 and layout.height <= 8)
  vim.o.columns, vim.o.lines = columns, lines
  vim.api.nvim_exec_autocmds("VimResized", {})
end)

test("resuming from another editing tab replaces the old LazyGit tab", function()
  local session = start()
  local old_tab = session.tab
  vim.cmd("tabnew")
  local origin = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  equal(git.open({ cwd = first_repo }), session)
  assert(not vim.api.nvim_tabpage_is_valid(old_tab))
  equal(#vim.api.nvim_list_tabpages(), 3)
  git.hide()
  equal(vim.api.nvim_get_current_win(), origin)
  equal(vim.api.nvim_get_current_tabpage(), tab)
  equal(#vim.api.nvim_list_tabpages(), 2)
end)

test("resizing a LazyGit tab never turns its window into a float", function()
  local session = start()
  vim.api.nvim_exec_autocmds("VimResized", {})
  equal(vim.api.nvim_win_get_config(session.win).relative, "")
  equal(vim.api.nvim_get_current_tabpage(), session.tab)
end)

test("nonblocking RPC opens a safely transported filename at a line", function()
  local origin = vim.api.nvim_get_current_win()
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local session = start()
  local tab = session.tab
  local child = client(session, "open", { filename }, 4)
  local result = child.wait()
  equal(result.code, 0)
  equal(vim.api.nvim_buf_get_name(0), file)
  equal(vim.api.nvim_win_get_cursor(0)[1], 4)
  equal(session.win, nil)
  equal(session.tab, nil)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(#vim.api.nvim_list_tabpages(), 1)
  equal(vim.api.nvim_get_current_tabpage(), origin_tab)
  equal(vim.api.nvim_get_current_win(), origin)
  equal(vim.fn.jobwait({ session.job }, 0)[1], -1)
  equal(git.open(), session)
end)

test("file navigation preserves unsaved buffers with nohidden", function()
  vim.o.hidden = false
  local origin_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "unsaved work" })
  local session = start()
  equal(client(session, "open", { file }, 900).wait().code, 0)
  equal(vim.api.nvim_win_get_cursor(0)[1], 5)
  equal(vim.api.nvim_buf_get_lines(origin_buf, 0, -1, false), { "unsaved work" })
  assert(vim.bo[origin_buf].modified)
  equal(#vim.api.nvim_list_wins(), 2)
end)

test("file navigation reuses an existing window", function()
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_win_set_buf(0, buf)
  local file_win = vim.api.nvim_get_current_win()
  vim.cmd("vnew")
  local session = start()
  equal(client(session, "open", { file }).wait().code, 0)
  equal(vim.api.nvim_get_current_win(), file_win)
  equal(#vim.api.nvim_list_wins(), 2)
end)

test("directory requests open the configured Neovim directory browser", function()
  vim.cmd("runtime plugin/netrwPlugin.vim")
  vim.api.nvim_exec_autocmds("VimEnter", { group = "FileExplorer" })
  local directory = first_repo .. "/directory with spaces"
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ "content" }, directory .. "/inside.txt")
  local session = start()
  equal(client(session, "open", { directory }).wait().code, 0)
  equal(vim.fn.isdirectory(vim.api.nvim_buf_get_name(0)), 1)
  equal(vim.bo.filetype, "netrw")
  equal(session.win, nil)
end)

test("blocking editor waits, saves, and resumes LazyGit", function()
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local session = start()
  local tab = session.tab
  local message = first_repo .. "/.git/COMMIT_EDITMSG"
  vim.fn.writefile({ "initial message" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  assert(child.result() == nil)
  equal(session.win, nil)
  equal(vim.api.nvim_get_current_tabpage(), origin_tab)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(#vim.api.nvim_list_tabpages(), 1)
  equal(#vim.api.nvim_list_wins(), 2)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "new message" })
  assert(git.edit_done())
  equal(child.wait().code, 0)
  equal(vim.fn.readfile(message), { "new message" })
  assert(session.win and vim.api.nvim_win_is_valid(session.win))
  equal(#vim.api.nvim_list_tabpages(), 2)
  assert(session.tab ~= tab)
end)

test("wq ends only the dedicated editor split", function()
  local session = start()
  local message = first_repo .. "/.git/MERGE_MSG"
  vim.fn.writefile({ "merge" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited merge" })
  vim.cmd("wq")
  equal(child.wait().code, 0)
  equal(vim.fn.readfile(message), { "edited merge" })
  assert(session.win and vim.api.nvim_win_is_valid(session.win))
end)

test("a multi-file blocking request saves all requested files", function()
  local session = start()
  local one, two = first_repo .. "/.git/message-one", first_repo .. "/.git/message-two"
  vim.fn.writefile({ "one" }, one)
  vim.fn.writefile({ "two" }, two)
  local child = client(session, "wait", { one, two })
  eventually(function()
    return session.edit ~= nil
  end)
  local buffers = session.edit.buffers
  vim.api.nvim_buf_set_lines(buffers[1], 0, -1, false, { "updated one" })
  vim.api.nvim_win_set_buf(0, buffers[2])
  vim.api.nvim_buf_set_lines(buffers[2], 0, -1, false, { "updated two" })
  assert(git.edit_done())
  equal(child.wait().code, 0)
  equal(vim.fn.readfile(one), { "updated one" })
  equal(vim.fn.readfile(two), { "updated two" })
end)

test("toggling during an external edit focuses its split and keeps waiting", function()
  local session = start()
  local message = first_repo .. "/.git/toggle-edit"
  vim.fn.writefile({ "pending" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  local edit_win = session.edit.win
  git.toggle()
  equal(vim.api.nvim_get_current_win(), edit_win)
  equal(session.win, nil)
  equal(child.result(), nil)
  git.edit_abort()
  assert(child.wait().code ~= 0)
end)

test("abort returns a failure and preserves unsaved editor text", function()
  local session = start()
  local message = first_repo .. "/.git/git-rebase-todo"
  vim.fn.writefile({ "pick abc original" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "do not run this" })
  assert(git.edit_abort())
  assert(child.wait().code ~= 0)
  equal(vim.fn.readfile(message), { "pick abc original" })
  equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "do not run this" })
end)

test("closing an unsaved editor split aborts rather than continuing Git", function()
  local session = start()
  local message = first_repo .. "/.git/SQUASH_MSG"
  vim.fn.writefile({ "squash" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved squash" })
  vim.cmd("q!")
  assert(child.wait().code ~= 0)
  equal(vim.fn.readfile(message), { "squash" })
end)

test("failed writes leave the editor request pending", function()
  local session = start()
  local message = first_repo .. "/.git/readonly-message"
  vim.fn.writefile({ "message" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  vim.bo.readonly = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
  equal(git.edit_done(), false)
  assert(session.edit)
  equal(child.result(), nil)
  vim.bo.readonly = false
  git.edit_abort()
  assert(child.wait().code ~= 0)
end)

test("hiding refreshes clean files but never overwrites dirty ones", function()
  local clean = vim.fn.bufadd(other_file)
  vim.fn.bufload(clean)
  local dirty = vim.fn.bufadd(file)
  vim.fn.bufload(dirty)
  vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { "keep unsaved" })
  start()
  vim.fn.writefile({ "changed on disk", "extra line" }, other_file)
  vim.fn.writefile({ "external" }, file)
  git.hide()
  equal(vim.api.nvim_buf_get_lines(clean, 0, -1, false), { "changed on disk", "extra line" })
  equal(vim.api.nvim_buf_get_lines(dirty, 0, -1, false), { "keep unsaved" })
end)

test("invalid requests fail without closing the LazyGit tab", function()
  local session = start()
  for _, request in ipairs({
    {},
    { session = session.id, files = {} },
    { session = session.id, files = { "relative" } },
    { session = session.id, files = { file }, line = -1 },
  }) do
    assert(git._request(request).error)
  end
  assert(session.win and vim.api.nvim_win_is_valid(session.win))
end)

test("generated config preserves user settings and suppresses the return prompt", function()
  local path = tmp .. "/custom config.yml"
  local contents = { "gui:", "  border: single", "os:", "  edit: 'old-editor {{filename}}'" }
  vim.fn.writefile(contents, path)
  git.setup(vim.tbl_extend("force", defaults, { config_files = { path } }))
  local session = start()
  local overlay = vim.json.decode(table.concat(vim.fn.readfile(session.config_path), "\n"))
  equal(overlay.promptToReturnFromSubprocess, false)
  equal(overlay.os.editInTerminal, false)
  assert(overlay.os.openDirInEditor:find("{{dir}}", 1, true))
  assert(overlay.os.edit:find("client.lua", 1, true))
  equal(vim.fn.readfile(path), contents)
end)

test("default config discovery honors LG_CONFIG_FILE without changing it", function()
  local path = tmp .. "/environment-config.yml"
  vim.fn.writefile({ "gui:", "  border: single" }, path)
  local previous = vim.env.LG_CONFIG_FILE
  vim.env.LG_CONFIG_FILE = path
  local options = vim.deepcopy(defaults)
  options.config_files = nil
  local integration = require("lazygit.bridge").build(options)
  equal(integration.command[#integration.command], path .. "," .. integration.path)
  equal(vim.env.LG_CONFIG_FILE, path)
  vim.fn.delete(integration.path)
  vim.env.LG_CONFIG_FILE = previous
end)

test("repository changes inside LazyGit are associated with its existing session", function()
  local session = start()
  local path = second_repo .. "/nested-file"
  vim.fn.writefile({ "second repo" }, path)
  local response = git._request({ session = session.id, files = { path }, cwd = second_repo })
  assert(not response.error, response.error)
  equal(git.open(), session)
  equal(#git.status(), 1)
end)

test("closing a session unblocks pending editor clients with failure", function()
  local session = start()
  local message = first_repo .. "/.git/pending-edit"
  vim.fn.writefile({ "pending" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  git.close()
  assert(child.wait().code ~= 0)
  equal(#git.status(), 0)
end)

test("replacing an editor buffer aborts without closing the replacement", function()
  local session = start()
  local message = first_repo .. "/.git/replaced-edit"
  vim.fn.writefile({ "pending" }, message)
  local child = client(session, "wait", { message })
  eventually(function()
    return session.edit ~= nil
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "other unsaved work" })
  assert(child.wait().code ~= 0)
  assert(vim.api.nvim_win_is_valid(win))
  equal(vim.api.nvim_win_get_buf(win), buf)
  equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "other unsaved work" })
end)

test("popup creation failure releases allocated state and config", function()
  git.setup(vim.tbl_deep_extend("force", defaults, { window = { type = "float", border = "invalid" } }))
  local session, err = git.open({ cwd = first_repo })
  equal(session, nil)
  assert(err)
  equal(#git.status(), 0)
end)

test("manually closing the float retains its session", function()
  git.setup(vim.tbl_deep_extend("force", defaults, { window = { type = "float" } }))
  local session = start()
  vim.api.nvim_win_close(session.win, true)
  equal(session.win, nil)
  equal(git.open({ cwd = first_repo }), session)
  equal(vim.fn.jobwait({ session.job }, 0)[1], -1)
end)

test("closing the LazyGit tab manually restores the originating tab", function()
  vim.cmd("tabnew")
  local origin = vim.api.nvim_get_current_win()
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local session = start()
  local tab = session.tab
  vim.cmd("stopinsert")
  vim.cmd("tabclose")
  eventually(function()
    return session.win == nil and vim.api.nvim_get_current_win() == origin
  end)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(vim.api.nvim_get_current_tabpage(), origin_tab)
  equal(#vim.api.nvim_list_tabpages(), 2)
  equal(vim.fn.jobwait({ session.job }, 0)[1], -1)
  equal(git.open({ cwd = first_repo }), session)
end)

test("hiding a background LazyGit tab does not steal editor focus", function()
  local session = start()
  local tab = session.tab
  vim.cmd("tabnew")
  local origin = vim.api.nvim_get_current_win()
  git.hide()
  equal(vim.api.nvim_get_current_win(), origin)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
end)

test("file opening still works after the original tab was closed", function()
  local origin = vim.api.nvim_get_current_win()
  local session = start()
  local tab = session.tab
  vim.api.nvim_win_close(origin, true)
  equal(#vim.api.nvim_list_tabpages(), 1)
  equal(client(session, "open", { other_file }).wait().code, 0)
  equal(#vim.api.nvim_list_tabpages(), 1)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(vim.api.nvim_buf_get_name(0), other_file)
  equal(vim.fn.jobwait({ session.job }, 0)[1], -1)
end)

test("file opening falls back to another window in the original tab", function()
  local remaining = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("vnew")
  local origin = vim.api.nvim_get_current_win()
  local session = start()
  vim.api.nvim_win_close(origin, true)
  equal(client(session, "open", { other_file }).wait().code, 0)
  equal(vim.api.nvim_get_current_tabpage(), tab)
  equal(vim.api.nvim_get_current_win(), remaining)
end)

test("hiding closes duplicate terminal splits but preserves user-created editors", function()
  local session = start()
  local tab = session.tab
  vim.cmd("split")
  git.hide()
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(#vim.api.nvim_list_tabpages(), 1)
  git.open({ cwd = first_repo })
  vim.cmd("vnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep this work" })
  git.hide()
  assert(vim.api.nvim_win_is_valid(win))
  equal(vim.api.nvim_get_current_win(), win)
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "keep this work" })
end)

test("native quit cleans up and a later open creates a fresh job", function()
  local origin = vim.api.nvim_get_current_win()
  local session = start()
  local tab = session.tab
  local path = session.config_path
  vim.api.nvim_chan_send(session.job, "q\n")
  eventually(function()
    return not vim.api.nvim_buf_is_valid(session.buf)
  end)
  equal(#git.status(), 0)
  equal(#vim.api.nvim_list_tabpages(), 1)
  equal(vim.api.nvim_get_current_win(), origin)
  assert(not vim.api.nvim_tabpage_is_valid(tab))
  equal(vim.fn.filereadable(path), 0)
  assert(start().job ~= session.job)
end)

test("deleting the terminal stops its job and removes temporary config", function()
  local session = start()
  git.hide()
  vim.api.nvim_buf_delete(session.buf, { force = true })
  eventually(function()
    return #git.status() == 0
  end)
  equal(vim.fn.filereadable(session.config_path), 0)
  assert(vim.fn.jobwait({ session.job }, 1000)[1] ~= -1)
end)

test("non-repository paths and missing executables do not allocate sessions", function()
  local session, err = git.open({ cwd = tmp })
  equal(session, nil)
  assert(err:find("not a git repository", 1, true))
  git.setup({ executable = tmp .. "/missing" })
  session, err = git.open({ cwd = first_repo })
  equal(session, nil)
  assert(err:find("executable not found", 1, true))
  equal(#git.status(), 0)
end)

reset()
vim.fn.delete(tmp, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
