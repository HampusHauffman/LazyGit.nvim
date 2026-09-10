local window = require("lazygit.window")
local M = {}
local next_id = 0

local function buffer(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  return buf
end

local function position(win, line)
  if line then
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_set_cursor(win, { math.min(line, count), 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zvzz")
    end)
  end
end

local function restore_hidden(edit)
  for buf, value in pairs(edit.hidden) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].bufhidden = value
    end
  end
end

function M.finish(session, code, message, resume)
  local edit = session.edit
  if not edit then
    return false
  end
  session.edit = nil
  vim.api.nvim_del_augroup_by_id(edit.group)
  session.results[edit.id] = { done = true, code = code, error = message }
  if vim.api.nvim_win_is_valid(edit.win) and vim.tbl_contains(edit.buffers, vim.api.nvim_win_get_buf(edit.win)) then
    vim.api.nvim_win_close(edit.win, true)
  end
  restore_hidden(edit)
  if resume then
    session.resume()
  end
  return true
end

function M.open(session, request)
  if session.edit then
    return { error = "an editor request is already pending; finish or abort it first" }
  end
  local buffers = {}
  for _, path in ipairs(request.files) do
    local ok, buf = pcall(buffer, path)
    if not ok then
      return { error = "could not open " .. path .. ": " .. tostring(buf) }
    end
    buffers[#buffers + 1] = buf
  end

  session.hide()
  local origin = window.origin(session.origin, session.origin_tab)
  vim.api.nvim_set_current_win(origin)

  if not request.wait then
    local target
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if window.is_editor(win) and vim.api.nvim_win_get_buf(win) == buffers[1] then
        target = win
        break
      end
    end
    if target then
      vim.api.nvim_set_current_win(target)
    elseif vim.bo.modified and not vim.o.hidden then
      vim.cmd("botright split")
    end
    vim.api.nvim_win_set_buf(0, buffers[1])
    position(vim.api.nvim_get_current_win(), request.line)
    session.origin = vim.api.nvim_get_current_win()
    return {}
  end

  -- A dedicated split makes :wq finish the external edit, not quit Neovim.
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buffers[1])
  position(win, request.line)
  next_id = next_id + 1
  local edit = {
    id = tostring(next_id),
    win = win,
    buffers = buffers,
    hidden = {},
    unsaved = {},
    group = vim.api.nvim_create_augroup("LazyGitEdit" .. next_id, {}),
  }
  for _, buf in ipairs(buffers) do
    edit.hidden[buf] = vim.bo[buf].bufhidden
    -- Closing an editor window must not wipe its buffer's unsaved changes.
    vim.bo[buf].bufhidden = "hide"
  end
  session.edit = edit
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = edit.group,
    callback = function(event)
      if vim.tbl_contains(buffers, event.buf) then
        edit.unsaved[event.buf] = vim.bo[event.buf].modified
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = edit.group,
    callback = function(event)
      edit.unsaved[event.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = edit.group,
    pattern = tostring(win),
    callback = function()
      vim.schedule(function()
        if session.edit ~= edit then
          return
        end
        local code = 0
        for _, buf in ipairs(edit.buffers) do
          if edit.unsaved[buf] or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
            code = 1
          end
        end
        M.finish(session, code, code ~= 0 and "editor closed with unsaved changes" or nil, true)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = edit.group,
    callback = function()
      if vim.api.nvim_get_current_win() == win and not vim.tbl_contains(buffers, vim.api.nvim_get_current_buf()) then
        vim.schedule(function()
          if session.edit == edit then
            M.finish(session, 1, "editor buffer was replaced before finishing", true)
          end
        end)
      end
    end,
  })
  vim.notify("LazyGit editor: :wq or :LazyGitEditDone to finish; :LazyGitEditAbort to cancel")
  return { id = edit.id }
end

function M.done(session)
  local edit = session.edit
  if not edit then
    return false
  end
  for _, buf in ipairs(edit.buffers) do
    if not vim.api.nvim_buf_is_valid(buf) then
      vim.notify("LazyGit editor buffer was deleted; abort the edit", vim.log.levels.ERROR)
      return false
    end
    local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("write")
    end)
    if not ok then
      vim.notify("LazyGit could not save the edit: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  return M.finish(session, 0, nil, true)
end

return M
