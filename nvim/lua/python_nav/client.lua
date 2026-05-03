-- JSON-RPC / MCP client over stdio.
-- Spawns the MCP server as a child process and communicates via newline-delimited JSON.

local M = {}

local job_id = nil
local req_id = 0
local pending = {}     -- id -> callback(result, err)
local partial = ""     -- incomplete line buffer
local initialized = false
local init_queue = {}  -- calls queued before initialize completes

local function next_id()
  req_id = req_id + 1
  return req_id
end

local function process_message(msg)
  if not msg.id then return end  -- notification, ignore
  local cb = pending[msg.id]
  if not cb then return end
  pending[msg.id] = nil

  if msg.error then
    cb(nil, msg.error.message or "rpc error")
    return
  end

  if msg.result then
    local content = msg.result.content
    if content and content[1] then
      local text = content[1].text
      if msg.result.isError then
        cb(nil, text)
        return
      end
      local ok, parsed = pcall(vim.json.decode, text)
      cb(ok and parsed or text, nil)
    else
      cb(msg.result, nil)
    end
  end
end

local function on_stdout(_, data, _)
  -- data is a list of chunks; first continues partial from previous call
  data[1] = partial .. (data[1] or "")
  partial  = data[#data] or ""

  -- Everything except the last element is a complete line
  for i = 1, #data - 1 do
    local line = data[i]
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == "table" then
        vim.schedule(function() process_message(msg) end)
      end
    end
  end
end

local function on_exit(_, code, _)
  job_id      = nil
  initialized = false
  _db         = nil
  vim.schedule(function()
    vim.notify(string.format("python-nav: server exited (code %d)", code), vim.log.levels.WARN)
  end)
end

local function raw_send(msg)
  if not job_id then
    vim.notify("python-nav: server not running", vim.log.levels.ERROR)
    return
  end
  vim.fn.chansend(job_id, vim.json.encode(msg) .. "\n")
end

local function do_call(tool, args, callback)
  local id = next_id()
  pending[id] = callback
  raw_send({
    jsonrpc = "2.0",
    id      = id,
    method  = "tools/call",
    params  = { name = tool, arguments = args },
  })
end

local function do_initialize()
  local id = next_id()
  pending[id] = function(_, err)
    if err then
      vim.schedule(function()
        vim.notify("python-nav: init error: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end
    -- Confirm initialized
    raw_send({ jsonrpc = "2.0", method = "notifications/initialized", params = {} })
    initialized = true
    -- Drain queue
    local q = init_queue
    init_queue = {}
    for _, fn in ipairs(q) do fn() end
  end
  raw_send({
    jsonrpc = "2.0",
    id      = id,
    method  = "initialize",
    params  = {
      protocolVersion = "2024-11-05",
      capabilities    = {},
      clientInfo      = { name = "nvim-python-nav", version = "1.0" },
    },
  })
end

-- ── Public API ─────────────────────────────────────────────────────────────────

function M.start(config)
  if job_id then return end

  local cmd = config.server_cmd
  if not cmd then
    -- Resolve relative to this file: ../../server/dist/index.js
    local this_file = debug.getinfo(1, "S").source:sub(2)
    local plugin_dir = vim.fn.fnamemodify(this_file, ":p:h:h:h:h")
    local server_js  = plugin_dir .. "/server/dist/index.js"
    if vim.fn.filereadable(server_js) == 1 then
      cmd = { "node", server_js }
    else
      vim.notify(
        "python-nav: server not built.\nRun: cd " .. plugin_dir .. "/server && npm install && npm run build",
        vim.log.levels.ERROR
      )
      return
    end
  end

  local env = {
    NAV_DB   = config.db_path or (config.root .. "/.nav.db"),
    NAV_ROOT = config.root or vim.fn.getcwd(),
  }

  job_id = vim.fn.jobstart(cmd, {
    env          = env,
    on_stdout    = on_stdout,
    on_stderr    = function() end,  -- silence; server logs go to stderr
    on_exit      = on_exit,
    stdout_buffered = false,
  })

  if not job_id or job_id <= 0 then
    vim.notify("python-nav: failed to start server", vim.log.levels.ERROR)
    job_id = nil
    return
  end

  do_initialize()
end

function M.call(tool, args, callback)
  if initialized then
    do_call(tool, args, callback)
  else
    table.insert(init_queue, function() do_call(tool, args, callback) end)
  end
end

function M.stop()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id      = nil
    initialized = false
  end
end

function M.is_running()
  return job_id ~= nil
end

return M
