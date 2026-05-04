local config = require("pi.config")
local context = require("pi.context")
local runner = require("pi.runner")
local session_mod = require("pi.session")
local ui = require("pi.ui")
local log = require("pi.log")

local M = {}

local active_session = nil
local last_session = nil

local function assert_supported_version()
  if vim.fn.has("nvim-0.10") == 0 then
    error("pi.nvim requires Neovim 0.10+")
  end
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not context.buffer_is_file_backed(bufnr) then
    vim.notify(string.format("%s requires a file", command_name), vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function build_append_system_prompt(cfg)
  local prompts = { context.get_system_prompt() }
  if cfg.append_system_prompt and cfg.append_system_prompt ~= "" then
    table.insert(prompts, cfg.append_system_prompt)
  end
  return table.concat(prompts, "\n\n")
end

local function get_pi_cmd()
  local cfg = config.get()
  local cmd = { "pi", "--mode", "rpc", "--no-session" }
  if not cfg.extensions then
    table.insert(cmd, "--no-extensions")
  end
  if not cfg.skills then
    table.insert(cmd, "--no-skills")
  end
  if not cfg.tools then
    table.insert(cmd, "--no-tools")
  end
  if cfg.provider then
    table.insert(cmd, "--provider")
    table.insert(cmd, cfg.provider)
  end
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end
  if cfg.system_prompt then
    table.insert(cmd, "--system-prompt")
    table.insert(cmd, cfg.system_prompt)
  end
  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, build_append_system_prompt(cfg))
  return cmd
end

local function set_status(session, status, message)
  if not session or session.closing then
    return
  end
  session.status = status
  if message then
    session_mod.push(session, message)
  end
  ui.update(session)
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function file_signature(path)
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  return {
    size = stat.size,
    mtime_sec = stat.mtime and stat.mtime.sec or 0,
    mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
  }
end

local function signatures_equal(a, b)
  if not a or not b then
    return a == b
  end

  return a.size == b.size and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec
end

local function snapshot_loaded_file_buffers()
  local snapshots = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      snapshots[path] = file_signature(path)
    end
  end

  return snapshots
end

local function reload_buffer_from_disk(bufnr, path)
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return false
  end

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = was_modifiable

  return true
end

local function reload_changed_file_buffers(session)
  local before_snapshots = session.file_snapshots or {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      local before = before_snapshots[path]
      local after = file_signature(path)

      if not signatures_equal(before, after) then
        reload_buffer_from_disk(bufnr, path)
      end
    end
  end
end

local function finish_session(session, status, opts)
  opts = opts or {}
  if not session or session.closing then
    return
  end

  session.closing = true
  session.status = status
  session.ended_at = vim.loop.hrtime()

  if opts.error then
    session.last_error = opts.error
    session_mod.push(session, opts.error)
    ui.update(session)
    runner.finish(session)
  elseif status == "error" then
    ui.update(session)
    runner.finish(session)
  else
    reload_changed_file_buffers(session)
    ui.close(session)
    runner.finish(session)
  end

  if active_session == session then
    active_session = nil
  end
  last_session = session

  log.append_session(config.get().log_path, session, session.last_message, status, session.source_path)
end

local function start_session(message, build_context)
  if active_session then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local session = session_mod.new(source_bufnr)
  session.file_snapshots = snapshot_loaded_file_buffers()
  session.last_message = message
  active_session = session
  last_session = session
  ui.open(session, config.get().focus_ui)
  set_status(session, "collecting_context")

  local ok, built_context = pcall(build_context)
  if not ok then
    finish_session(session, "error", { error = built_context })
    return
  end

  local payload = vim.json.encode({
    type = "prompt",
    message = message .. "\n\nContext:\n" .. built_context,
  }) .. "\n"

  set_status(session, "starting")

  local process, err = runner.start(session, get_pi_cmd(), payload, {
    on_event = function(event)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      if event.type == "thinking" then
        set_status(session, "thinking")
      elseif event.type == "tool_start" then
        session.active_tool = event.tool
        set_status(session, "running_tool")
      elseif event.type == "tool_end" then
        session.active_tool = nil
        set_status(session, "thinking")
      elseif event.type == "done" then
        session.saw_terminal_event = true
        finish_session(session, "done")
      elseif event.type == "error" then
        session.saw_terminal_event = true
        finish_session(session, "error", { error = event.message })
      end
    end,
    on_stderr = function(line)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      session_mod.push(session, line)
      ui.update(session)
    end,
    on_error = function(error_message)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      finish_session(session, "error", { error = tostring(error_message) })
    end,
    on_exit = function(result)
      if session.cancelled then
        return
      end
      if session.closing then
        return
      end
      if result.code ~= 0 and result.code ~= 143 and result.code ~= 124 then
        finish_session(session, "error", { error = "pi exited with code " .. result.code })
        return
      end
      if not session.saw_terminal_event then
        finish_session(session, "error", { error = "pi exited before completing request" })
        return
      end
      finish_session(session, "done")
    end,
  })

  if not process then
    finish_session(session, "error", { error = tostring(err) })
    return
  end

  session.process = process
end

function M.setup(opts)
  assert_supported_version()
  config.setup(opts)
end

function M.prompt_with_buffer()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAsk")
  if not bufnr then
    return
  end

  vim.ui.input({ prompt = context.format_prompt_label(bufnr, nil) }, function(input)
    if input then
      start_session(input, function()
        return context.get_buffer_context(bufnr, config.get())
      end)
    end
  end)
end

function M.prompt_with_selection()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAskSelection")
  if not bufnr then
    return
  end

  local range = context.get_visual_selection_range()
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, range) }, function(input)
    if input then
      start_session(input, function()
        return context.get_visual_context(bufnr, config.get())
      end)
    end
  end)
end

function M.cancel()
  if not active_session then
    return
  end
  active_session.cancelled = true
  runner.cancel(active_session)
  last_session = active_session
  ui.close(active_session)
  active_session = nil
end

function M.is_running()
  return active_session ~= nil
end

function M._get_active_session()
  return active_session
end

function M._get_last_session()
  return last_session
end

function M.show_log()
  local log_path = config.get().log_path
  if not log_path or log_path == "" then
    vim.notify("pi.nvim: log_path not configured", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(log_path) == 0 then
    vim.notify("pi.nvim: log file not found at " .. log_path, vim.log.levels.INFO)
    return
  end

  vim.cmd("new")
  vim.cmd("read " .. vim.fn.fnameescape(log_path))
  vim.cmd("1d")
  vim.bo.modifiable = false
  vim.bo.buftype = "nofile"
  vim.bo.filetype = "log"
  vim.cmd("normal! G")
end

function M.get_buffer_context()
  return context.get_buffer_context(vim.api.nvim_get_current_buf(), config.get())
end

function M.get_visual_context()
  return context.get_visual_context(vim.api.nvim_get_current_buf(), config.get())
end

return M
