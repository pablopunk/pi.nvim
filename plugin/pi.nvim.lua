-- pi.nvim - Neovim plugin for pi coding agent
-- Maintainer: pablopunk
-- License: MIT

if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = true

-- Commands
vim.api.nvim_create_user_command("PiAsk", function()
  require("pi").prompt_with_buffer()
end, { desc = "Ask pi with current buffer as context" })

vim.api.nvim_create_user_command("PiAskSelection", function()
  require("pi").prompt_with_selection()
end, { range = true, desc = "Ask pi with visual selection as context" })
