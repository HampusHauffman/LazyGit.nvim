local config = require("lazygit.config")
local window = require("lazygit.window")
local editor = require("lazygit.editor")
local M = {}
local sessions = {}
local visible, last, group
local closing = false
local serial = 0

local function notify(message, level)
  vim.notify("lazygit.nvim: " .. message, level or vim.log.levels.ERROR)
end

local function refresh()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
      local autoread = vim.bo[buf].autoread
      vim.bo[buf].autoread = true
      local ok, err = pcall(vim.cmd.checktime, { args = { tostring(buf) }, mods = { silent = true } })
      vim.bo[buf].autoread = autoread
      if not ok then
        notify("could not refresh a buffer: " .. tostring(err), vim.log.levels.WARN)
      end
    end
  end
end

local function root(opts)
  local cwd = opts and opts.cwd
  if not cwd then
    local name = vim.api.nvim_buf_get_name(0)
    cwd = vim.bo.buftype == "" and name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  end
  cwd = vim.fn.fnamemodify(cwd, ":p")
  if vim.fn.isdirectory(cwd) == 0 then
    return nil, "not a directory: " .. cwd
  end
  if vim.fn.executable("git") == 0 then
    return nil, "git is not installed"
  end
  local result = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "not a Git worktree")
  end
  return vim.fs.normalize((result.stdout:gsub("\n$", "")), { expand_env = false })
end

local function find(cwd)
  if last and (last.cwd == cwd or last.root == cwd) then
    return last
  end
  for _, session in pairs(sessions) do
    if session.root == cwd or session.cwd == cwd then
      return session
    end
  end
end

local function editing()
  for _, session in pairs(sessions) do
    if session.edit and vim.tbl_contains(session.edit.buffers, vim.api.nvim_get_current_buf()) then
      return session
    end
  end
end

local function hide(session)
  if not session then
    return
  end
  local win, tab = session.win, session.tab
  local was_current = win == vim.api.nvim_get_current_win()
    or (tab == vim.api.nvim_get_current_tabpage() and vim.api.nvim_get_current_buf() == session.buf)
  session.win, session.tab = nil, nil
  if visible == session then
    visible = nil
  end
  if not closing and win and vim.api.nvim_win_is_valid(win) then
    if was_current then
      vim.cmd("stopinsert")
    end
    window.close(win, tab, session.buf)
    if was_current and session.origin and vim.api.nvim_win_is_valid(session.origin) then
      vim.api.nvim_set_current_win(session.origin)
    end
  end
  if not closing then
    refresh()
  end
end

local function enter(session)
  -- Let the previous tab finish leaving terminal mode before entering again.
  vim.defer_fn(function()
    if not closing and visible == session and session.win == vim.api.nvim_get_current_win()
        and vim.api.nvim_get_current_buf() == session.buf then
      vim.cmd("startinsert")
    end
  end, 0)
end

local function show(session)
  if closing or sessions[session.id] ~= session then
    return
  end
  if session.edit then
    if vim.api.nvim_win_is_valid(session.edit.win) then
      vim.api.nvim_set_current_win(session.edit.win)
    end
    notify("finish with :wq / :LazyGitEditDone, or use :LazyGitEditAbort", vim.log.levels.INFO)
    return true
  end
  if visible and visible ~= session then
    hide(visible)
  end
  if session.win and vim.api.nvim_win_is_valid(session.win)
      and vim.api.nvim_win_get_tabpage(session.win) ~= vim.api.nvim_get_current_tabpage() then
    hide(session)
  end
  if not session.win or not vim.api.nvim_win_is_valid(session.win) then
    session.origin = window.origin(vim.api.nvim_get_current_win())
    session.origin_tab = vim.api.nvim_win_get_tabpage(session.origin)
    local ok, win, tab = pcall(window.open, session.buf, config.options.window)
    if not ok then
      notify("could not open LazyGit: " .. tostring(win))
      return nil, win
    end
    session.win, session.tab = win, tab
  else
    vim.api.nvim_set_current_win(session.win)
  end
  visible, last = session, session
  enter(session)
  return true
end

local function cleanup(session, stop)
  if sessions[session.id] ~= session then
    return
  end
  sessions[session.id] = nil
  if last == session then
    last = nil
  end
  editor.finish(session, 1, "LazyGit session closed", false)
  hide(session)
  if stop and session.job then
    vim.fn.jobstop(session.job)
  end
  if vim.api.nvim_buf_is_valid(session.buf) then
    vim.api.nvim_buf_delete(session.buf, { force = true })
  end
  if session.config_path then
    vim.fn.delete(session.config_path)
  end
end

