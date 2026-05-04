local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

local function flush()
  child.lua([[vim.wait(50, function() return false end, 10)]])
end

local function setup_test_env(setup_code)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[
    _G.__pi_test_notifications = {}
    _G.__pi_force_notify_backend = true
    vim.notify = function(msg, level)
      table.insert(_G.__pi_test_notifications, { msg = msg, level = level })
    end
  ]])
  child.lua(setup_code or 'require("pi").setup({})')
end

local function setup_buffer(lines, filename)
  child.lua(
    [[
      local lines, filename = ...
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      if filename then
        vim.api.nvim_buf_set_name(0, filename)
      end
    ]],
    { lines, filename }
  )
end

local function mock_system()
  child.lua([[
    _G.__pi_test_system = {
      cmd = nil,
      opts = nil,
      on_exit = nil,
      killed = nil,
      closing = false,
      writes = {},
      stdin_closed = false,
    }

    vim.system = function(cmd, opts, on_exit)
      _G.__pi_test_system.cmd = cmd
      _G.__pi_test_system.opts = opts
      _G.__pi_test_system.on_exit = on_exit
      return {
        write = function(_, data)
          table.insert(_G.__pi_test_system.writes, data)
        end,
        kill = function(_, signal)
          _G.__pi_test_system.killed = signal
          _G.__pi_test_system.closing = true
        end,
        is_closing = function()
          return _G.__pi_test_system.closing
        end,
        _state = {
          stdin = {
            close = function()
              _G.__pi_test_system.stdin_closed = true
              _G.__pi_test_system.closing = true
            end,
            flush = function()
              -- No-op in tests
            end,
          },
        },
      }
    end
  ]])

  return {
    get_cmd = function()
      return child.lua_get([[_G.__pi_test_system.cmd]])
    end,
    get_stdin = function()
      return child.lua_get([[table.concat(_G.__pi_test_system.writes, "")]])
    end,
    stdin_was_closed = function()
      return child.lua_get([[_G.__pi_test_system.stdin_closed]])
    end,
    stdout = function(data)
      child.lua([[ _G.__pi_test_system.opts.stdout(nil, ...) ]], { data })
      flush()
    end,
    stderr = function(data)
      child.lua([[ _G.__pi_test_system.opts.stderr(nil, ...) ]], { data })
      flush()
    end,
    exit = function(code, signal)
      child.lua([[ _G.__pi_test_system.on_exit({ code = ..., signal = ... }) ]], { code, signal or 0 })
      flush()
    end,
    killed = function()
      return child.lua_get([[_G.__pi_test_system.killed]])
    end,
  }
end

local function run_pi_ask(input_text)
  local system = mock_system()
  child.lua(string.format(
    [[
      vim.ui.input = function(_, callback)
        callback(%q)
      end
    ]],
    input_text
  ))
  child.cmd("PiAsk")
  flush()
  return system
end

local function run_pi_ask_selection(input_text, start_line, end_line)
  local system = mock_system()
  child.api.nvim_buf_set_mark(0, "<", start_line, 0, {})
  child.api.nvim_buf_set_mark(0, ">", end_line, 999, {})
  child.lua(string.format(
    [[
      vim.ui.input = function(_, callback)
        callback(%q)
      end
    ]],
    input_text
  ))
  child.cmd("PiAskSelection")
  flush()
  return system
end

local function decode_prompt(stdin)
  return child.lua(
    [[
      local stdin = ...
      return vim.json.decode(vim.trim(stdin))
    ]],
    { stdin }
  )
end

local function notifications()
  return child.lua_get([[_G.__pi_test_notifications]])
end

