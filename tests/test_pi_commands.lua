-- Tests for PiAsk and PiAskSelection commands
-- These tests mock the pi CLI and verify the prompt structure

local MiniTest = require("mini.test")

-- Create child process
local child = MiniTest.new_child_neovim()

-- Helper to setup the test environment
local function setup_test_env()
  -- Use restart to handle case where child might already be running
  child.restart({ "-u", "tests/minimal_init.lua" })
  -- Load the plugin
  child.lua('require("pi").setup({})')
end

-- Helper to mock vim.fn.jobstart and capture the command and stdin
local function mock_jobstart()
  child.lua([[
    _G.__pi_test_captured = {
      cmd = nil,
      stdin = nil,
      job_id = 123,
    }

    _G.__pi_test_original_jobstart = vim.fn.jobstart
    _G.__pi_test_original_chansend = vim.fn.chansend
    _G.__pi_test_original_chanclose = vim.fn.chanclose

    vim.fn.jobstart = function(cmd, opts)
      _G.__pi_test_captured.cmd = cmd
      return _G.__pi_test_captured.job_id
    end

    vim.fn.chansend = function(job, data)
      if job == _G.__pi_test_captured.job_id then
        _G.__pi_test_captured.stdin = data
      end
      return 1
    end

    vim.fn.chanclose = function() end
  ]])

  return {
    get_cmd = function()
      return child.lua_get([[_G.__pi_test_captured.cmd]])
    end,
    get_stdin = function()
      return child.lua_get([[_G.__pi_test_captured.stdin]])
    end,
  }
end

-- Helper to trigger PiAsk and capture what would be sent to pi
local function run_pi_ask(input_text)
  local captured = mock_jobstart()

  child.lua(string.format(
    [[
    vim.ui.input = function(opts, callback)
      callback(%q)
    end
  ]],
    input_text
  ))

  child.cmd("PiAsk")

  return captured
end

-- Helper to run PiAskSelection with visual selection
-- Sets up visual marks '< and '> to simulate a selection
local function run_pi_ask_selection(input_text, start_line, end_line)
  local captured = mock_jobstart()

  -- Set visual marks directly using nvim_buf_set_mark
  -- mark = '< is the start of visual selection, '> is the end
  child.api.nvim_buf_set_mark(0, "<", start_line, 0, {})
  child.api.nvim_buf_set_mark(0, ">", end_line, 999, {})

  -- Mock vim.ui.input
  child.lua(string.format(
    [[
    vim.ui.input = function(opts, callback)
      callback(%q)
    end
  ]],
    input_text
  ))

  child.cmd("PiAskSelection")

  return captured
end

-- Helper to decode the JSON prompt sent to pi
local function decode_prompt(captured)
  local stdin = captured.get_stdin()
  if not stdin then
    return nil
  end
  return child.lua(
    [[
    local stdin = ...
    local ok, result = pcall(vim.json.decode, stdin)
    if ok then
      return result
    end
    return nil
  ]],
    { stdin }
  )
end

-- Helper to create a buffer with content for testing
local function setup_buffer(lines, filename)
  child.lua(
    [[
    local lines = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  ]],
    { lines }
  )

  if filename then
    child.lua(
      [[
      local filename = ...
      vim.api.nvim_buf_set_name(0, filename)
    ]],
      { filename }
    )
  end
end

-- Test PiAsk command sends user message to pi
local function test_pi_ask_sends_message()
  setup_test_env()
  setup_buffer({ "some code here" }, "/test/file.lua")

  local captured = run_pi_ask("help me refactor this")
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(prompt.type, "prompt")
  MiniTest.expect.equality(prompt.message:match("help me refactor this"), "help me refactor this")
end

-- Test PiAsk includes buffer context
local function test_pi_ask_includes_context()
  setup_test_env()
  setup_buffer({ "local x = 1", "local y = 2" }, "/test/file.lua")

  local captured = run_pi_ask("what does this do")
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(prompt.message:match("local x = 1"), "local x = 1")
  MiniTest.expect.equality(prompt.message:match("local y = 2"), "local y = 2")
  MiniTest.expect.equality(prompt.message:match("/test/file.lua"), "/test/file.lua")
end

-- Test PiAsk includes system prompt
local function test_pi_ask_includes_system_prompt()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local captured = run_pi_ask("hello")
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(
    prompt.message:match("You are running inside the pi.nvim"),
    "You are running inside the pi.nvim"
  )
end

-- Test PiAsk uses correct command
local function test_pi_ask_command()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local captured = run_pi_ask("test")
  local cmd = captured.get_cmd()

  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(cmd[2], "--mode")
  MiniTest.expect.equality(cmd[3], "rpc")
  MiniTest.expect.equality(cmd[4], "--no-session")
end

