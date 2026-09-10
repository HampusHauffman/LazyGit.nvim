local M = {}

function M.check()
  vim.health.start("lazygit.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required")
  end
  if vim.fn.has("win32") == 1 then
    vim.health.error("The editor bridge currently supports Linux and macOS only")
  end
  local options = require("lazygit.config").options
  for _, executable in ipairs({ "git", options.executable }) do
    if vim.fn.executable(executable) == 1 then
      local result = vim.system({ executable, "--version" }, { text = true }):wait()
      if result.code == 0 then
        vim.health.ok(vim.trim(result.stdout))
      else
        vim.health.error(executable .. ": " .. vim.trim(result.stderr))
      end
    else
      vim.health.error("Executable not found: " .. executable)
    end
  end
  for _, path in ipairs(options.config_files or {}) do
    local full = vim.fn.fnamemodify(path, ":p")
    if vim.fn.filereadable(full) == 1 and not full:find(",", 1, true) then
      vim.health.ok("Config file: " .. full)
    else
      vim.health.error("Config path must exist and must not contain commas: " .. full)
    end
  end
  vim.health.info("Disable other plugins that provide the lazygit Lua module or :LazyGit command.")
  vim.health.info("Repository-local LazyGit os.* overrides can replace the editor bridge.")
end

return M