local function last_notification()
  local items = notifications()
  return items[#items]
end

local function write_file(path, lines)
  child.lua(
    [[
      local path, lines = ...
      vim.fn.writefile(lines, path)
    ]],
    { path, lines }
  )
end

local function has_arg(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return i
    end
  end
  return nil
end

local function test_pi_ask_uses_vim_system_command()
  setup_test_env()
  setup_buffer({ "print('hello')" }, "/test/file.lua")

  local system = run_pi_ask("refactor this")
  local cmd = system.get_cmd()
  local stdin_mode = child.lua_get([[_G.__pi_test_system.opts.stdin]])

  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(cmd[2], "--mode")
  MiniTest.expect.equality(cmd[3], "rpc")
  MiniTest.expect.equality(cmd[4], "--no-session")
  MiniTest.expect.equality(stdin_mode, true)

  local append_idx = has_arg(cmd, "--append-system-prompt")
  MiniTest.expect.no_equality(append_idx, nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("running inside the pi.nvim Neovim plugin"), nil)
end

local function test_pi_ask_includes_context_and_message()
  setup_test_env()
  setup_buffer({ "local x = 1", "local y = 2" }, "/test/file.lua")

  local system = run_pi_ask("what does this do")
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.type, "prompt")
  MiniTest.expect.equality(prompt.message:match("what does this do"), "what does this do")
  MiniTest.expect.equality(prompt.message:match("File: /test/file.lua"), "File: /test/file.lua")
  MiniTest.expect.equality(prompt.message:match("local x = 1"), "local x = 1")
  MiniTest.expect.equality(prompt.message:match("running inside the pi.nvim Neovim plugin"), nil)
end

local function test_pi_ask_requires_file()
  setup_test_env()
  setup_buffer({ "code" }, nil)
  child.lua([[
    vim.ui.input = function()
      error("vim.ui.input should not be called")
    end
  ]])

  child.cmd("PiAsk")

  local notification = last_notification()
  MiniTest.expect.equality(notification.msg:match("file"), "file")
end

local function test_context_is_trimmed_for_speed()
  setup_test_env('require("pi").setup({ max_context_lines = 2, max_context_bytes = 16 })')
  setup_buffer({ "line one", "line two", "line three" }, "/test/trim.lua")

  local system = run_pi_ask("trim it")
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("trimmed for speed"), "trimmed for speed")
end

local function test_selection_uses_nearby_context()
  setup_test_env('require("pi").setup({ selection_context_lines = 1, max_context_bytes = 1000 })')
  setup_buffer({ "line1", "line2", "line3", "line4", "line5", "line6" }, "/test/select.lua")

  local system = run_pi_ask_selection("focus selection", 3, 4)
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Selected lines: 3%-4"), "Selected lines: 3-4")
  MiniTest.expect.equality(prompt.message:match("Nearby context %(2%-5%)"), "Nearby context (2-5)")
  MiniTest.expect.equality(prompt.message:match("line1"), nil)
  MiniTest.expect.equality(prompt.message:match("line6"), nil)
end

