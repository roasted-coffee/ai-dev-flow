-- Floating window and list UI helpers. No external dependencies.

local M = {}

local function win_dims(min_w, content_lines)
  local max_w = math.floor(vim.o.columns * 0.82)
  local max_h = math.floor(vim.o.lines   * 0.65)
  local w = math.min(max_w, math.max(min_w, 60))
  local h = math.min(max_h, math.max(1, #content_lines))
  local row = math.floor((vim.o.lines   - h) / 2)
  local col = math.floor((vim.o.columns - w) / 2)
  return w, h, row, col
end

-- Show read-only floating window with `lines` of text.
function M.show_float(title, lines)
  local w, h, row, col = win_dims(#title + 4, lines)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    width      = w,
    height     = h,
    row        = row,
    col        = col,
    style      = "minimal",
    border     = "rounded",
    title      = " " .. title .. " ",
    title_pos  = "center",
  })

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = true

  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  local o = { buffer = buf, nowait = true, noremap = true, silent = true }
  vim.keymap.set("n", "q",     close, o)
  vim.keymap.set("n", "<Esc>", close, o)

  return win, buf
end

-- Show a selectable list in a float. Press <CR> to pick, q/<Esc> to dismiss.
-- `items`       – raw items
-- `on_select`   – fn(item)
-- `format_item` – fn(item) -> string
function M.show_list(title, items, on_select, format_item)
  format_item = format_item or tostring

  local display = {}
  for _, item in ipairs(items) do
    table.insert(display, format_item(item))
  end

  local w, h, row, col = win_dims(#title + 4, display)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    width      = w,
    height     = h,
    row        = row,
    col        = col,
    style      = "minimal",
    border     = "rounded",
    title      = " " .. title .. " ",
    title_pos  = "center",
  })

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = true

  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  local o = { buffer = buf, nowait = true, noremap = true, silent = true }

  vim.keymap.set("n", "<CR>", function()
    local idx = vim.api.nvim_win_get_cursor(win)[1]
    close()
    if items[idx] then on_select(items[idx]) end
  end, o)
  vim.keymap.set("n", "q",     close, o)
  vim.keymap.set("n", "<Esc>", close, o)

  return win, buf
end

return M
