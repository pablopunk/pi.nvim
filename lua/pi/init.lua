local M = {}

M.config = {
  provider = nil,
  model = nil,
}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local SYSTEM_PROMPT =
  [[You are running inside the pi.nvim Neovim plugin. The user has sent a request and will not be able to reply back. You must complete the task immediately without asking any questions or requesting clarification. Take action now and do what was asked.]]

local EMPTY_FILE_NOTE =
  [[NOTE: This file is currently empty. Please create or populate it directly by applying the necessary edits so pi.nvim can write the file.]]

local state = {
  job = nil,
  buf = nil,
  win = nil,
  spinner_idx = 1,
  spinner_timer = nil,
  ns_id = nil,
  extmark_id = nil,
}

local function buffer_is_file_backed(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return filename ~= nil and filename ~= ""
end

local function buffer_is_empty(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("%S") then
      return false
    end
  end
  return true
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not buffer_is_file_backed(bufnr) then
    local err = string.format("%s requires a file", command_name)
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function get_visual_selection_range()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if not start_pos or not end_pos then
    return nil
  end
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  return { start = start_line, ["end"] = end_line }
end

local function format_prompt_label(bufnr, selection_range)
  local components = {}
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename and filename ~= "" then
    local short = vim.fn.fnamemodify(filename, ":t")
    table.insert(components, short)
  end
  if selection_range and selection_range.start and selection_range["end"] then
    table.insert(components, string.format("%d:%d", selection_range.start, selection_range["end"]))
  end

  local label
  if #components > 0 then
    label = string.format("ask pi (%s)", table.concat(components, ":"))
  else
    label = "ask pi"
  end

  return label .. ": "
end

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  state.ns_id = vim.api.nvim_create_namespace("pi_nvim")
end

local function get_pi_cmd()
  local cmd = { "pi", "--mode", "rpc", "--no-session" }
  if M.config.provider then
    table.insert(cmd, "--provider")
    table.insert(cmd, M.config.provider)
  end
  if M.config.model then
    table.insert(cmd, "--model")
    table.insert(cmd, M.config.model)
  end
  return cmd
end

local function create_output_window()
  local max_width = math.floor(vim.o.columns * 0.8)
  local max_height = math.floor(vim.o.lines * 0.8)
  local width = math.min(40, max_width)
  local height = math.min(1, max_height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_name(buf, "pi-response://" .. buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  return buf, win
end

local function close_window()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
end

local function update_spinner(status_text)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local spinner_char = spinner[state.spinner_idx % #spinner + 1]
  state.spinner_idx = state.spinner_idx + 1

  local virt_text = { { spinner_char .. " " .. status_text, "Comment" } }

  if state.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, state.ns_id, state.extmark_id)
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(state.buf, state.ns_id, 0, 0, {
    virt_text = virt_text,
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

local function start_spinner(status_text)
  local function tick()
    if not state.spinner_timer then
      return
    end
    update_spinner(status_text)
    state.spinner_timer = vim.defer_fn(tick, 200)
  end
  tick()
end

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
  if state.extmark_id and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, state.ns_id, state.extmark_id)
    state.extmark_id = nil
  end
end

local function cleanup()
  stop_spinner()
  if state.job then
    vim.fn.jobstop(state.job)
    state.job = nil
  end
  close_window()
end

local function handle_event(data)
  local ok, event = pcall(vim.json.decode, data)
  if not ok or not event then
    return
  end

  -- Ignore events if cleanup has already occurred
  if not state.job then
    return
  end

  local event_type = event.type

  if event_type == "message_update" then
    local delta = event.assistantMessageEvent
    if delta then
      if delta.type == "thinking_delta" then
        update_spinner("Thinking...")
      elseif delta.type == "error" then
        stop_spinner()
        cleanup()
        local reason = delta.reason or "unknown"
        vim.notify("pi error: " .. reason, vim.log.levels.ERROR)
      end
    end
  elseif event_type == "tool_execution_start" then
    update_spinner("Running tool: " .. (event.toolName or "unknown"))
  elseif event_type == "tool_execution_end" then
    update_spinner("Thinking...")
  elseif event_type == "agent_end" then
    stop_spinner()
    cleanup()
    vim.cmd("edit!")
    vim.notify("pi finished", vim.log.levels.INFO)
  elseif event_type == "response" then
    if not event.success then
      stop_spinner()
      cleanup()
      vim.notify("pi error: " .. (event.error or "unknown"), vim.log.levels.ERROR)
    end
  end
end

function M.send(message, context)
  if state.job then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local full_prompt = message
  if context and context ~= "" then
    full_prompt = full_prompt .. "\n\nContext:\n" .. context
  end

  state.spinner_idx = 1
  state.buf, state.win = create_output_window()
  start_spinner("Thinking...")

  local cmd = get_pi_cmd()

  state.job = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              handle_event(line)
            end)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              vim.notify("pi stderr: " .. line, vim.log.levels.ERROR)
            end)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        stop_spinner()
        -- 143 = SIGTERM (128 + 15), normal termination from jobstop()
        if exit_code ~= 0 and exit_code ~= 143 then
          vim.notify("pi exited with code " .. exit_code, vim.log.levels.ERROR)
        end
        state.job = nil
      end)
    end,
  })

  if state.job <= 0 then
    vim.notify("Failed to start pi", vim.log.levels.ERROR)
    cleanup()
    return
  end

  local prompt_cmd = vim.json.encode({
    type = "prompt",
    message = full_prompt,
  })
  vim.fn.chansend(state.job, prompt_cmd .. "\n")
  vim.fn.chanclose(state.job, "stdin")
