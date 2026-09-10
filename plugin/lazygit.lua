if vim.g.loaded_lazygit_nvim then
  return
end
vim.g.loaded_lazygit_nvim = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("lazygit.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

local function directory(opts)
  return opts.args ~= "" and { cwd = vim.fn.expand(opts.args) } or nil
end

for name, method in pairs({ LazyGit = "toggle", LazyGitOpen = "open" }) do
  vim.api.nvim_create_user_command(name, function(opts)
    require("lazygit")[method](directory(opts))
  end, { nargs = "?", complete = "dir", desc = "Open or resume LazyGit" })
end

for name, method in pairs({
  LazyGitHide = "hide",
  LazyGitClose = "close",
  LazyGitEditDone = "edit_done",
  LazyGitEditAbort = "edit_abort",
}) do
  vim.api.nvim_create_user_command(name, function()
    require("lazygit")[method]()
  end, { desc = name })
end
