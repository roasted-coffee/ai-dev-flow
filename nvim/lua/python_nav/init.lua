-- python_nav: structured navigation + impact analysis for Python codebases.
-- Usage: require("python_nav").setup({ root = "/path/to/project" })

local M = {}

local client = require("python_nav.client")
local ui     = require("python_nav.ui")

M.config = {
  root        = nil,
  db_path     = nil,
  server_cmd  = nil,
  indexer_cmd = nil,
}

-- State for active diff/patch session
local patch_state = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function word_at_cursor()
  return vim.fn.expand("<cword>")
end

local function rel_path()
  local abs = vim.fn.expand("%:p")
  local root = M.config.root
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return vim.fn.expand("%:.")
end

local function jump_to(file, line)
  local abs = M.config.root .. "/" .. file
  if vim.fn.expand("%:p") == vim.fn.fnamemodify(abs, ":p") then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  else
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
  vim.cmd("normal! zz")
end

-- ── Navigation commands ───────────────────────────────────────────────────────

function M.find_definition(name)
  name = name or word_at_cursor()
  if name == "" then
    vim.notify("python-nav: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  client.call("find_definition", { name = name }, function(result, err)
    if err then
      vim.notify("python-nav Def: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or #result == 0 then
      vim.notify("No definition for: " .. name, vim.log.levels.WARN)
      return
    end
    if #result == 1 then
      jump_to(result[1].file, result[1].start_line)
    else
      ui.show_list(
        "Definitions: " .. name,
        result,
        function(item) jump_to(item.file, item.start_line) end,
        function(item)
          return string.format("[%-8s] %s:%d", item.type, item.file, item.start_line)
        end
      )
    end
  end)
end

function M.get_context()
  local file = rel_path()
  local line  = vim.api.nvim_win_get_cursor(0)[1]

  client.call("get_context", { file = file, line = line }, function(result, err)
    if err then
      vim.notify("python-nav Context: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or result.error then
      vim.notify("python-nav: " .. (result and result.error or "no context"), vim.log.levels.WARN)
      return
    end
    if not result.lines or #result.lines == 0 then
      vim.notify("python-nav: empty context", vim.log.levels.WARN)
      return
    end

    local enc = result.enclosing
    local title
    if enc then
      title = string.format("%s  [%s %s]", result.file, enc.type, enc.name)
    else
      title = string.format("%s  [lines %d–%d]", result.file, result.start_line, result.end_line)
    end

    ui.show_float(title, result.lines)
  end)
end

function M.find_references(name)
  name = name or word_at_cursor()
  if name == "" then
    vim.notify("python-nav: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  client.call("find_references", { name = name, limit = 20 }, function(result, err)
    if err then
      vim.notify("python-nav Refs: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or #result == 0 then
      vim.notify("No references for: " .. name, vim.log.levels.WARN)
      return
    end

    local qf = {}
    for _, ref in ipairs(result) do
      table.insert(qf, {
        filename = M.config.root .. "/" .. ref.file,
        lnum     = ref.line,
        col      = 1,
        text     = ref.symbol_name,
      })
    end
    vim.fn.setqflist({}, "r", { title = "Refs: " .. name, items = qf })
    vim.cmd("copen")
    vim.notify(string.format("  %d refs for '%s'", #result, name), vim.log.levels.INFO)
  end)
end

function M.search(query)
  if not query or query == "" then
    vim.notify("python-nav: provide a search query", vim.log.levels.WARN)
    return
  end
  client.call("search_text", { query = query, limit = 10 }, function(result, err)
    if err then
      vim.notify("python-nav Search: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or #result == 0 then
      vim.notify("No symbols matching: " .. query, vim.log.levels.WARN)
      return
    end
    ui.show_list(
      "Search: " .. query,
      result,
      function(item) jump_to(item.file, item.start_line) end,
      function(item)
        return string.format("[%-8s] %-30s %s:%d", item.type, item.name, item.file, item.start_line)
      end
    )
  end)
end

function M.code_action(symbol)
  symbol = symbol or word_at_cursor()
  if symbol == "" then
    vim.notify("python-nav: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "refactor", "add_feature" }, {
    prompt = "Intent for '" .. symbol .. "': ",
  }, function(intent)
    if not intent then return end

    client.call("code_action", { symbol = symbol, intent = intent }, function(result, err)
      if err then
        vim.notify("python-nav CodeAction: " .. err, vim.log.levels.ERROR)
        return
      end
      if result and result.error then
        vim.notify("python-nav: " .. result.error, vim.log.levels.WARN)
        return
      end

      local lines = {}
      local function push(s) table.insert(lines, s or "") end

      push(string.format("Symbol : %s  [%s]", result.symbol, result.type or "?"))
      push("")
      if result.defined_at then
        push(string.format("Defined: %s:%d", result.defined_at.file, result.defined_at.line))
      end
      if result.reference_count then
        push(string.format("Refs   : %d across %d files",
          result.reference_count, result.affected_files and #result.affected_files or 0))
      end
      push("")
      push("Plan:")
      if result.plan then
        for _, step in ipairs(result.plan) do push("  " .. step) end
      end
      if result.affected_files and #result.affected_files > 0 then
        push("")
        push("Affected files:")
        for _, f in ipairs(result.affected_files) do push("  " .. f) end
      end
      if result.call_sites and #result.call_sites > 0 then
        push("")
        push("Call sites (first 10):")
        for _, cs in ipairs(result.call_sites) do
          push(string.format("  %s:%d", cs.file, cs.line))
        end
      end
      if result.insertion_point then
        push("")
        push(string.format("Insert after: %s:%d",
          result.insertion_point.file, result.insertion_point.after_line))
      end

      ui.show_float("CodeAction [" .. intent .. "]  " .. symbol, lines)
    end)
  end)
end

-- ── New: Analyze ─────────────────────────────────────────────────────────────

function M.analyze(symbol)
  symbol = symbol or word_at_cursor()
  if symbol == "" then
    vim.notify("python-nav: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  client.call("analyze_usages", { symbol = symbol }, function(result, err)
    if err then
      vim.notify("python-nav Analyze: " .. err, vim.log.levels.ERROR)
      return
    end
    if result and result.error then
      vim.notify("python-nav: " .. result.error, vim.log.levels.WARN)
      return
    end

    local lines = {}
    local function push(s) table.insert(lines, s or "") end

    push(string.format("Symbol : %s", result.symbol))
    if result.defined_in then
      push(string.format("Defined: %s:%d", result.defined_in.file, result.defined_in.start_line))
    end
    push(string.format("Total  : %d references", result.total_refs or 0))

    if result.patterns then
      push("")
      push("Usage patterns:")
      for _, pat in ipairs({ "assignment", "destructuring", "chained", "ignored" }) do
        local n = result.patterns[pat] or 0
        if n > 0 then
          push(string.format("  %-15s %d", pat, n))
        end
      end
    end

    local function section(title, refs)
      if not refs or #refs == 0 then return end
      push("")
      push(title .. " (" .. #refs .. "):")
      for _, r in ipairs(refs) do
        local entry = string.format("  %s:%d", r.file, r.line)
        if r.content then entry = entry .. "  " .. r.content end
        push(entry)
      end
    end

    section("Same file",   result.same_file)
    section("Same module", result.same_module)
    section("External",    result.external)

    ui.show_float("Analyze: " .. symbol, lines)
  end)
end

-- ── New: Patch ────────────────────────────────────────────────────────────────

function M.patch(symbol)
  symbol = symbol or word_at_cursor()
  if symbol == "" then
    vim.notify("python-nav: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "add_field", "remove_field", "rename", "refactor_logic" }, {
    prompt = "Patch intent for '" .. symbol .. "': ",
  }, function(intent)
    if not intent then return end

    client.call("generate_patch", { symbol = symbol, intent = intent }, function(result, err)
      if err then
        vim.notify("python-nav Patch: " .. err, vim.log.levels.ERROR)
        return
      end
      if result and result.error then
        vim.notify("python-nav: " .. result.error, vim.log.levels.WARN)
        return
      end

      local src = result.source_lines or {}
      if #src == 0 then
        vim.notify("python-nav: empty source block for " .. symbol, vim.log.levels.WARN)
        return
      end

      -- Left (read-only original)
      local left_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, src)
      vim.bo[left_buf].filetype   = "python"
      vim.bo[left_buf].modifiable = false
      vim.bo[left_buf].bufhidden  = "wipe"

      -- Right (editable proposed)
      local right_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, src)
      vim.bo[right_buf].filetype  = "python"
      vim.bo[right_buf].bufhidden = "wipe"

      -- Replace current window with left buf, open right in vsplit
      local left_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_win, left_buf)
      vim.cmd("diffthis")

      vim.cmd("vsplit")
      local right_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(right_win, right_buf)
      vim.cmd("diffthis")

      patch_state = {
        file       = result.file,
        start_line = result.start_line,
        end_line   = result.end_line,
        right_buf  = right_buf,
        left_buf   = left_buf,
        left_win   = left_win,
        right_win  = right_win,
      }

      vim.notify(
        string.format("[%s] %s  %s:%d-%d — edit right pane, :ApplyPatch to apply",
          intent, symbol, result.file, result.start_line, result.end_line),
        vim.log.levels.INFO
      )
    end)
  end)
end

-- ── New: ApplyPatch ───────────────────────────────────────────────────────────

function M.apply_patch()
  if not patch_state then
    vim.notify("python-nav: no pending patch — run :Patch first", vim.log.levels.WARN)
    return
  end

  local ps = patch_state

  -- Confirm before writing
  local choice = vim.fn.confirm(
    string.format("Apply patch to %s lines %d–%d?", ps.file, ps.start_line, ps.end_line),
    "&Yes\n&No", 2
  )
  if choice ~= 1 then return end

  -- Read modified lines from right buffer before closing windows
  local new_lines = vim.api.nvim_buf_get_lines(ps.right_buf, 0, -1, false)

  -- Close diff windows
  if vim.api.nvim_win_is_valid(ps.right_win) then
    pcall(vim.api.nvim_win_close, ps.right_win, true)
  end
  if vim.api.nvim_win_is_valid(ps.left_win) then
    pcall(vim.api.nvim_win_close, ps.left_win, true)
  end

  -- Open real file and replace the symbol's line range
  local abs_path = M.config.root .. "/" .. ps.file
  vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  -- nvim_buf_set_lines: end is exclusive
  vim.api.nvim_buf_set_lines(0, ps.start_line - 1, ps.end_line, false, new_lines)

  patch_state = nil
  vim.notify(string.format("python-nav: patch applied to %s — save with :w", ps.file), vim.log.levels.INFO)
end

-- ── Reindex ───────────────────────────────────────────────────────────────────

function M.reindex()
  local root    = M.config.root
  local db_path = M.config.db_path

  local cmd = M.config.indexer_cmd
  if not cmd then
    local this_file  = debug.getinfo(1, "S").source:sub(2)
    local plugin_dir = vim.fn.fnamemodify(this_file, ":p:h:h:h:h")
    local py_script  = plugin_dir .. "/indexer/indexer.py"
    if vim.fn.filereadable(py_script) == 1 then
      cmd = { "python3", py_script }
    else
      vim.notify("python-nav: indexer not found at " .. py_script, vim.log.levels.ERROR)
      return
    end
  end

  local args = vim.list_extend(vim.deepcopy(cmd), { root, "--db", db_path })
  vim.notify("python-nav: indexing " .. root .. " …", vim.log.levels.INFO)

  vim.fn.jobstart(args, {
    on_exit = function(_, code, _)
      if code == 0 then
        vim.schedule(function()
          vim.notify("python-nav: indexing complete", vim.log.levels.INFO)
          client.stop()
          client.start(M.config)
        end)
      else
        vim.schedule(function()
          vim.notify("python-nav: indexer exited with code " .. code, vim.log.levels.ERROR)
        end)
      end
    end,
    on_stdout = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function() vim.notify(line, vim.log.levels.DEBUG) end)
        end
      end
    end,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  if not M.config.root then M.config.root = vim.fn.getcwd() end
  M.config.root = vim.fn.fnamemodify(M.config.root, ":p"):gsub("/$", "")

  if not M.config.db_path then
    M.config.db_path = M.config.root .. "/.nav.db"
  end

  client.start(M.config)

  local cmd = vim.api.nvim_create_user_command
  cmd("Def",        function(a) M.find_definition(a.args ~= "" and a.args or nil) end, { nargs = "?" })
  cmd("Context",    function(_) M.get_context() end,                                    { nargs = 0  })
  cmd("Refs",       function(a) M.find_references(a.args ~= "" and a.args or nil) end,  { nargs = "?" })
  cmd("Search",     function(a) M.search(a.args) end,                                   { nargs = 1  })
  cmd("CodeAction", function(a) M.code_action(a.args ~= "" and a.args or nil) end,      { nargs = "?" })
  cmd("Analyze",    function(a) M.analyze(a.args ~= "" and a.args or nil) end,          { nargs = "?" })
  cmd("Patch",      function(a) M.patch(a.args ~= "" and a.args or nil) end,            { nargs = "?" })
  cmd("ApplyPatch", function(_) M.apply_patch() end,                                    { nargs = 0  })
  cmd("NavIndex",   function(_) M.reindex() end,                                        { nargs = 0  })
  cmd("NavStop",    function(_) client.stop() end,                                      { nargs = 0  })

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
  end
  map("gd", function() M.find_definition() end, "python-nav: go to definition")
  map("gr", function() M.find_references() end, "python-nav: find references")
  map("K",  function() M.get_context()     end, "python-nav: show context")
end

return M
