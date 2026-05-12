--- Context builders for pi.nvim prompts.
local M = {}

local SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin. The user has sent a request and will not be able to reply back. You must complete the task immediately without asking any questions or requesting clarification. Take action now and do what was asked.

IMPORTANT: Any file content included in the provided Context comes from the user's current Neovim buffer and may be newer than the on-disk file. Treat the provided Context as the source of truth for that file content. Do not read the same file just to verify its contents before editing, because the filesystem copy may be stale if the user has unsaved changes. Base edits on the provided buffer/selection content whenever possible.]]

local BUFFER_SOURCE_OF_TRUTH_NOTE = [[NOTE: The context below comes from the current Neovim buffer and may include unsaved changes that are newer than the on-disk file. Treat this context as the source of truth for the file content, and do not read the same file only to confirm its current contents before editing.]]

local EMPTY_FILE_NOTE = [[NOTE: This file is currently empty. Please create or populate it directly by applying the necessary edits so pi.nvim can write the file.]]

--- Returns whether a buffer contains only empty or whitespace-only lines.
--- @param bufnr integer Buffer handle.
--- @return boolean is_empty Whether the buffer has meaningful content.
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

--- Returns whether a buffer maps to a real file on disk.
--- @param bufnr integer Buffer handle.
--- @return boolean is_file_backed Whether the buffer is file-backed.
function M.buffer_is_file_backed(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return filename ~= nil and filename ~= ""
end

--- Returns the current visual selection as a 1-based inclusive line range.
--- @return table|nil range Selection range with `start` and `end` keys.
function M.get_visual_selection_range()
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

--- Builds the prompt label shown in `vim.ui.input`.
--- @param bufnr integer Buffer handle.
--- @param selection_range table|nil Optional selected line range.
--- @return string label Input prompt label.
function M.format_prompt_label(bufnr, selection_range)
  local components = {}
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename ~= "" then
    table.insert(components, vim.fn.fnamemodify(filename, ":t"))
  end
  if selection_range and selection_range.start and selection_range["end"] then
    table.insert(components, string.format("%d:%d", selection_range.start, selection_range["end"]))
  end
  if #components == 0 then
    return "ask pi: "
  end
  return string.format("ask pi (%s): ", table.concat(components, ":"))
end

--- Returns a buffer's filetype, defaulting to plain text.
--- @param bufnr integer Buffer handle.
--- @return string filetype Buffer filetype or `text`.
local function filetype_for(bufnr)
  return vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "text"
end

--- Extracts nearby lines around a 1-based center line.
--- @param lines string[] All buffer lines.
--- @param center_line integer 1-based center line.
--- @param surrounding_lines integer Number of surrounding lines to include on each side.
--- @return string[] slice Selected lines.
--- @return integer start_line First included line number.
--- @return integer end_line Last included line number.
local function slice_lines_around(lines, center_line, surrounding_lines)
  local start_line = math.max(1, center_line - surrounding_lines)
  local end_line = math.min(#lines, center_line + surrounding_lines)
  return vim.list_slice(lines, start_line, end_line), start_line, end_line
end

--- Truncates text to a byte limit.
--- @param text string Text to trim.
--- @param max_bytes integer Maximum byte length.
--- @return string content Trimmed or original text.
--- @return boolean did_trim Whether truncation happened.
local function truncate_to_bytes(text, max_bytes)
  if #text <= max_bytes then
    return text, false
  end
  return text:sub(1, max_bytes), true
end

--- Wraps text inside a labeled fenced code block.
--- @param label string Section label.
--- @param text string Section content.
--- @return string block Formatted block.
local function content_block(label, text)
  return string.format("%s:\n```\n%s\n```", label, text)
end

--- Converts a diagnostic severity enum into a stable uppercase label.
--- @param severity integer|nil Diagnostic severity.
--- @return string label Severity label.
local function diagnostic_severity_label(severity)
  local labels = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARN",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
  }
  return labels[severity] or "UNKNOWN"
end

--- Returns whether a diagnostic overlaps an inclusive line range.
--- @param diagnostic table Diagnostic item from `vim.diagnostic.get`.
--- @param start_line integer Inclusive start line.
--- @param end_line integer Inclusive end line.
--- @return boolean overlaps Whether the diagnostic intersects the range.
local function diagnostic_overlaps_range(diagnostic, start_line, end_line)
  local diagnostic_start = (diagnostic.lnum or 0) + 1
  local diagnostic_end = (diagnostic.end_lnum or diagnostic.lnum or 0) + 1
  return diagnostic_start <= end_line and diagnostic_end >= start_line
end

--- Formats a diagnostic as a human-readable bullet list item.
--- @param diagnostic table Diagnostic item from `vim.diagnostic.get`.
--- @return string line Rendered diagnostic line.
local function format_diagnostic(diagnostic)
  local line = (diagnostic.lnum or 0) + 1
  local col = (diagnostic.col or 0) + 1
  local details = { diagnostic_severity_label(diagnostic.severity) }

  if diagnostic.source and diagnostic.source ~= "" then
    details[#details + 1] = diagnostic.source
  end

  return string.format("- line %d:%d: %s [%s]", line, col, diagnostic.message, table.concat(details, ", "))
end

--- Builds an optional diagnostics block for the current buffer or selection.
--- @param bufnr integer Buffer handle.
--- @param config table Active pi.nvim configuration.
--- @param opts? table Optional range filter.
--- @return string|nil block Formatted diagnostics block.
--- @return string|nil note Optional trimming note.
local function diagnostics_block(bufnr, config, opts)
  if not config.context.diagnostics or not config.context.diagnostics.enabled then
    return nil
  end

  opts = opts or {}
  local diagnostics = vim.diagnostic.get(bufnr)
  if not diagnostics or vim.tbl_isempty(diagnostics) then
    return nil
  end

  if opts.range then
    diagnostics = vim.tbl_filter(function(diagnostic)
      return diagnostic_overlaps_range(diagnostic, opts.range.start, opts.range["end"])
    end, diagnostics)
    if vim.tbl_isempty(diagnostics) then
      return nil
    end
  end

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return (a.col or 0) < (b.col or 0)
  end)

  local formatted = {}
  for _, diagnostic in ipairs(diagnostics) do
    formatted[#formatted + 1] = format_diagnostic(diagnostic)
  end

  local content, did_trim_bytes = truncate_to_bytes(table.concat(formatted, "\n"), config.context.max_bytes)
  local label = opts.range and "Diagnostics in selection" or "Diagnostics"
  local note = nil

  if did_trim_bytes then
    note = string.format("NOTE: Diagnostics were trimmed for speed (max_bytes=%d).", config.context.max_bytes)
  end

  return content_block(label, content), note
end

--- Returns the system prompt appended to pi invocations.
--- @return string prompt Internal system prompt.
function M.get_system_prompt()
  return SYSTEM_PROMPT
end

--- Builds prompt context for `:PiAsk` around the current cursor line.
--- @param bufnr integer Buffer handle.
--- @param config table Active pi.nvim configuration.
--- @return string context Prompt context payload.
function M.get_buffer_context(bufnr, config)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local surrounding_lines = config.context.ask.surrounding_lines
  local nearby_lines, start_line, end_line = slice_lines_around(lines, cursor_line, surrounding_lines)
  local content, did_trim_bytes = truncate_to_bytes(table.concat(nearby_lines, "\n"), config.context.max_bytes)
  local filename = vim.api.nvim_buf_get_name(bufnr)

  local parts = {
    string.format("File: %s", filename),
    string.format("Cwd: %s", vim.fn.getcwd()),
    string.format("Filetype: %s", filetype_for(bufnr)),
    string.format("Current line: %d", cursor_line),
    BUFFER_SOURCE_OF_TRUTH_NOTE,
    content_block(string.format("Nearby context (%d-%d)", start_line, end_line), content),
  }

  if did_trim_bytes then
    parts[#parts + 1] = string.format(
      "NOTE: Context was trimmed for speed (max_bytes=%d).",
      config.context.max_bytes
    )
  end

  local diagnostics, diagnostics_note = diagnostics_block(bufnr, config)
  if diagnostics then
    parts[#parts + 1] = diagnostics
  end
  if diagnostics_note then
    parts[#parts + 1] = diagnostics_note
  end

  if buffer_is_empty(bufnr) then
    parts[#parts + 1] = EMPTY_FILE_NOTE
  end

  return table.concat(parts, "\n\n")
end

--- Builds prompt context for `:PiAskSelection`.
--- @param bufnr integer Buffer handle.
--- @param config table Active pi.nvim configuration.
--- @return string context Prompt context payload.
function M.get_visual_context(bufnr, config)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local selection_range = M.get_visual_selection_range() or { start = 1, ["end"] = #all_lines }
  local surrounding_lines = config.context.selection.surrounding_lines
  local before = math.max(1, selection_range.start - surrounding_lines)
  local after = math.min(#all_lines, selection_range["end"] + surrounding_lines)

  local nearby_lines = vim.api.nvim_buf_get_lines(bufnr, before - 1, after, false)
  local selected_lines = vim.api.nvim_buf_get_lines(bufnr, selection_range.start - 1, selection_range["end"], false)
  local nearby_text, nearby_trimmed = truncate_to_bytes(table.concat(nearby_lines, "\n"), config.context.max_bytes)
  local selected_text, selected_trimmed = truncate_to_bytes(table.concat(selected_lines, "\n"), config.context.max_bytes)

  local parts = {
    string.format("File: %s", filename),
    string.format("Cwd: %s", vim.fn.getcwd()),
    string.format("Filetype: %s", filetype_for(bufnr)),
    string.format("Selected lines: %d-%d", selection_range.start, selection_range["end"]),
    BUFFER_SOURCE_OF_TRUTH_NOTE,
    content_block("Selected content", selected_text),
    content_block(string.format("Nearby context (%d-%d)", before, after), nearby_text),
  }

  if nearby_trimmed or selected_trimmed then
    parts[#parts + 1] = string.format(
      "NOTE: Selection context was trimmed for speed (max_bytes=%d).",
      config.context.max_bytes
    )
  end

  local diagnostics, diagnostics_note = diagnostics_block(bufnr, config, { range = selection_range })
  if diagnostics then
    parts[#parts + 1] = diagnostics
  end
  if diagnostics_note then
    parts[#parts + 1] = diagnostics_note
  end

  if buffer_is_empty(bufnr) then
    parts[#parts + 1] = EMPTY_FILE_NOTE
  end

  return table.concat(parts, "\n\n")
end

return M
