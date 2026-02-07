# pi.nvim

A Neovim plugin for interacting with [pi](https://pi.dev) - the minimal cli agent.

<p align="center">
<a href="https://asciinema.org/a/k7XHTrbWKHp3dOAF?autoplay=1">
  <img src="https://github.com/pablopunk/pi.nvim/blob/main/assets/asciinema.gif?raw=true&forceUpdate" width="100%" />
</a>
</p>

It's funny that all AI plugins for Neovim are quite complex to interact with, like they want to imitate all current IDE features, while those are trending towards the simplicity of the CLI (which is the reason most users choose neovim in the first place). [pi.dev](https://pi.dev/) is the best example of this philosophy, and the perfect candidate to integrate in neovim.

## Features

- **Context aware**: Sends your current buffer + selection as context.
- **Simple configuration**: Just set your preferred AI model.
- **Gets out of your way**: You ask it. It does it. Done.

## Requirements

- [Neovim](https://neovim.io/) 0.7+
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

```lua
require("pi").setup({
  provider = "openrouter",
  model = "openrouter/free", -- default
})
```

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
| `:PiAsk` | Normal | Prompt for input, sends with full buffer as context |
| `:PiAskSelection` | Visual | Prompt for input, sends with visual selection as context |


## License

MIT