local function test_pi_ask_requires_file()
  setup_test_env()
  setup_buffer({ "code" }, nil)

  child.lua([[
    _G.__pi_test_notifies = {}
    vim.notify = function(msg, level)
      table.insert(_G.__pi_test_notifies, { msg = msg, level = level })
    end
    vim.ui.input = function()
      error("vim.ui.input should not be called when the buffer has no file")
    end
  ]])

  child.cmd("PiAsk")

  local notifications = child.lua_get([[_G.__pi_test_notifies]])
  MiniTest.expect.equality(#notifications > 0, true)
  local last = notifications[#notifications]
  local error_level = child.lua_get([[vim.log.levels.ERROR]])
  MiniTest.expect.equality(last.level, error_level)
  MiniTest.expect.equality(last.msg:match("file"), "file")
end

local function test_pi_ask_empty_file_note()
  setup_test_env()
  setup_buffer({ "" }, "/test/new.lua")

  local captured = run_pi_ask("scaffold this file")
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(
    prompt.message:match("NOTE: This file is currently empty"),
    "NOTE: This file is currently empty"
  )
end

-- Test PiAskSelection sends user message
local function test_pi_ask_selection_sends_message()
  setup_test_env()
  setup_buffer({
    "line 1",
    "line 2",
    "line 3 - SELECTED",
    "line 4 - SELECTED",
    "line 5",
  }, "/test/selection.lua")

  -- Select lines 3-4
  local captured = run_pi_ask_selection("explain this selection", 3, 4)
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(prompt.message:match("explain this selection"), "explain this selection")
end

-- Test PiAskSelection includes full file and selection
local function test_pi_ask_selection_includes_context()
  setup_test_env()
  setup_buffer({
    "first line",
    "second line",
    "third line",
  }, "/test/full.lua")

  -- Select lines 2-3
  local captured = run_pi_ask_selection("test", 2, 3)
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(prompt.message:match("first line"), "first line")
  MiniTest.expect.equality(prompt.message:match("second line"), "second line")
  MiniTest.expect.equality(prompt.message:match("third line"), "third line")
  MiniTest.expect.equality(prompt.message:match("Selected lines 2%-3"), "Selected lines 2-3")
end

-- Test PiAskSelection includes selection separately
local function test_pi_ask_selection_separate()
  setup_test_env()
  setup_buffer({
    "before",
    "selected content",
    "after",
  }, "/test/select.lua")

  -- Select line 2
  local captured = run_pi_ask_selection("test", 2, 2)
  local prompt = decode_prompt(captured)

  local _, selection_count = prompt.message:gsub("selected content", "")
  MiniTest.expect.equality(selection_count >= 1, true)
end

-- Test PiAskSelection uses correct command
local function test_pi_ask_selection_command()
  setup_test_env()
  setup_buffer({ "code" }, "/test/selection.lua")

  local captured = run_pi_ask_selection("test", 1, 1)
  local cmd = captured.get_cmd()

  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(cmd[2], "--mode")
  MiniTest.expect.equality(cmd[3], "rpc")
end

local function test_pi_ask_selection_requires_file()
  setup_test_env()
  setup_buffer({ "code" }, nil)

  child.lua([[
    _G.__pi_test_notifies = {}
    vim.notify = function(msg, level)
      table.insert(_G.__pi_test_notifies, { msg = msg, level = level })
    end
    vim.ui.input = function()
      error("vim.ui.input should not be called when the buffer has no file")
    end
  ]])

  child.cmd("PiAskSelection")

  local notifications = child.lua_get([[_G.__pi_test_notifies]])
  MiniTest.expect.equality(#notifications > 0, true)
  local last = notifications[#notifications]
  local error_level = child.lua_get([[vim.log.levels.ERROR]])
  MiniTest.expect.equality(last.level, error_level)
  MiniTest.expect.equality(last.msg:match("PiAskSelection"), "PiAskSelection")
end

local function test_pi_ask_selection_empty_file_note()
  setup_test_env()
  setup_buffer({ "" }, "/test/new_selection.lua")

  local captured = run_pi_ask_selection("create this file", 1, 1)
  local prompt = decode_prompt(captured)

  MiniTest.expect.equality(
    prompt.message:match("NOTE: This file is currently empty"),
    "NOTE: This file is currently empty"
  )
end

-- Test custom provider configuration
local function test_custom_provider()
  setup_test_env()
  child.lua([[require("pi").setup({ provider = "openai" })]])

  setup_buffer({ "code" }, "/test/provider.lua")
  local captured = run_pi_ask("test")
  local cmd = captured.get_cmd()

  local provider_found = false
  for i, v in ipairs(cmd) do
    if v == "--provider" and cmd[i + 1] == "openai" then
      provider_found = true
      break
    end
  end
  MiniTest.expect.equality(provider_found, true)
end

-- Test custom model configuration
local function test_custom_model()
  setup_test_env()
  child.lua([[require("pi").setup({ model = "gpt-4" })]])

  setup_buffer({ "code" }, "/test/model.lua")
  local captured = run_pi_ask("test")
  local cmd = captured.get_cmd()

  local model_found = false
  for i, v in ipairs(cmd) do
    if v == "--model" and cmd[i + 1] == "gpt-4" then
      model_found = true
      break
    end
  end
  MiniTest.expect.equality(model_found, true)
end

-- Define test set manually with cases as functions
local T = MiniTest.new_set()

T["PiAsk"] = MiniTest.new_set()
T["PiAsk"]["sends user message to pi"] = test_pi_ask_sends_message
T["PiAsk"]["includes buffer context in prompt"] = test_pi_ask_includes_context
T["PiAsk"]["includes system prompt in context"] = test_pi_ask_includes_system_prompt
T["PiAsk"]["uses correct pi command"] = test_pi_ask_command
T["PiAsk"]["requires a file"] = test_pi_ask_requires_file
T["PiAsk"]["adds note when file is empty"] = test_pi_ask_empty_file_note

T["PiAskSelection"] = MiniTest.new_set()
T["PiAskSelection"]["sends user message with selection context"] = test_pi_ask_selection_sends_message
T["PiAskSelection"]["includes full file and selection in context"] = test_pi_ask_selection_includes_context
T["PiAskSelection"]["includes selection content separately"] = test_pi_ask_selection_separate
T["PiAskSelection"]["uses correct pi command"] = test_pi_ask_selection_command
T["PiAskSelection"]["requires a file"] = test_pi_ask_selection_requires_file
T["PiAskSelection"]["adds note when file is empty"] = test_pi_ask_selection_empty_file_note

T["Configuration"] = MiniTest.new_set()
T["Configuration"]["uses custom provider when configured"] = test_custom_provider
T["Configuration"]["uses custom model when configured"] = test_custom_model

return T
