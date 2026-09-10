# lazygit.nvim

LazyGit in a dedicated Neovim tab, without nested editors or manual remote-editor
setup. Open files back in your editing tab, keep your place in LazyGit when

hiding it, and return automatically after editing commit messages or rebase files.

## Install

Using Neovim's built-in package manager (0.12+):

```lua
vim.pack.add({
  { src = "https://github.com/HampusHauffman/lazygit.nvim" },
})

require("lazygit").setup()
vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })
```

Requires `git` and `lazygit` on Linux or macOS with a POSIX-compatible shell.
The plugin itself supports Neovim 0.10+.
## Usage

| Key or command | Action |
| --- | --- |
| `<leader>gg` / `:LazyGit` | Open or toggle LazyGit for the current repository. |
| `e` / `o` in LazyGit | Close its tab and open the selected file in your editing tab. |
| `Ctrl-g` / `:LazyGitHide` | Close its tab, preserving the process and navigation state. |
| `q` in LazyGit / `:LazyGitClose` | Quit and close the tab. Reopening starts a new process. |
| `:LazyGitOpen /path/to/repo` | Open or resume another repository. |

Enter, Escape, and `q` retain LazyGit's own behavior in terminal-input mode.
Each repository has a reusable session; your other tabs and unsaved buffers
are preserved.

External Git editors open in a split. Use `:wq` or `:LazyGitEditDone` to save
and return to LazyGit, or `:LazyGitEditAbort` to cancel. Writing alone does not
finish the request. Failed subprocesses still require LazyGit's native Enter
acknowledgment.

## Configuration

These are the defaults; `setup()` is optional:

```lua
require("lazygit").setup({
  window = { type = "tab" }, -- "float" for a popup
  keys = { hide = "<C-g>" }, -- false to disable
  config_files = nil,
})
```

Your normal LazyGit config is retained. The plugin adds temporary editor
settings without rewriting it or changing Neovim's environment. No manual
`os.edit` or `GIT_EDITOR` configuration is needed.

Set `config_files` to a list of config paths to override the defaults, or `{}`
to omit the global config. Repository-local `os.edit*` / `os.open*` overrides
can interfere with the integration.

See `:help lazygit` for all options and commands, or `:checkhealth lazygit`
for diagnostics.
