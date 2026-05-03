import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";
import Database from "better-sqlite3";
import * as fs from "fs";
import * as path from "path";

const DB_PATH = process.env.NAV_DB ?? ".nav.db";
const ROOT = process.env.NAV_ROOT ?? ".";

let _db: Database.Database | null = null;

// Bounded in-memory cache for context results
const contextCache = new Map<string, unknown>();
const CACHE_MAX = 50;

function cacheSet(key: string, val: unknown) {
  if (contextCache.size >= CACHE_MAX) {
    const oldest = contextCache.keys().next().value;
    if (oldest !== undefined) contextCache.delete(oldest);
  }
  contextCache.set(key, val);
}

function getDb(): Database.Database | null {
  if (!fs.existsSync(DB_PATH)) return null;
  if (!_db) {
    _db = new Database(DB_PATH, { readonly: true });
  }
  return _db;
}

// ── Query helpers ─────────────────────────────────────────────────────────────

function findDefinition(name: string) {
  const db = getDb();
  if (!db) return [];
  return db
    .prepare(
      `SELECT name, type, file, start_line, end_line
       FROM symbols
       WHERE name = ?
       ORDER BY CASE type
         WHEN 'function' THEN 0
         WHEN 'method'   THEN 1
         WHEN 'class'    THEN 2
         ELSE 3 END, file`
    )
    .all(name);
}

function findReferences(name: string, limit: number = 20) {
  const db = getDb();
  if (!db) return [];
  return db
    .prepare(
      `SELECT r.symbol_name, r.file, r.line,
         (SELECT COUNT(*) FROM symbols s WHERE s.name = r.symbol_name AND s.file = r.file) as def_in_file
       FROM symbol_refs r
       WHERE r.symbol_name = ?
       ORDER BY def_in_file DESC, r.file, r.line
       LIMIT ?`
    )
    .all(name, Math.min(limit, 20));
}