end

function M.get_buffer_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local has_filename = filename and filename ~= ""

  local context = SYSTEM_PROMPT .. "\n\n"
  if has_filename then
    context = context .. string.format("File: %s\n```\n%s\n```", filename, content)
  else
    context = context .. string.format("```\n%s\n```", content)
  end

  if has_filename and buffer_is_empty(bufnr) then
    context = context .. "\n\n" .. EMPTY_FILE_NOTE
  end

  return context
end

function M.get_visual_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local has_filename = filename and filename ~= ""

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_content = table.concat(all_lines, "\n")

  local selection_range = get_visual_selection_range()
  local start_line = selection_range and selection_range.start or 1
  local end_line = selection_range and selection_range["end"] or #all_lines

  local selected_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local selection_content = table.concat(selected_lines, "\n")

  local context = SYSTEM_PROMPT .. "\n\n"
  if has_filename then
    context = context
      .. string.format(
        "File: %s\n\nFull file content:\n```\n%s\n```\n\nSelected lines %d-%d:\n```\n%s\n```",
        filename,
        all_content,
        start_line,
        end_line,
        selection_content
      )
  else
    context = context
      .. string.format(
        "Full file content:\n```\n%s\n```\n\nSelected lines %d-%d:\n```\n%s\n```",
        all_content,
        start_line,
        end_line,
        selection_content
      )
  end

  if has_filename and buffer_is_empty(bufnr) then
    context = context .. "\n\n" .. EMPTY_FILE_NOTE
  end

  return context
end

function M.prompt_with_buffer()
  if state.job then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  local bufnr = ensure_file_backed_buffer("PiAsk")
  if not bufnr then
    return
  end

  local prompt_label = format_prompt_label(bufnr, nil)

  vim.ui.input({ prompt = prompt_label }, function(input)
    if input then
      local context = M.get_buffer_context()
      M.send(input, context)
    end
  end)
end

function M.prompt_with_selection()
  if state.job then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  local bufnr = ensure_file_backed_buffer("PiAskSelection")
  if not bufnr then
    return
  end

  local selection_range = get_visual_selection_range()
  local prompt_label = format_prompt_label(bufnr, selection_range)

  vim.ui.input({ prompt = prompt_label }, function(input)
    if input then
      local context = M.get_visual_context()
      M.send(input, context)
    end
  end)
end

return M
