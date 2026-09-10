# LazyGit.nvim

LazyGit in a dedicated Neovim tab, with files and external editors opened in
your existing Neovim session.

## Why this plugin?

Running LazyGit in a terminal is easy. Moving between that terminal and your
editor is less straightforward: editing a file can launch another editor,
closing a window can lose your place in LazyGit, and an external Git editor
needs to tell the waiting process when you are finished.

LazyGit.nvim handles that round trip:

- **Open a file:** LazyGit's `e` and `o` actions close its tab and open the file
  in your previous editing tab. Line-aware actions preserve the line number.
- **Hide and return:** `Ctrl-g` closes the LazyGit tab without stopping its
  process. Reopening restores your panel, selection, and navigation state.
- **Finish an external edit:** commit-message and rebase editor requests open
  a split in your editing tab. `:wq` saves, closes the split, and returns to
  LazyGit. `:LazyGitEditAbort` cancels the request.
- **Quit normally:** LazyGit's native quit ends the process and closes its tab.
  Your other tabs and splits remain in place.

This is still the real LazyGit interface, not a replacement Git UI. No `nvr`,
Python package, or shell alias is needed.

## Requirements

- Neovim 0.10 or newer.
- `git` and `lazygit` available on `PATH`.
- Linux or macOS with a POSIX-compatible shell, such as Bash or Zsh.

The integration targets LazyGit 0.64.1 and newer compatible releases. Windows
is not currently supported.

Disable other plugins providing `require("lazygit")` or `:LazyGit`, including
`kdheepak/lazygit.nvim`, before installing this one.

## Installation

### lazy.nvim

```lua
{
  "HampusHauffman/LazyGit.nvim",
  main = "lazygit",
  cmd = { "LazyGit", "LazyGitOpen" },
  keys = {
    { "<leader>gg", "<cmd>LazyGit<cr>", desc = "LazyGit" },
  },
  opts = {},
}
```

### Neovim's built-in package manager: `vim.pack.add`

On Neovim versions providing `vim.pack` (0.12+), add this to your configuration:

```lua
vim.pack.add({
  { src = "https://github.com/HampusHauffman/LazyGit.nvim" },
})

require("lazygit").setup()
vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })
```

### Native packages: `:packadd`

No plugin manager is required. Clone into an optional package directory:

```sh
mkdir -p ~/.local/share/nvim/site/pack/plugins/opt
git clone https://github.com/HampusHauffman/LazyGit.nvim \
  ~/.local/share/nvim/site/pack/plugins/opt/LazyGit.nvim
```

Then add to `init.lua`:

```lua
vim.cmd.packadd("LazyGit.nvim")
require("lazygit").setup()
vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })
```

If you use a custom data directory, substitute the directory printed by
`:lua print(vim.fn.stdpath("data"))` for `~/.local/share/nvim`.
Run `:helptags ALL` once after a manual installation to register the help file.

## Usage

| Command or key | Action |
| --- | --- |
| `:LazyGit` / `<leader>gg` | Open or toggle LazyGit for the current file's repository. |
| `:LazyGitOpen /path/to/repo` | Open or resume a particular repository. |
| `Ctrl-g` inside LazyGit / `:LazyGitHide` | Close its tab, keeping the process running. |
| `:LazyGitClose` | Stop the visible or last session and close its tab. |
| `:LazyGitEditDone` | Save and finish a pending external editor request. |
| `:LazyGitEditAbort` | Cancel a pending external editor request. |

Enter, Escape, and `q` in terminal-input mode belong to LazyGit. To enter
Neovim's terminal-normal mode, use `Ctrl-\ Ctrl-n`; `q` then hides the tab.
Closing the tab with `:tabclose` also preserves its process.

Each repository/worktree has its own reusable session. Opening a file reuses
an existing window displaying it when possible. Unsaved buffers are preserved,
and clean file buffers are refreshed when returning from LazyGit. Directory
editing opens Neovim's configured directory browser.

For blocking edits, `:write` alone does not finish the request: use `:wq` or
`:LazyGitEditDone`. A failed write leaves the request pending. Do not use `:cq`
to cancel, as that exits your entire Neovim.

Successful edits return without an extra Enter. LazyGit still requires Enter
to acknowledge a failed subprocess, including a cancelled editor. The plugin
preserves that failure rather than reporting a successful edit.

## Configuration

Calling `setup()` is optional unless you want to change the defaults.

```lua
require("lazygit").setup({
  executable = "lazygit",
  args = {},
  window = {
    type = "tab",
  },
  keys = {
    hide = "<C-g>", -- another key, or false to disable
  },
  config_files = nil,
})
```

A floating window remains available as an alternative:

```lua
require("lazygit").setup({
  window = {
    type = "float",
    width = 0.9,
    height = 0.9,
    border = "rounded",
  },
})
```

Width and height accept fractions of the available space or integer cell
counts. Hide and reopen a session to change its layout; stop and reopen it
to change its executable, arguments, configuration files, or hide mapping.

### LazyGit configuration

Keep your normal LazyGit configuration. For example:

```yaml
# ~/.config/lazygit/config.yml
gui:
  showFileTree: true
  scrollHeight: 3
```

No manual `os.edit` or `GIT_EDITOR` setup is necessary. The plugin appends a
temporary config for file/directory opening, line-aware editing, and returning
from subprocesses. Editor environment overrides apply only to the LazyGit
child process; your global config and Neovim environment are not rewritten.

By default, existing `LG_CONFIG_FILE` paths are honored, otherwise LazyGit's
normal global `config.yml` is used. To select files explicitly:

```lua
require("lazygit").setup({
  config_files = {
    vim.fn.expand("~/.config/lazygit/config.yml"),
    vim.fn.expand("~/.config/lazygit/theme.yml"),
  },
})
```

All listed files must exist; later files override earlier ones. An empty list
omits the global config. Use `config_files` instead of passing config flags
in `args`.

Repository-local LazyGit configs are still loaded afterward. Remove local
`os.edit*`, `os.open`, `os.openDirInEditor`, or
`promptToReturnFromSubprocess` overrides if they conflict with the integration.
Custom commands that hard-code another editor are not rewritten.

See `:help lazygit` for the full Lua API and options, or `:checkhealth lazygit`
for diagnostics.

## How it works

LazyGit's editor commands launch a clean, headless Neovim helper. The helper
sends filenames and optional line numbers as structured data over the parent
Neovim's local RPC socket. The parent closes the LazyGit tab and opens the
requested buffers; it does not scrape terminal output or simulate commands.

Ordinary file requests return immediately after loading. Blocking requests
keep the helper waiting until you finish or cancel, without blocking Neovim.

## Development

```sh
make test
make smoke
```

The first command runs headless integration tests. The second exercises a real
LazyGit process, including tab cleanup, file opening, external editing, and
terminal keys. Both use temporary repositories without creating commits.

To run the smoke test with an existing Neovim configuration:

```sh
LAZYGIT_TEST_CONFIG="$HOME/.config/nvim/init.lua" make smoke
```
