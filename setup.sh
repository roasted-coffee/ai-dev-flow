#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> python-nav setup"

# ── Python indexer deps ───────────────────────────────────────────────────────
echo ""
echo "[1/2] Installing Python deps..."
pip install -r "$SCRIPT_DIR/indexer/requirements.txt" --quiet

# ── TypeScript MCP server ─────────────────────────────────────────────────────
echo ""
echo "[2/2] Building MCP server..."
cd "$SCRIPT_DIR/server"
npm install --silent
npm run build

echo ""
echo "Done."
echo ""
echo "Next steps:"
echo "  1. Index your Python project:"
echo "       python3 $SCRIPT_DIR/indexer/indexer.py /path/to/your/project"
echo "     This creates .nav.db in your CWD. Move it to the project root."
echo ""
echo "  2. Add to your Neovim config (lazy.nvim example):"
echo '     {'
echo '       dir = "'"$SCRIPT_DIR/nvim"'",'
echo '       config = function()'
echo '         require("python_nav").setup({'
echo '           root = "/path/to/your/project",'
echo '         })'
echo '       end,'
echo '     }'
echo ""
echo "  3. Inside Neovim:"
echo "       :NavIndex   – re-index (runs indexer against configured root)"
echo "       gd / :Def   – jump to definition"
echo "       K  / :Context – show enclosing function/class block"
echo "       gr / :Refs  – find references (quickfix)"
echo "       :Search <q> – symbol search"
echo "       :CodeAction – refactor/add-feature plan"