local function initialize()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("LazyGitNvim", {})
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if visible and not visible.tab and visible.win and vim.api.nvim_win_is_valid(visible.win) then
        vim.api.nvim_win_set_config(visible.win, window.layout(config.options.window))
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if visible and visible.win == tonumber(event.match) then
        local session = visible
        local was_current = session.win == vim.api.nvim_get_current_win()
        session.win, session.tab = nil, nil
        visible = nil
        vim.schedule(function()
          if closing then
            return
          end
          if was_current and not visible and session.origin and vim.api.nvim_win_is_valid(session.origin) then
            vim.cmd("stopinsert")
            vim.api.nvim_set_current_win(session.origin)
          end
          refresh()
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      for _, session in pairs(sessions) do
        if session.buf == event.buf then
          vim.schedule(function()
            cleanup(session, true)
          end)
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      closing = true
      for _, session in pairs(sessions) do
        cleanup(session, true)
      end
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  initialize()
end

function M.open(opts)
  initialize()
  if not opts or not opts.cwd then
    local pending = editing()
    if pending then
      show(pending)
      return pending
    end
  end
  if visible and visible.win and vim.api.nvim_win_get_tabpage(visible.win) == vim.api.nvim_get_current_tabpage() then
    if not opts or not opts.cwd then
      local shown, show_err = show(visible)
      return shown and visible or nil, show_err
    end
  end
  local cwd, err = root(opts)
  if not cwd then
    notify(err)
    return nil, err
  end
  local session = find(cwd)
  if session then
    local shown, show_err = show(session)
    return shown and session or nil, show_err
  end
  if vim.fn.executable(config.options.executable) == 0 then
    err = "executable not found: " .. config.options.executable
    notify(err)
    return nil, err
  end
  local bridge = require("lazygit.bridge")
  local ok, integration = pcall(bridge.build, config.options)
  if not ok then
    notify(tostring(integration))
    return nil, integration
  end
  serial = serial + 1
  session = {
    id = tostring(vim.uv.hrtime()) .. "-" .. serial,
    root = cwd,
    cwd = cwd,
    buf = vim.api.nvim_create_buf(false, true),
    config_path = integration.path,
    results = {},
  }
  session.hide = function()
    hide(session)
  end
  session.resume = function()
    return show(session)
  end
  sessions[session.id] = session
  vim.bo[session.buf].bufhidden = "hide"
  vim.bo[session.buf].swapfile = false
  local shown, show_err = show(session)
  if not shown then
    cleanup(session, false)
    return nil, show_err
  end
  local env = integration.env
  env.LAZYGIT_NVIM_SESSION = session.id
  local started, job = pcall(vim.fn.termopen, integration.command, {
    cwd = cwd,
    env = env,
    on_exit = function(_, code)
      vim.schedule(function()
        if sessions[session.id] ~= session then
          return
        end
        local output = vim.api.nvim_buf_is_valid(session.buf)
            and table.concat(vim.api.nvim_buf_get_lines(session.buf, -15, -1, false), "\n")
          or ""
        cleanup(session, false)
        if code ~= 0 and not closing then
          notify("LazyGit exited with code " .. code .. "\n" .. vim.trim(output))
        end
      end)
    end,
  })
  if not started or job <= 0 then
    cleanup(session, false)
    err = "could not start LazyGit: " .. tostring(job)
    notify(err)
    return nil, err
  end
  session.job = job
  vim.bo[session.buf].filetype = "lazygit"
  if config.options.keys.hide then
    vim.keymap.set({ "n", "t" }, config.options.keys.hide, function()
      hide(session)
    end, { buffer = session.buf, silent = true, desc = "Hide LazyGit (keep it running)" })
  end
  vim.keymap.set("n", "q", function()
    hide(session)
  end, { buffer = session.buf, silent = true, desc = "Hide LazyGit" })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = session.buf,
    callback = function()
      if visible == session and vim.api.nvim_get_current_win() == session.win then
        enter(session)
      end
    end,
  })
  return session
end

function M.toggle(opts)
  if visible and visible.win and vim.api.nvim_win_get_tabpage(visible.win) == vim.api.nvim_get_current_tabpage() then
    hide(visible)
    return
  end
  return M.open(opts)
end

function M.hide()
  hide(visible)
end

function M.close()
  local session = visible or last
  if session then
    cleanup(session, true)
  end
end

function M.edit_done()
  local session = editing()
  if not session then
    notify("the current buffer is not a pending LazyGit edit", vim.log.levels.WARN)
    return false
  end
  return editor.done(session)
end

function M.edit_abort()
  local session = editing()
  if not session then
    notify("the current buffer is not a pending LazyGit edit", vim.log.levels.WARN)
    return false
  end
  return editor.finish(session, 1, "editing cancelled", true)
end

function M._request(request)
  if type(request) ~= "table" or type(request.session) ~= "string" then
    return { error = "invalid editor request" }
  end
  local session = sessions[request.session]
  if not session then
    return { error = "LazyGit session is no longer running" }
  end
  if type(request.files) ~= "table" or not vim.islist(request.files) or #request.files == 0 then
    return { error = "no files in editor request" }
  end
  for _, path in ipairs(request.files) do
    if type(path) ~= "string" or path == "" or not vim.startswith(path, "/") or path:find("\0", 1, true) then
      return { error = "editor paths must be absolute, nonempty filenames" }
    end
  end
  if request.line ~= nil and (type(request.line) ~= "number" or request.line < 1 or request.line % 1 ~= 0) then
    return { error = "invalid editor line number" }
  end
  if request.cwd ~= nil then
    if type(request.cwd) ~= "string" or not vim.startswith(request.cwd, "/") then
      return { error = "editor working directory must be absolute" }
    end
    session.cwd = vim.fs.normalize(request.cwd, { expand_env = false })
  end
  return editor.open(session, request)
end

function M._poll(id, request_id)
  local session = sessions[id]
  if not session then
    return { done = true, code = 1, error = "LazyGit session is no longer running" }
  end
  local result = session.results[request_id]
  if result then
    session.results[request_id] = nil
    return result
  end
  if session.edit and session.edit.id == request_id then
    return { done = false }
  end
  return { done = true, code = 1, error = "unknown editor request" }
end

function M.status()
  local result = {}
  for _, session in pairs(sessions) do
    result[#result + 1] = {
      root = session.root,
      buffer = session.buf,
      window = session.win,
      tabpage = session.tab,
      job = session.job,
      editing = session.edit ~= nil,
      visible = visible == session,
    }
  end
  return result
end

return M