local function test_chunked_stdout_updates_and_success_notifies_done()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("go")
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), true)

  system.stdout('{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta"}}')
  system.stdout('\n{"type":"tool_execution_start","toolName":"read_file"}\n')

  local active_tool = child.lua_get([[require("pi")._get_active_session().active_tool]])
  MiniTest.expect.equality(active_tool, "read_file")

  system.stdout('{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
end

local function test_error_notifies_and_clears_ui_state()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("break")
  system.stdout('{"type":"response","success":false,"error":"boom"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(1, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "error")
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
  MiniTest.expect.equality(last_notification().msg:match("boom"), "boom")
end

local function test_clean_exit_without_agent_end_is_an_error()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("break")
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "error")
  MiniTest.expect.equality(last_notification().msg:match("before completing request"), "before completing request")
end

local function test_turn_end_does_not_finish_session()
  -- Regression: turn_end means one agent turn finished, not the whole run.
  -- During multi-step tool workflows, the agent emits turn_end between turns
  -- and only emits agent_end when the entire run is complete. See PR #4.
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("multi-turn")

  -- Simulate: tool call -> turn_end with stopReason="toolUse" -> another turn
  system.stdout('{"type":"tool_execution_start","toolName":"edit"}\n')
  system.stdout('{"type":"tool_execution_end","toolName":"edit"}\n')
  system.stdout('{"type":"turn_end","stopReason":"toolUse"}\n')

  -- Session must still be running; stdin must not be closed.
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), true)
  MiniTest.expect.equality(system.stdin_was_closed(), false)

  -- Now the actual terminal event arrives.
  system.stdout('{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "done")
end

local function test_turn_end_followed_by_agent_end_completes()
  -- Single-turn runs emit turn_end immediately followed by agent_end.
  -- Ensure that pattern still completes cleanly.
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("single turn")
  system.stdout('{"type":"turn_end","stopReason":"endTurn"}\n{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "done")
end

local function test_cancel_kills_process_and_closes_immediately()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("cancel me")
  child.cmd("PiCancel")
  flush()

  MiniTest.expect.equality(system.killed(), 15)
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
end

local function test_skills_option_disables_skills()
  setup_test_env('require("pi").setup({ skills = false })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("test")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-skills"), nil)
end

local function test_extensions_option_disables_extensions()
  setup_test_env('require("pi").setup({ extensions = false })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("test")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-extensions"), nil)
end

local function test_tools_option_disables_tools()
  setup_test_env('require("pi").setup({ tools = false })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("test")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-tools"), nil)
end

local function test_append_system_prompt_is_concatenated()
  setup_test_env('require("pi").setup({ append_system_prompt = "Always run tests" })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_ask("test")
  local cmd = system.get_cmd()
  local append_idx = has_arg(cmd, "--append-system-prompt")

  MiniTest.expect.no_equality(append_idx, nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("running inside the pi.nvim Neovim plugin"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("Always run tests"), nil)
end

local function test_second_request_is_blocked_while_running()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  run_pi_ask("first")
  child.lua([[
    vim.ui.input = function(_, callback)
      callback("second")
    end
  ]])
  child.cmd("PiAsk")

  local notification = last_notification()
  MiniTest.expect.equality(notification.msg:match("already running"), "already running")
end

local function test_success_overwrites_modified_buffer_with_disk_edits()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "from disk" })
  setup_buffer({ "code" }, file)
  child.lua([[vim.bo.modified = true]])

  local system = run_pi_ask("finish")
  write_file(file, { "updated on disk" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[vim.bo.modified]]), false)
  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  MiniTest.expect.equality(lines[1], "updated on disk")
end

local function test_success_reloads_all_changed_loaded_buffers()
  setup_test_env()
  local file_one = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  local file_two = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file_one, { "one before" })
  write_file(file_two, { "two before" })
  setup_buffer({ "one buffer edit" }, file_one)
  child.lua([[vim.cmd("edit " .. ...)]], { file_two })
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two buffer edit" })]])
  child.lua([[vim.bo.modified = true]])
  child.lua([[vim.cmd("buffer #")]])
  child.lua([[vim.bo.modified = true]])

  local system = run_pi_ask("finish")
  write_file(file_one, { "one after agent edit" })
  write_file(file_two, { "two after agent edit" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local buffers = child.lua_get([[{
    one = vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false),
    one_modified = vim.bo[vim.fn.bufnr(...)].modified,
    two = vim.api.nvim_buf_get_lines(vim.fn.bufnr(select(2, ...)), 0, -1, false),
    two_modified = vim.bo[vim.fn.bufnr(select(2, ...))].modified,
  }]], { file_one, file_two })
  MiniTest.expect.equality(buffers.one[1], "one after agent edit")
  MiniTest.expect.equality(buffers.one_modified, false)
  MiniTest.expect.equality(buffers.two[1], "two after agent edit")
  MiniTest.expect.equality(buffers.two_modified, false)
end

local function test_success_reloads_unmodified_buffer()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "from disk" })
  setup_buffer({ "code" }, file)
  child.lua([[vim.bo.modified = false]])

  local system = run_pi_ask("finish")
  write_file(file, { "updated on disk" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  MiniTest.expect.equality(lines[1], "updated on disk")
end

local T = MiniTest.new_set()

T["PiAsk"] = MiniTest.new_set()
T["PiAsk"]["uses vim.system command"] = test_pi_ask_uses_vim_system_command
T["PiAsk"]["includes prompt message and context"] = test_pi_ask_includes_context_and_message
T["PiAsk"]["requires a file"] = test_pi_ask_requires_file
T["PiAsk"]["trims context for speed"] = test_context_is_trimmed_for_speed
T["PiAsk"]["blocks second request while running"] = test_second_request_is_blocked_while_running
T["PiAsk"]["overwrites modified buffer with disk edits on success"] = test_success_overwrites_modified_buffer_with_disk_edits
T["PiAsk"]["reloads unmodified buffer on success"] = test_success_reloads_unmodified_buffer
T["PiAsk"]["reloads all changed loaded buffers on success"] = test_success_reloads_all_changed_loaded_buffers
T["PiAsk"]["skills option disables skills"] = test_skills_option_disables_skills
T["PiAsk"]["extensions option disables extensions"] = test_extensions_option_disables_extensions
T["PiAsk"]["tools option disables tools"] = test_tools_option_disables_tools
T["PiAsk"]["append_system_prompt is concatenated with plugin prompt"] = test_append_system_prompt_is_concatenated

T["PiAskSelection"] = MiniTest.new_set()
T["PiAskSelection"]["uses nearby context"] = test_selection_uses_nearby_context

T["Session"] = MiniTest.new_set()
T["Session"]["handles chunked stdout and notifies on success"] = test_chunked_stdout_updates_and_success_notifies_done
T["Session"]["notifies and clears UI state on error"] = test_error_notifies_and_clears_ui_state
T["Session"]["clean exit without terminal event is an error"] = test_clean_exit_without_agent_end_is_an_error
T["Session"]["turn_end does not finish session (multi-turn tool use)"] = test_turn_end_does_not_finish_session
T["Session"]["turn_end followed by agent_end completes"] = test_turn_end_followed_by_agent_end_completes
T["Session"]["cancel closes immediately"] = test_cancel_kills_process_and_closes_immediately

return T
