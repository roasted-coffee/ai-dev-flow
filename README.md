# python-nav

Index-driven Python navigation for Neovim. Not autocomplete, not a full IDE — a constrained, structured retrieval system backed by Tree-sitter and SQLite.

**Stack:** Python indexer → SQLite → MCP server (Node.js) → Neovim Lua plugin

---

## What it does

- Jump to definitions (`gd`)
- Find all usages (`gr`)
- Show enclosing function/class block (`K`)
- Pre-edit impact analysis (`:Analyze`)
- Diff-based patch workflow (`:Patch` → `:ApplyPatch`)
- Symbol search (`:Search`)
- Structured refactor/feature plans (`:CodeAction`)

All results are bounded: max 20 references, max 80 context lines, no full file reads.

---

## Requirements

- Python 3.10+
- Node.js 18+
- Neovim 0.9+

---

## Setup

```bash
git clone <repo> python-nav
cd python-nav
bash setup.sh
```

`setup.sh` installs Python deps, runs `npm install`, and builds the TypeScript server.

---

## Index your project

```bash
python3 indexer/indexer.py /path/to/your/project
```

Creates `.nav.db` in your current directory. Move it to the project root:

```bash
mv .nav.db /path/to/your/project/
```

Re-run any time to pick up changes. Incremental: only re-parses files whose content changed.

---

## Neovim config

### lazy.nvim

```lua
{
  dir = "/path/to/python-nav/nvim",
  config = function()
    require("python_nav").setup({
      root = "/path/to/your/project",
    })
  end,
}
```

### Manual (no plugin manager)

```lua
-- In your init.lua
vim.opt.rtp:prepend("/path/to/python-nav/nvim")
require("python_nav").setup({
  root = "/path/to/your/project",
})
```

### Config options

```lua
require("python_nav").setup({
  root        = "/path/to/project",   -- required; defaults to cwd
  db_path     = "/path/to/.nav.db",   -- defaults to root/.nav.db
  server_cmd  = { "node", "/path/to/dist/index.js" },  -- auto-detected
  indexer_cmd = { "python3", "/path/to/indexer.py" },  -- auto-detected
})
```

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:Def [name]` | optional | Jump to definition. Uses word under cursor if no arg. Multiple results → pick list. |
| `:Context` | — | Show enclosing function/class block (≤80 lines) in floating window. |
| `:Refs [name]` | optional | Find all usages → quickfix list. |
| `:Search <query>` | required | Partial symbol name search. |
| `:Analyze [name]` | optional | Pre-edit impact analysis: usage groups + patterns. |
| `:Patch [name]` | optional | Generate diff view for targeted edit. |
| `:ApplyPatch` | — | Write right pane of diff back to file (with confirmation). |
| `:CodeAction [name]` | optional | Structured refactor/add-feature plan. |
| `:NavIndex` | — | Re-run indexer against configured root. |
| `:NavStop` | — | Stop the MCP server process. |

### Keymaps

| Key | Action |
|-----|--------|
| `gd` | `:Def` |
| `gr` | `:Refs` |
| `K` | `:Context` |

---

## Workflow examples

### Jump to definition

Place cursor on any symbol, press `gd`. If multiple definitions exist (e.g. same name in different files), a pick list opens.

### Find all usages

Press `gr` on a symbol. Results open in the quickfix list — navigate with `:cn` / `:cp` or via your quickfix plugin.

### Pre-edit analysis

```vim
:Analyze parse_args
```

Shows:

```
Symbol : parse_args
Defined: utils/cli.py:12
Total  : 7 references

Usage patterns:
  assignment      4
  ignored         3

Same file (2):
  utils/cli.py:12   def parse_args(argv):
  utils/cli.py:45   result = parse_args(sys.argv)

Same module (1):
  utils/config.py:8   result = parse_args(args)

External (4):
  tests/test_cli.py:15   out = parse_args(["--debug"])
  ...
```

### Patch workflow

1. Place cursor on symbol, run `:Patch`
2. Select intent from menu: `add_field / remove_field / rename / refactor_logic`
3. Diff opens — left pane is read-only original, right pane is editable
4. Edit the right pane (or ask Claude to suggest changes)
5. Run `:ApplyPatch` — confirms before writing

```
:Patch process_result
> add_field
[add_field] process_result  handlers/result.py:34-41 — edit right pane, :ApplyPatch to apply
```

After editing:

```
:ApplyPatch
Apply patch to handlers/result.py lines 34–41? [Yes/No]
> Yes
python-nav: patch applied to handlers/result.py — save with :w
```

### CodeAction

```vim
:CodeAction validate_input
```

Select `refactor`:

```
Symbol : validate_input  [function]
Defined: core/validation.py:88

Refs   : 12 across 5 files

Plan:
  1. Open definition: core/validation.py:88
  2. Understand current signature/logic
  3. Update definition
  4. Visit each call site (12 references across 5 files)
  5. Run :Refs after editing to verify no missed sites

Call sites (first 10):
  api/endpoints.py:34
  api/endpoints.py:67
  ...
```

---

## MCP server tools

The server is also usable as a standalone MCP server (e.g. from Claude Code). Tools:

| Tool | Parameters | Description |
|------|-----------|-------------|
| `find_definition` | `name` | Exact symbol lookup. Returns file, line, type. |
| `find_references` | `name`, `limit?` | All usages, ranked definition-files-first. Max 20. |
| `get_context` | `file`, `line`, `level?`, `radius?`, `strip_comments?` | Source block around location. `level`: 1=metadata, 2=≤40 lines, 3=≤80 lines. |
| `search_text` | `query`, `limit?` | Partial symbol name match. Max 20. |
| `analyze_usages` | `symbol` | Grouped references + usage pattern classification. |
| `generate_patch` | `symbol`, `intent` | Current source block + intent guidance. Intents: `add_field`, `remove_field`, `rename`, `refactor_logic`. |
| `code_action` | `symbol`, `intent` | Step-by-step plan. Intents: `refactor`, `add_feature`. |

### Claude Code (`~/.claude.json` or `.mcp.json`)

```json
{
  "mcpServers": {
    "python-nav": {
      "command": "node",
      "args": ["/path/to/python-nav/server/dist/index.js"],
      "env": {
        "NAV_ROOT": "/path/to/your/project",
        "NAV_DB":   "/path/to/your/project/.nav.db"
      }
    }
  }
}
```

---

## Database schema

```sql
files       (path TEXT PRIMARY KEY, hash TEXT)
symbols     (id, name, type, file, start_line, end_line)
symbol_refs (symbol_name, file, line)
imports     (from_file, module, symbol, alias)
```

Indexes on `symbols(name)`, `symbol_refs(symbol_name)`, `symbol_refs(file)`, `symbols(file)`.

---

## Limitations

- Python only (Tree-sitter Python grammar)
- References are identifier-based, not type-resolved — dynamic dispatch and monkey-patching produce false positives
- No cross-file type inference
- Incremental index updates require re-running the indexer (`:NavIndex` or CLI)

---

## Project structure

```
python-nav/
├── indexer/
│   ├── indexer.py          # Tree-sitter → SQLite
│   └── requirements.txt
├── server/
│   └── src/index.ts        # MCP server (7 tools)
├── nvim/
│   └── lua/python_nav/
│       ├── init.lua         # Commands, keymaps, patch workflow
│       ├── client.lua       # JSON-RPC stdio client
│       └── ui.lua           # Floating window + list picker
└── setup.sh
```