function stripPythonComments(lines: string[]): string[] {
  return lines
    .map((line) => {
      const idx = line.indexOf("#");
      if (idx === -1) return line;
      const before = line.slice(0, idx);
      const sq = (before.match(/'/g) || []).length;
      const dq = (before.match(/"/g) || []).length;
      if (sq % 2 === 0 && dq % 2 === 0) return line.slice(0, idx).trimEnd();
      return line;
    })
    .filter((l) => l.trimEnd() !== "");
}

function getContext(
  file: string,
  lineNum: number,
  radius: number = 40,
  level: number = 2,
  strip: boolean = false
) {
  const cacheKey = `${file}:${lineNum}:${radius}:${level}:${strip}`;
  if (contextCache.has(cacheKey)) return contextCache.get(cacheKey);

  const fullPath = path.join(ROOT, file);
  if (!fs.existsSync(fullPath)) return { error: `File not found: ${file}` };

  const db = getDb();
  const enclosing = db
    ? (db
        .prepare(
          `SELECT name, type, start_line, end_line
           FROM symbols
           WHERE file = ? AND start_line <= ? AND end_line >= ?
           ORDER BY (end_line - start_line) ASC
           LIMIT 1`
        )
        .get(file, lineNum, lineNum) as
        | { name: string; type: string; start_line: number; end_line: number }
        | undefined)
    : undefined;

  // Level 1: metadata only, no source lines
  if (level === 1) {
    const result = {
      file,
      line: lineNum,
      enclosing: enclosing
        ? {
            name: enclosing.name,
            type: enclosing.type,
            start_line: enclosing.start_line,
            end_line: enclosing.end_line,
          }
        : null,
    };
    cacheSet(cacheKey, result);
    return result;
  }

  const allLines = fs.readFileSync(fullPath, "utf-8").split("\n");
  const total = allLines.length;

  // Level 3 allows up to 80 lines; levels 1/2 use radius (default 40)
  const effectiveRadius = level >= 3 ? 40 : radius;
  const hardCap = 80; // max context lines (reduced from 100)

  let startIdx: number;
  let endIdx: number;

  if (enclosing) {
    startIdx = enclosing.start_line - 1;
    endIdx = enclosing.end_line - 1;
    if (endIdx - startIdx > hardCap - 1) {
      startIdx = Math.max(0, lineNum - 1 - effectiveRadius);
      endIdx = Math.min(total - 1, lineNum - 1 + effectiveRadius);
    }
  } else {
    startIdx = Math.max(0, lineNum - 1 - effectiveRadius);
    endIdx = Math.min(total - 1, lineNum - 1 + effectiveRadius);
  }

  if (endIdx - startIdx > hardCap - 1) endIdx = startIdx + hardCap - 1;
  endIdx = Math.min(endIdx, total - 1);

  let rawLines = allLines.slice(startIdx, endIdx + 1);
  if (strip) rawLines = stripPythonComments(rawLines);

  const lines = rawLines.map((l, i) => `${startIdx + i + 1}: ${l}`);

  const result = {
    file,
    start_line: startIdx + 1,
    end_line: endIdx + 1,
    enclosing: enclosing ? { name: enclosing.name, type: enclosing.type } : null,
    lines,
  };
  cacheSet(cacheKey, result);
  return result;
}

function searchText(query: string, limit: number = 10) {
  const db = getDb();
  if (!db) return [];
  return db
    .prepare(
      `SELECT name, type, file, start_line
       FROM symbols
       WHERE name LIKE ?
       ORDER BY
         CASE WHEN name = ? THEN 0 ELSE 1 END,
         name
       LIMIT ?`
    )
    .all(`%${query}%`, query, Math.min(limit, 20));
}

function codeAction(symbol: string, intent: "refactor" | "add_feature") {
  const db = getDb();
  if (!db) return { error: "Database not loaded" };

  const sym = db
    .prepare(`SELECT * FROM symbols WHERE name = ? LIMIT 1`)
    .get(symbol) as
    | { name: string; type: string; file: string; start_line: number; end_line: number }
    | undefined;

  if (!sym) return { error: `Symbol '${symbol}' not found in index` };

  const refs = db
    .prepare(
      `SELECT file, line FROM symbol_refs WHERE symbol_name = ? ORDER BY file, line LIMIT 20`
    )
    .all(symbol) as { file: string; line: number }[];

  const affectedFiles = [...new Set(refs.map((r) => r.file))];

  if (intent === "refactor") {
    return {
      symbol: sym.name,
      type: sym.type,
      defined_at: { file: sym.file, line: sym.start_line },
      reference_count: refs.length,
      affected_files: affectedFiles,
      plan: [
        `1. Open definition: ${sym.file}:${sym.start_line}`,
        `2. Understand current signature/logic`,
        `3. Update definition`,
        `4. Visit each call site (${refs.length} references across ${affectedFiles.length} files)`,
        `5. Run :Refs after editing to verify no missed sites`,
      ],
      call_sites: refs.slice(0, 10),
    };
  } else {
    return {
      symbol: sym.name,
      type: sym.type,
      insertion_point: { file: sym.file, after_line: sym.end_line },
      plan: [
        `1. Open ${sym.file}`,
        `2. Insert new ${sym.type === "method" ? "method" : "function"} after line ${sym.end_line}`,
        `3. Follow naming/style of existing '${sym.name}' ${sym.type}`,
        `4. Add call sites as needed`,
      ],
    };
  }
}

// ── New: analyze_usages ────────────────────────────────────────────────────────

function classifyPattern(line: string, symbol: string): string {
  const t = line.trim();
  // Destructuring: a, b = ... (comma before =)
  if (/^[a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)+\s*=/.test(t)) return "destructuring";
  // Assignment: x = symbol(...)
  if (/^[a-zA-Z_][\w.]*\s*=\s*/.test(t) && t.includes(symbol)) return "assignment";
  // Chained: obj.symbol or symbol.method
  if (t.includes("." + symbol) || (t.includes(symbol + ".") && !t.startsWith(symbol + " ")))
    return "chained";
  return "ignored";
}

function analyzeUsages(symbol: string) {
  const db = getDb();
  if (!db) return { error: "Database not loaded" };

  const sym = db
    .prepare(`SELECT file, start_line, end_line FROM symbols WHERE name = ? LIMIT 1`)
    .get(symbol) as { file: string; start_line: number; end_line: number } | undefined;

  const refs = db
    .prepare(
      `SELECT file, line FROM symbol_refs WHERE symbol_name = ? ORDER BY file, line LIMIT 100`
    )
    .all(symbol) as { file: string; line: number }[];

  const empty = {
    symbol,
    defined_in: sym ? { file: sym.file, start_line: sym.start_line } : null,
    total_refs: 0,
    same_file: [] as unknown[],
    same_module: [] as unknown[],
    external: [] as unknown[],
    patterns: { assignment: 0, destructuring: 0, chained: 0, ignored: 0 },
  };
  if (refs.length === 0) return empty;

  const symDir = sym ? path.dirname(sym.file) : null;
  const groups: { same_file: unknown[]; same_module: unknown[]; external: unknown[] } = {
    same_file: [],
    same_module: [],
    external: [],
  };
  const patCounts: Record<string, number> = {
    assignment: 0, destructuring: 0, chained: 0, ignored: 0,
  };

  const fileLineCache = new Map<string, string[]>();

  for (const ref of refs) {
    const entry: Record<string, unknown> = { file: ref.file, line: ref.line };

    if (sym && ref.file === sym.file) groups.same_file.push(entry);
    else if (symDir && path.dirname(ref.file) === symDir) groups.same_module.push(entry);
    else groups.external.push(entry);

    const fp = path.join(ROOT, ref.file);
    if (fs.existsSync(fp)) {
      if (!fileLineCache.has(ref.file)) {
        fileLineCache.set(ref.file, fs.readFileSync(fp, "utf-8").split("\n"));
      }
      const lineContent = (fileLineCache.get(ref.file) ?? [])[ref.line - 1] ?? "";
      const pat = classifyPattern(lineContent, symbol);
      patCounts[pat]++;
      entry.pattern = pat;
      entry.content = lineContent.trim().slice(0, 80);
    }
  }

  return {
    symbol,
    defined_in: sym ? { file: sym.file, start_line: sym.start_line } : null,
    total_refs: refs.length,
    same_file:    groups.same_file.slice(0, 10),
    same_module:  groups.same_module.slice(0, 10),
    external:     groups.external.slice(0, 10),
    patterns: patCounts,
  };
}

// ── New: generate_patch ────────────────────────────────────────────────────────

const PATCH_GUIDANCE: Record<string, string> = {
  add_field:      "Add new field to return value or parameter list",
  remove_field:   "Remove a field from return value or parameter list",
  rename:         "Rename symbol — update definition and all internal references",
  refactor_logic: "Restructure internal logic without changing the public interface",
};

function generatePatch(symbol: string, intent: string) {
  const db = getDb();
  if (!db) return { error: "Database not loaded" };

  const sym = db
    .prepare(
      `SELECT name, type, file, start_line, end_line FROM symbols WHERE name = ? LIMIT 1`
    )
    .get(symbol) as
    | { name: string; type: string; file: string; start_line: number; end_line: number }
    | undefined;

  if (!sym) return { error: `Symbol '${symbol}' not found` };

  const fullPath = path.join(ROOT, sym.file);
  if (!fs.existsSync(fullPath)) return { error: `File not found: ${sym.file}` };

  const allLines = fs.readFileSync(fullPath, "utf-8").split("\n");
  const sourceLines = allLines.slice(sym.start_line - 1, sym.end_line);

  const refs = db
    .prepare(
      `SELECT file, line FROM symbol_refs WHERE symbol_name = ? ORDER BY file, line LIMIT 20`
    )
    .all(symbol) as { file: string; line: number }[];

  return {
    symbol:    sym.name,
    type:      sym.type,
    file:      sym.file,
    start_line: sym.start_line,
    end_line:   sym.end_line,
    intent,
    guidance:  PATCH_GUIDANCE[intent] ?? `Modify '${symbol}' for intent: ${intent}`,
    source_lines:    sourceLines,
    line_count:      sourceLines.length,
    reference_count: refs.length,
    call_sites:      refs.slice(0, 10),
  };
}

// ── Tool definitions ──────────────────────────────────────────────────────────

const TOOLS: Tool[] = [
  {
    name: "find_definition",
    description: "Find where a Python symbol (function/class/method) is defined. Returns file, line, and type.",
    inputSchema: {
      type: "object" as const,
      properties: {
        name: { type: "string", description: "Exact symbol name" },
      },
      required: ["name"],
    },
  },
  {
    name: "find_references",
    description: "Find all usages of a symbol. Ranked: definition files first. Max 20 results.",
    inputSchema: {
      type: "object" as const,
      properties: {
        name:  { type: "string", description: "Symbol name" },
        limit: { type: "number", description: "Max results (default 20, max 20)" },
      },
      required: ["name"],
    },
  },
  {
    name: "get_context",
    description: "Get source lines around a location. Returns enclosing function/class block (max 80 lines). Level 1=metadata only, 2=≤40 lines (default), 3=≤80 lines.",
    inputSchema: {
      type: "object" as const,
      properties: {
        file:   { type: "string", description: "Relative file path (from repo root)" },
        line:   { type: "number", description: "Line number (1-based)" },
        radius: { type: "number", description: "Lines around target when no enclosing symbol (default 40)" },
        level:  { type: "number", description: "Detail level: 1=metadata, 2=≤40 lines, 3=≤80 lines (default 2)" },
        strip_comments: { type: "boolean", description: "Strip Python comments from output (default false)" },
      },
      required: ["file", "line"],
    },
  },
  {
    name: "search_text",
    description: "Search symbols by partial name match. Returns definitions only (no full file scan). Max 20 results.",
    inputSchema: {
      type: "object" as const,
      properties: {
        query: { type: "string", description: "Partial symbol name" },
        limit: { type: "number", description: "Max results (default 10, max 20)" },
      },
      required: ["query"],
    },
  },
  {
    name: "code_action",
    description: "Get a structured impact analysis and step-by-step plan for refactoring or adding a feature.",
    inputSchema: {
      type: "object" as const,
      properties: {
        symbol: { type: "string", description: "Target symbol name" },
        intent: {
          type: "string",
          enum: ["refactor", "add_feature"],
          description: "What you intend to do",
        },
      },
      required: ["symbol", "intent"],
    },
  },
  {
    name: "analyze_usages",
    description: "Pre-edit analysis: groups all references by proximity (same_file/same_module/external) and classifies usage patterns (assignment/destructuring/chained/ignored). No code blocks — structured data only.",
    inputSchema: {
      type: "object" as const,
      properties: {
        symbol: { type: "string", description: "Symbol name to analyze" },
      },
      required: ["symbol"],
    },
  },
  {
    name: "generate_patch",
    description: "Returns the current source block for a symbol plus intent-aware guidance. Use this to prepare a targeted, minimal diff. Supports intents: add_field, remove_field, rename, refactor_logic.",
    inputSchema: {
      type: "object" as const,
      properties: {
        symbol: { type: "string", description: "Target symbol name" },
        intent: {
          type: "string",
          enum: ["add_field", "remove_field", "rename", "refactor_logic"],
          description: "What you intend to change",
        },
      },
      required: ["symbol", "intent"],
    },
  },
];

// ── Server bootstrap ──────────────────────────────────────────────────────────

async function main() {
  const server = new Server(
    { name: "python-nav", version: "1.1.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    const a = args as Record<string, unknown>;

    try {
      let result: unknown;

      switch (name) {
        case "find_definition":
          result = findDefinition(a.name as string);
          break;
        case "find_references":
          result = findReferences(a.name as string, (a.limit as number) ?? 20);
          break;
        case "get_context":
          result = getContext(
            a.file as string,
            a.line as number,
            (a.radius as number) ?? 40,
            (a.level as number) ?? 2,
            (a.strip_comments as boolean) ?? false
          );
          break;
        case "search_text":
          result = searchText(a.query as string, (a.limit as number) ?? 10);
          break;
        case "code_action":
          result = codeAction(a.symbol as string, a.intent as "refactor" | "add_feature");
          break;
        case "analyze_usages":
          result = analyzeUsages(a.symbol as string);
          break;
        case "generate_patch":
          result = generatePatch(a.symbol as string, a.intent as string);
          break;
        default:
          return {
            content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
            isError: true,
          };
      }

      return {
        content: [{ type: "text" as const, text: JSON.stringify(result, null, 2) }],
      };
    } catch (err) {
      return {
        content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }],
        isError: true,
      };
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`Fatal: ${err}\n`);
  process.exit(1);
});
