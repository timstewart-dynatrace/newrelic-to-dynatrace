#!/usr/bin/env bash
# Render newrelic-export/docs_markdown/*.md to newrelic-export/docs_html/*.html
# using pandoc and the DMA template.
#
# Usage:
#   ./build-docs.sh           # render all markdown files
#   ./build-docs.sh README-NEWRELIC.md   # render a single file
#
# Requires: pandoc (brew install pandoc / apt-get install pandoc)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/newrelic-export/docs_markdown"
DST="$ROOT/newrelic-export/docs_html"
TPL="$DST/html-template.html"

[[ -d "$SRC" ]] || { echo "ERROR: source dir not found: $SRC" >&2; exit 1; }
[[ -f "$TPL" ]] || { echo "ERROR: template not found: $TPL" >&2; exit 1; }
command -v pandoc >/dev/null 2>&1 || {
    echo "ERROR: pandoc not installed." >&2
    echo "  Install: brew install pandoc (macOS) or apt-get install pandoc (Linux)" >&2
    exit 1
}

# If a specific filename is passed, render only that file
if [[ $# -gt 0 ]]; then
    targets=("$SRC/$1")
else
    targets=("$SRC"/*.md)
fi

count=0
for md in "${targets[@]}"; do
    [[ -f "$md" ]] || { echo "WARN: not found, skipping: $md" >&2; continue; }
    name="$(basename "$md" .md)"
    out="$DST/${name}.html"
    # Pull title from the first H1 line (strip leading '# ')
    title="$(grep -m1 '^# ' "$md" | sed 's/^#\s*//' || echo "$name")"

    pandoc "$md" \
        --standalone \
        --template "$TPL" \
        --metadata title="$title" \
        --from markdown \
        --to html5 \
        -o "$out"

    echo "  ✓ $name.html"
    count=$((count + 1))
done

echo ""
echo "Rendered $count file(s) to $DST/"
