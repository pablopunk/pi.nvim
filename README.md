# pi.nvim

A Neovim plugin for interacting with [pi](https://pi.dev) - the minimal cli agent.

<p align="center">
<a href="https://asciinema.org/a/RuG4c2kkhrLx1ChZ">
  <img src="https://github.com/pablopunk/pi.nvim/blob/main/assets/asciinema.gif?raw=true&forceUpdate" width="100%" />
</a>
</p>

It's funny that all AI plugins for Neovim are quite complex to interact with, like they want to imitate all current IDE features, while those are trending towards the simplicity of the CLI (which is the reason most users choose neovim in the first place). [pi.dev](https://pi.dev/) is the best example of this philosophy, and the perfect candidate to integrate in neovim.

## Features

- **Context aware**: Sends your current buffer, cwd, selection, and optional diagnostics as context.
- **Unsaved-buffer aware**: Tells pi to treat the sent Neovim buffer content as the source of truth, even if the on-disk file is stale.
- **Simple configuration**: Just set your preferred AI model.
- **Gets out of your way**: You ask it. It does it. Done.

## Requirements

- [Neovim](https://neovim.io/) 0.10+
- [pi](https://github.com/badlogic/pi-mono) installed globally: `curl -fsSL https://pi.dev/install.sh | sh`
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

All config is optional:

```lua
require("pi").setup()
```

Override only the ones you need:

```lua
require("pi").setup({
  binary = "~/.bin/pi", -- or { "env", "FOO=1", "pi-wrapper" }
  provider = "openrouter",
  model = "openrouter/free",
  thinking = "off", -- be careful, thinking is time-consuming, it's not a great experience if you want simplicity
  system_prompt = "You are a helpful assistant.",
  append_system_prompt = "Always respond concisely.",
  context = {
    max_bytes = 24000,
    ask = {
      surrounding_lines = 80,
    },
    selection = {
      surrounding_lines = 40,
    },
    diagnostics = {
      enabled = false,
    },
  },
  skills = true,
  extensions = true,
})
```

| Prop | Default | Description |
|------|---------|-------------|
| `binary` | `"pi"` | The binary to run when invoking pi. Can be a string or an array of strings. When omitted it is set to `"pi"`. Useful for custom pi installations or wrappers. |
| `provider` | `nil` | pi provider to use. If omitted, pi uses its own default configuration. |
| `model` | `nil` | Model name to use. If omitted, pi uses its own default configuration. |
| `thinking` | `"off"` | Sets pi's thinking level (`--thinking`). Supported values: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. |
| `system_prompt` | `nil` | Passes a custom system prompt to pi (`--system-prompt`). Use with care, since this overrides pi's generated baseline instructions. |
| `append_system_prompt` | `nil` | Appends text to the system prompt (`--append-system-prompt`). pi.nvim always appends its non-interactive execution instruction, and this option is concatenated after it. |
| `context.max_bytes` | `24000` | Maximum size in bytes for sent context before trimming. |
| `context.ask.surrounding_lines` | `80` | Number of lines before and after the current cursor line to include for `:PiAsk`. |
| `context.selection.surrounding_lines` | `40` | Number of lines before and after the current visual selection to include for `:PiAskSelection`. |
| `context.diagnostics.enabled` | `false` | Includes Neovim diagnostics in the sent context. `:PiAsk` sends all buffer diagnostics; `:PiAskSelection` sends only diagnostics overlapping the selected lines. |
| `skills` | `true` | Whether pi discovers and loads skills. Set to `false` to pass `--no-skills`. |
| `extensions` | `true` | Whether pi discovers and loads extensions. Set to `false` to pass `--no-extensions`. |

Use `pi --list-models` to see available models.

**Examples:**

This is basically the same as doing `pi --provider <provider> --model <model>`, so you can test it out on the cli to make sure it works.
```lua
-- OpenRouter kimi-k2.5
{ provider = "openrouter", model = "moonshotai/kimi-k2.5" }

-- OpenAI overriding the default thinking level
{ provider = "openai", model = "gpt-5-mini", thinking = "high" }

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
- Treats sent buffer/selection context as newer than disk, so unsaved Neovim changes are the source of truth for the agent.
- Optionally includes Neovim diagnostics from LSPs/linters via `vim.diagnostic`.
- Trims oversized context for speed instead of always sending the full file.


## API

`pi.nvim` exposes `get_cmd()` and `run()` for programmatic use. See [this gist](https://gist.github.com/nhlmg93/49c1e5ec1e1df20b5050c770840cd7b2) for a minimal `:PiSearch` example built on `run()`.

## License

MIT
