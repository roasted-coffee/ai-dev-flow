#!/usr/bin/env python3
"""
Python codebase indexer using Tree-sitter.
Extracts definitions, references, and imports into SQLite.
Incremental: only re-parses files whose hash changed.
"""

import argparse
import hashlib
import os
import sqlite3
import sys
from pathlib import Path

try:
    import tree_sitter_python as tspython
    from tree_sitter import Language, Parser
except ImportError:
    print("Missing deps. Run: pip install tree-sitter tree-sitter-python", file=sys.stderr)
    sys.exit(1)

PY_LANG = Language(tspython.language())
_parser = Parser(PY_LANG)

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY,
    hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS symbols (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    file TEXT NOT NULL,
    start_line INTEGER NOT NULL,
    end_line   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS symbol_refs (
    symbol_name TEXT NOT NULL,
    file        TEXT NOT NULL,
    line        INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS imports (
    from_file TEXT NOT NULL,
    module    TEXT NOT NULL,
    symbol    TEXT,
    alias     TEXT
);
CREATE INDEX IF NOT EXISTS idx_sym_name  ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_ref_name  ON symbol_refs(symbol_name);
CREATE INDEX IF NOT EXISTS idx_ref_file  ON symbol_refs(file);
CREATE INDEX IF NOT EXISTS idx_sym_file  ON symbols(file);
"""


def open_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def file_hash(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def parse_source(path: str):
    with open(path, "rb") as f:
        src = f.read()
    tree = _parser.parse(src)
    return tree, src


# ── Definitions ───────────────────────────────────────────────────────────────

def extract_definitions(tree, src: bytes, file_path: str) -> list[dict]:
    results = []

    def walk(node, enclosing_class: str | None = None):
        t = node.type

        if t == "function_definition":
            name_node = node.child_by_field_name("name")
            if name_node:
                sym_type = "method" if enclosing_class else "function"
                results.append({
                    "name": src[name_node.start_byte:name_node.end_byte].decode(),
                    "type": sym_type,
                    "file": file_path,
                    "start_line": node.start_point[0] + 1,
                    "end_line":   node.end_point[0] + 1,
                })
            # Recurse into body (nested functions are still functions)
            for child in node.children:
                walk(child, enclosing_class)

        elif t == "class_definition":
            name_node = node.child_by_field_name("name")
            cls_name = None
            if name_node:
                cls_name = src[name_node.start_byte:name_node.end_byte].decode()
                results.append({
                    "name": cls_name,
                    "type": "class",
                    "file": file_path,
                    "start_line": node.start_point[0] + 1,
                    "end_line":   node.end_point[0] + 1,
                })
            for child in node.children:
                walk(child, cls_name or enclosing_class)

        else:
            for child in node.children:
                walk(child, enclosing_class)

    walk(tree.root_node)
    return results


# ── References ────────────────────────────────────────────────────────────────

def extract_references(tree, src: bytes, file_path: str) -> list[dict]:
    results = []
    seen: set[tuple] = set()

    def walk(node):
        t = node.type

        if t == "identifier":
            name = src[node.start_byte:node.end_byte].decode()
            line = node.start_point[0] + 1
            key = (name, line)
            if key not in seen:
                seen.add(key)
                results.append({"symbol_name": name, "file": file_path, "line": line})

        elif t == "attribute":
            # Capture the attribute portion of obj.attr
            attr = node.child_by_field_name("attribute")
            if attr:
                name = src[attr.start_byte:attr.end_byte].decode()
                line = attr.start_point[0] + 1
                key = (name, line)
                if key not in seen:
                    seen.add(key)
                    results.append({"symbol_name": name, "file": file_path, "line": line})
            # Still recurse so we capture the object side
            for child in node.children:
                walk(child)
            return  # avoid double-processing attribute children

        for child in node.children:
            walk(child)

    walk(tree.root_node)
    return results


# ── Imports ───────────────────────────────────────────────────────────────────

def _text(src: bytes, node) -> str:
    return src[node.start_byte:node.end_byte].decode()


def extract_imports(tree, src: bytes, file_path: str) -> list[dict]:
    results = []

    def walk(node):
        t = node.type

        if t == "import_statement":
            for child in node.children:
                if child.type == "dotted_name":
                    results.append({
                        "from_file": file_path,
                        "module": _text(src, child),
                        "symbol": None,
                        "alias": None,
                    })
                elif child.type == "aliased_import":
                    name_n  = child.child_by_field_name("name")
                    alias_n = child.child_by_field_name("alias")
                    results.append({
                        "from_file": file_path,
                        "module": _text(src, name_n) if name_n else "",
                        "symbol": None,
                        "alias": _text(src, alias_n) if alias_n else None,
                    })
            return  # don't recurse into import children

        elif t == "import_from_statement":
            mod_node = node.child_by_field_name("module_name")
            module = _text(src, mod_node) if mod_node else ""

            for child in node.children:
                if child == mod_node:
                    continue
                if child.type == "import_from_names":
                    for imp in child.children:
                        if imp.type in ("identifier", "dotted_name"):
                            results.append({
                                "from_file": file_path,
                                "module": module,
                                "symbol": _text(src, imp),
                                "alias": None,
                            })
                        elif imp.type == "aliased_import":
                            n_n = imp.child_by_field_name("name")
                            a_n = imp.child_by_field_name("alias")
                            results.append({
                                "from_file": file_path,
                                "module": module,
                                "symbol": _text(src, n_n) if n_n else "",
                                "alias": _text(src, a_n) if a_n else None,
                            })
                elif child.type in ("identifier", "dotted_name"):
                    results.append({
                        "from_file": file_path,
                        "module": module,
                        "symbol": _text(src, child),
                        "alias": None,
                    })
                elif child.type == "aliased_import":
                    n_n = child.child_by_field_name("name")
                    a_n = child.child_by_field_name("alias")
                    results.append({
                        "from_file": file_path,
                        "module": module,
                        "symbol": _text(src, n_n) if n_n else "",
                        "alias": _text(src, a_n) if a_n else None,
                    })
            return

        for child in node.children:
            walk(child)

    walk(tree.root_node)
    return results


# ── Indexing ──────────────────────────────────────────────────────────────────

def index_file(conn: sqlite3.Connection, abs_path: str, root: str) -> bool:
    rel = os.path.relpath(abs_path, root)
    h = file_hash(abs_path)

    row = conn.execute("SELECT hash FROM files WHERE path = ?", (rel,)).fetchone()
    if row and row["hash"] == h:
        return False  # unchanged

    conn.execute("DELETE FROM symbols    WHERE file      = ?", (rel,))
    conn.execute("DELETE FROM symbol_refs WHERE file      = ?", (rel,))
    conn.execute("DELETE FROM imports    WHERE from_file = ?", (rel,))

    try:
        tree, src = parse_source(abs_path)
    except Exception as e:
        print(f"  parse error {rel}: {e}", file=sys.stderr)
        return False

    for d in extract_definitions(tree, src, rel):
        conn.execute(
            "INSERT INTO symbols (name, type, file, start_line, end_line) VALUES (?,?,?,?,?)",
            (d["name"], d["type"], d["file"], d["start_line"], d["end_line"]),
        )

    for r in extract_references(tree, src, rel):
        conn.execute(
            "INSERT INTO symbol_refs (symbol_name, file, line) VALUES (?,?,?)",
            (r["symbol_name"], r["file"], r["line"]),
        )

    for i in extract_imports(tree, src, rel):
        conn.execute(
            "INSERT INTO imports (from_file, module, symbol, alias) VALUES (?,?,?,?)",
            (i["from_file"], i["module"], i["symbol"], i["alias"]),
        )

    conn.execute(
        "INSERT OR REPLACE INTO files (path, hash) VALUES (?,?)",
        (rel, h),
    )
    conn.commit()
    return True


SKIP_DIRS = {".git", "__pycache__", ".venv", "venv", "node_modules", ".tox", "dist", "build"}


def index_repo(root: str, db_path: str, verbose: bool = True):
    conn = open_db(db_path)
    updated = total = 0

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for fn in filenames:
            if not fn.endswith(".py"):
                continue
            total += 1
            abs_path = os.path.join(dirpath, fn)
            if index_file(conn, abs_path, root):
                updated += 1
                if verbose:
                    print(f"  indexed: {os.path.relpath(abs_path, root)}")

    conn.close()
    print(f"Done. {updated}/{total} files updated.")


def main():
    ap = argparse.ArgumentParser(description="Index a Python repo into SQLite")
    ap.add_argument("root", help="Root directory")
    ap.add_argument("--db", default=".nav.db", help="SQLite path (default: .nav.db in cwd)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"Not a directory: {root}", file=sys.stderr)
        sys.exit(1)

    index_repo(root, args.db, verbose=not args.quiet)


if __name__ == "__main__":
    main()
