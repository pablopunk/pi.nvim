local M = {}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local active_statuses = {
  collecting_context = true,
  starting = true,
  thinking = true,
  running_tool = true,
  applying = true,
}

local function has_rich_notify()
  if _G.__pi_force_notify_backend then
    return true
  end

  if package.loaded.notify ~= nil or pcall(require, "notify") then
    return true
  end

  local mini_notify = rawget(_G, "MiniNotify")
  return type(mini_notify) == "table" and type(mini_notify.add) == "function"
end

local function is_session_window_valid(session)
  return session and session.winnr and vim.api.nvim_win_is_valid(session.winnr)
end

local function is_session_buffer_valid(session)
  return session and session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr)
end

local function title_for(session)
  if session.status == "error" then
    return session.ui_backend == "notify" and "pi error" or " pi error "
  end
  return session.ui_backend == "notify" and "pi" or " pi "
end

local function status_line(session)
  local prefix = ""
  if session.ui_backend == "float" and active_statuses[session.status] then
    session.spinner_idx = ((session.spinner_idx or 0) % #spinner) + 1
    prefix = spinner[session.spinner_idx] .. " "
  end

  if session.status == "running_tool" and session.active_tool then
    return prefix .. (session.ui_backend == "notify" and "Pi calling tool: " or "Running tool: ") .. session.active_tool
  end

  local notify_labels = {
    collecting_context = "Pi collecting context...",
    starting = "Pi starting...",
    thinking = "Pi thinking...",
    running_tool = "Pi calling tool...",
    applying = "Pi applying edits...",
    done = "Pi done",
    error = session.last_error or "pi failed",
    cancelled = "Pi cancelled",
  }

  local float_labels = {
    idle = "Idle",
    collecting_context = "Collecting context...",
    starting = "Starting pi...",
    thinking = "Thinking...",
    running_tool = "Running tool...",
    applying = "Applying edits...",
    done = "Done",
    error = session.last_error or "pi failed",
    cancelled = "Cancelled",
  }

  local labels = session.ui_backend == "notify" and notify_labels or float_labels
  local message = labels[session.status]
  if not message then
    return nil
  end
  return prefix .. message
end

local function notification_level(session)
  if session.status == "error" then
    return vim.log.levels.ERROR
  end
  if session.status == "cancelled" then
    return vim.log.levels.WARN
  end
  return vim.log.levels.INFO
end

local function render_notify(session)
  local message = status_line(session)
  if not message then
    return
  end

  local signature = session.status .. "|" .. (session.active_tool or "") .. "|" .. (session.last_error or "")
  if session.last_notified_signature == signature then
    return
  end
  session.last_notified_signature = signature

  vim.notify(message, notification_level(session), {
    title = title_for(session),
  })
end

local function render_float(session)
  if not is_session_buffer_valid(session) then
    return
  end

  local lines = { status_line(session) }
  local start_idx = math.max(1, #session.history - 3)
  for i = start_idx, #session.history do
    lines[#lines + 1] = session.history[i]
  end

  vim.bo[session.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
  vim.bo[session.bufnr].modifiable = false

  if is_session_window_valid(session) then
    pcall(vim.api.nvim_win_set_config, session.winnr, vim.tbl_extend("force", vim.api.nvim_win_get_config(session.winnr), {
      title = title_for(session),
      height = math.min(math.max(#lines, 1), math.max(3, math.floor(vim.o.lines * 0.25))),
    }))
  end
end

local function render(session)
  if session.ui_backend == "notify" then
    render_notify(session)
  else
    render_float(session)
  end
end

local function stop_timer(session)
  if session.ui_timer then
    session.ui_timer:stop()
    session.ui_timer:close()
    session.ui_timer = nil
  end
end

local function ensure_timer(session)
  if session.ui_backend ~= "float" or session.ui_timer or not active_statuses[session.status] then
    return
  end

  session.ui_timer = vim.loop.new_timer()
  session.ui_timer:start(100, 100, vim.schedule_wrap(function()
    if not is_session_buffer_valid(session) or not active_statuses[session.status] then
      stop_timer(session)
      return
    end
    render(session)
  end))
end

local function open_float(session, focus)
  local width = math.min(60, math.max(40, math.floor(vim.o.columns * 0.45)))
  local height = 4
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  session.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[session.bufnr].buftype = "nofile"
  vim.bo[session.bufnr].bufhidden = "wipe"
  vim.bo[session.bufnr].swapfile = false
  vim.bo[session.bufnr].modifiable = false
  vim.api.nvim_buf_set_name(session.bufnr, "pi-session://" .. session.id)

  session.winnr = vim.api.nvim_open_win(session.bufnr, focus, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title_for(session),
    title_pos = "center",
    noautocmd = true,
  })

  vim.wo[session.winnr].wrap = true
  vim.wo[session.winnr].linebreak = true
  vim.wo[session.winnr].winfixbuf = true
end

function M.open(session, focus)
  session.ui_backend = has_rich_notify() and "notify" or "float"

  if session.ui_backend == "float" then
    open_float(session, focus)
  else
    session.winnr = nil
    session.bufnr = nil
  end

  render(session)
  ensure_timer(session)
end

function M.update(session)
  if active_statuses[session.status] then
    ensure_timer(session)
  else
    stop_timer(session)
  end
  render(session)
end

function M.close(session)
  stop_timer(session)

  if session.ui_backend == "float" then
    if is_session_window_valid(session) then
      pcall(vim.api.nvim_win_close, session.winnr, true)
    end
    if is_session_buffer_valid(session) then
      pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
    end
    session.winnr = nil
    session.bufnr = nil
    return
  end

  session.winnr = nil
  session.bufnr = nil

  if session.cancelled then
    session.status = "cancelled"
    render(session)
    return
  end

  if session.status ~= "error" then
    session.status = "done"
    render(session)
  end
end

return M
