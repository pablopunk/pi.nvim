--- Configuration helpers for pi.nvim.
local M = {}

local VALID_THINKING_LEVELS = {
  off = true,
  minimal = true,
  low = true,
  medium = true,
  high = true,
  xhigh = true,
}

M.defaults = {
  binary = "pi",
  provider = nil,
  model = nil,
  thinking = "off",
  system_prompt = nil,
  append_system_prompt = nil,
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
}

local values = vim.deepcopy(M.defaults)

--- Validates a positive numeric configuration value.
--- @param name string Human-readable config key name.
--- @param value number Value to validate.
local function validate_number(name, value)
  if type(value) ~= "number" or value < 1 then
    error(string.format("pi.nvim: %s must be a positive number", name))
  end
end

--- Validates user-provided configuration overrides.
--- @param opts table User configuration passed to `setup`.
function M.validate(opts)
  if opts.binary ~= nil and not (type(opts.binary) == "string" or type(opts.binary) == "table") then
    error("pi.nvim: binary must be a string or list of strings")
  end

  if type(opts.binary) == "table" then
    for i, v in ipairs(opts.binary) do
      if type(v) ~= "string" then
        error(string.format("pi.nvim: binary[%d] must be a string", i))
      end
    end
  end

  local context = opts.context
  if context ~= nil then
    if type(context) ~= "table" then
      error("pi.nvim: context must be a table")
    end
    if context.max_bytes ~= nil then
      validate_number("context.max_bytes", context.max_bytes)
    end
    if context.ask ~= nil then
      if type(context.ask) ~= "table" then
        error("pi.nvim: context.ask must be a table")
      end
      if context.ask.surrounding_lines ~= nil then
        validate_number("context.ask.surrounding_lines", context.ask.surrounding_lines)
      end
    end
    if context.selection ~= nil then
      if type(context.selection) ~= "table" then
        error("pi.nvim: context.selection must be a table")
      end
      if context.selection.surrounding_lines ~= nil then
        validate_number("context.selection.surrounding_lines", context.selection.surrounding_lines)
      end
    end
    if context.diagnostics ~= nil then
      if type(context.diagnostics) ~= "table" then
        error("pi.nvim: context.diagnostics must be a table")
      end
      if context.diagnostics.enabled ~= nil and type(context.diagnostics.enabled) ~= "boolean" then
        error("pi.nvim: context.diagnostics.enabled must be a boolean")
      end
    end
  end
  if opts.skills ~= nil and type(opts.skills) ~= "boolean" then
    error("pi.nvim: skills must be a boolean")
  end
  if opts.extensions ~= nil and type(opts.extensions) ~= "boolean" then
    error("pi.nvim: extensions must be a boolean")
  end
  if opts.thinking ~= nil then
    if type(opts.thinking) ~= "string" then
      error("pi.nvim: thinking must be a string")
    end
    if not VALID_THINKING_LEVELS[opts.thinking] then
      error("pi.nvim: thinking must be one of: off, minimal, low, medium, high, xhigh")
    end
  end
  if opts.system_prompt ~= nil and type(opts.system_prompt) ~= "string" then
    error("pi.nvim: system_prompt must be a string")
  end
  if opts.append_system_prompt ~= nil and type(opts.append_system_prompt) ~= "string" then
    error("pi.nvim: append_system_prompt must be a string")
  end
end

--- Merges user options with defaults and stores the effective config.
--- @param opts? table User configuration overrides.
--- @return table values Effective configuration.
function M.setup(opts)
  opts = opts or {}
  M.validate(opts)
  values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return values
end

--- Returns the currently active configuration.
--- @return table values Effective configuration.
function M.get()
  return values
end

return M
