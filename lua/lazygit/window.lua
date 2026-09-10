local M = {}

local function size(value, available)
  return math.max(1, math.min(available, value <= 1 and math.floor(available * value) or value))
end

function M.layout(options)
  local columns = math.max(1, vim.o.columns - 2)
  local lines = math.max(1, vim.o.lines - vim.o.cmdheight - 3)
  local width, height = size(options.width, columns), size(options.height, lines)
  return {
    relative = "editor",
    style = "minimal",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    border = options.border,
    title = options.border ~= "none" and options.title or nil,
    title_pos = options.border ~= "none" and options.title_pos or nil,
    zindex = options.zindex,
  }
end

function M.open(buffer, options)
  if options.type == "tab" then
    vim.cmd("tab sbuffer " .. buffer)
    local win = vim.api.nvim_get_current_win()
    vim.w[win].lazygit_terminal = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    return win, vim.api.nvim_get_current_tabpage()
  end
  local win = vim.api.nvim_open_win(buffer, true, M.layout(options))
  vim.w[win].lazygit_terminal = true
  vim.wo[win].winblend = options.winblend
  return win
end

function M.close(win, tab, buffer)
  local windows = tab and vim.api.nvim_tabpage_is_valid(tab) and vim.api.nvim_tabpage_list_wins(tab) or { win }
  for _, target in ipairs(windows) do
    if vim.api.nvim_win_is_valid(target) and vim.api.nvim_win_get_buf(target) == buffer then
      if vim.api.nvim_win_get_config(target).relative == "" and #vim.api.nvim_list_tabpages() == 1 then
        local normal = 0
        for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_get_config(other).relative == "" then
            normal = normal + 1
          end
        end
        -- The originating tab may have been closed while LazyGit was open.
        if normal == 1 then
          vim.cmd("tabnew")
        end
      end
      vim.api.nvim_win_close(target, true)
    end
  end
end

function M.is_editor(win)
  return vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
    and not (vim.w[win].lazygit_terminal and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal")
end

function M.origin(preferred, tab)
  if preferred and M.is_editor(preferred) then
    return preferred
  end
  local target = tab and vim.api.nvim_tabpage_is_valid(tab) and tab or vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(target)) do
    if M.is_editor(win) then
      return win
    end
  end
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_win()
end

return M
