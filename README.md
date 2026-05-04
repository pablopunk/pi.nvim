# pi.nvim

A Neovim plugin for interacting with [pi](https://pi.dev) - the minimal cli agent.

<p align="center">
<a href="https://asciinema.org/a/k7XHTrbWKHp3dOAF?autoplay=1">
  <img src="https://github.com/pablopunk/pi.nvim/blob/main/assets/asciinema.gif?raw=true&forceUpdate" width="100%" />
</a>
</p>

It's funny that all AI plugins for Neovim are quite complex to interact with, like they want to imitate all current IDE features, while those are trending towards the simplicity of the CLI (which is the reason most users choose neovim in the first place). [pi.dev](https://pi.dev/) is the best example of this philosophy, and the perfect candidate to integrate in neovim.

## Features

- **Context aware**: Sends your current buffer, cwd, and selection as context.
- **Simple configuration**: Just set your preferred AI model.
- **Gets out of your way**: You ask it. It does it. Done.

## Requirements

- [Neovim](https://neovim.io/) 0.10+
- [pi](https://github.com/badlogic/pi-mono) installed globally: `npm install -g @mariozechner/pi-coding-agent`
- Your preferred models availble in pi: `pi --list-models`

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{ "pablopunk/pi.nvim" }
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use "pablopunk/pi.nvim"
```

### Using [mini.deps](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-deps.md)

```lua
MiniDeps.add("pablopunk/pi.nvim")
```

## Config

Provider and model are optional - pi will use your default configuration if not specified:

```lua
require("pi").setup()
```

Or override with specific values:

```lua
require("pi").setup({
  provider = "openrouter",
  model = "openrouter/free",
  system_prompt = "You are a helpful assistant.",
  append_system_prompt = "Always respond concisely.",
  max_context_lines = 300,
  max_context_bytes = 24000,
  selection_context_lines = 40,
  log_path = "/tmp/pi-nvim.log",
  skills = true,
  extensions = true,
  tools = true,
})
```

The `log_path` setting controls where all sessions are logged. Set to `nil` or empty string to disable logging. Default: `/tmp/pi-nvim.log`.

The `skills` setting controls whether pi discovers and loads skills (`--no-skills`). Default: `true`.

The `extensions` setting controls whether pi discovers and loads extensions (`--no-extensions`). Default: `true`.

The `tools` setting controls whether pi enables built-in tools (`--no-tools`). Default: `true`.

The `system_prompt` setting passes a custom system prompt to pi (`--system-prompt`). Default: `nil` (uses pi's default system prompt). Use with care, since this overrides pi's generated baseline instructions.

The `append_system_prompt` setting appends text to the system prompt (`--append-system-prompt`). pi.nvim always appends its non-interactive execution instruction, and this option is concatenated after it. Default: `nil`.

Use `pi --list-models` to see available models.

**Examples:**

This is basically the same as doing `pi --provider <provider> --model <model>`, so you can test it out on the cli to make sure it works.
```lua
-- OpenRouter kimi-k2.5
{ provider = "openrouter", model = "moonshotai/kimi-k2.5" }

-- OpenRouter haiku-4.5
{ provider = "openrouter", model = "anthropic/claude-haiku-4.5" }

-- Anthropic haiku-4-5
{ provider = "anthropic", model = "claude-haiku-4-5" }

-- OpenAI
{ provider = "openai", model = "gpt-4.1-mini" }
```

Run `pi --list-models` to see available options.

### Keymaps

No keymaps by default. You choose.

```lua
-- Ask pi with the current buffer as context
vim.keymap.set("n", "<leader>ai", ":PiAsk<CR>", { desc = "Ask pi" })

-- Ask pi with visual selection as context
vim.keymap.set("v", "<leader>ai", ":PiAskSelection<CR>", { desc = "Ask pi (selection)" })
```

## Usage

### Commands

| Command | Mode | Description |
|---------|------|-------------|
| `:PiAsk` | Normal | Prompt for input, sends it + current buffer as context |
| `:PiAskSelection` | Visual | Same as :PiAsk but also sends selected lines as context |
| `:PiCancel` | Normal | Cancel the active pi request immediately |
| `:PiLog` | Normal | Open the session log in a new split |

## Behavior

- Runs asynchronously and keeps editing nonblocking.
- Uses `nvim-notify` for status updates when available; otherwise falls back to a small floating status window.
- Reloads changed loaded buffers on success so pi's on-disk edits are reflected in Neovim.
- Trims oversized context for speed instead of always sending the full file.


## License

MIT
