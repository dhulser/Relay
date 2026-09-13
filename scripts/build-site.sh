#!/bin/bash
# Assembles the marketing site into dist-site/ as complete static pages.
#
# Each site/*.html is kept as a fragment (title, head tags, styles, then the
# page) because that is what the Claude artifact preview takes; GitHub Pages
# needs whole documents, so this wraps each one and adds the tags a shared
# link wants. site.css and assets/ are copied alongside.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist-site"
BASE="https://dhulser.github.io/Relay/"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$ROOT/site/assets" "$OUT/assets"
cp "$ROOT/site/site.css" "$OUT/site.css"

for SRC in "$ROOT"/site/*.html; do
  NAME="$(basename "$SRC")"
  URL="$BASE"; [ "$NAME" = "index.html" ] || URL="$BASE$NAME"

  # Everything before the page wrapper is head material; the rest is the body.
  SPLIT='<div class="wrap">'
  HEAD_PART="$(python3 -c 'import sys; s=open(sys.argv[1]).read(); print(s[:s.index(sys.argv[2])])' "$SRC" "$SPLIT")"
  BODY_PART="$(python3 -c 'import sys; s=open(sys.argv[1]).read(); print(s[s.index(sys.argv[2]):])' "$SRC" "$SPLIT")"
  TITLE="$(printf '%s' "$HEAD_PART" | sed -n 's|.*<title>\(.*\)</title>.*|\1|p' | head -1)"
  DESC="$(printf '%s' "$HEAD_PART" | sed -n 's|.*<meta name="description" content="\([^"]*\)".*|\1|p' | head -1)"

  {
    cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#5B63D3">
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="$URL">
<meta property="og:type" content="website">
<meta property="og:url" content="$URL">
<meta property="og:title" content="$TITLE">
<meta property="og:description" content="$DESC">
<meta property="og:image" content="${BASE}assets/subtitles.png">
<meta name="twitter:card" content="summary_large_image">
HEAD
    printf '%s\n' "$HEAD_PART"
    echo "</head>"
    echo "<body>"
    printf '%s\n' "$BODY_PART"
    echo "</body>"
    echo "</html>"
  } > "$OUT/$NAME"
  echo "dist-site/$NAME ($(wc -c < "$OUT/$NAME" | tr -d ' ') bytes)"
done
