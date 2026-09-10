io.stdout:write("FAKE_LAZYGIT_READY\n")
io.stdout:flush()
local input = assert(vim.uv.new_tty(0, true))
input:read_start(function(err, data)
  assert(not err, err)
  if data and data:find("q", 1, true) then
    vim.schedule(function()
      input:read_stop()
      input:close()
      vim.cmd("qa!")
    end)
  end
end)
vim.wait(60000, function()
  return false
end)
