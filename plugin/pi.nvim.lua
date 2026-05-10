-- pi.nvim - Neovim plugin for pi coding agent
-- Maintainer: pablopunk
-- License: MIT

-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = true

-- Register user-facing commands exposed by the plugin.

-- Open a prompt using the current buffer as additional context.
vim.api.nvim_create_user_command("PiAsk", function()
  require("pi").prompt_with_buffer()
end, { desc = "Ask pi with current buffer as context" })

-- Open a prompt using the current visual selection as context.
vim.api.nvim_create_user_command("PiAskSelection", function()
  require("pi").prompt_with_selection()
end, { range = true, desc = "Ask pi with visual selection as context" })

-- Search the project semantically and populate the quickfix list.
vim.api.nvim_create_user_command("PiSearch", function()
  require("pi").search()
end, { desc = "Search project with pi and open quickfix results" })

-- Cancel the currently running pi request, if there is one.
vim.api.nvim_create_user_command("PiCancel", function()
  require("pi").cancel()
end, { desc = "Cancel the active pi request" })

-- Show the pi.nvim session log
vim.api.nvim_create_user_command("PiLog", function()
  require("pi").show_log()
end, { desc = "Show pi session log" })
