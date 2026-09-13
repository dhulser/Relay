#!/bin/bash
# Assembles the marketing site into dist-site/ as a complete static page.
#
# site/index.html is kept as a fragment (title, styles, then the page) because
# that is what the Claude artifact preview takes; GitHub Pages needs a whole
# document, so this wraps it and adds the tags a shared link wants.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/site/index.html"
OUT="$ROOT/dist-site"
URL="https://dhulser.github.io/Relay/"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$ROOT/site/assets" "$OUT/assets"

# Everything before the page wrapper is head material; the rest is the body.
SPLIT='<div class="wrap">'
HEAD_PART="$(python3 -c 'import sys; s=open(sys.argv[1]).read(); print(s[:s.index(sys.argv[2])])' "$SRC" "$SPLIT")"
BODY_PART="$(python3 -c 'import sys; s=open(sys.argv[1]).read(); print(s[s.index(sys.argv[2]):])' "$SRC" "$SPLIT")"

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
<meta property="og:title" content="Relay: Live Translator for Mac">
<meta property="og:description" content="Live subtitles in your language for calls and anything else playing on your Mac.">
<meta property="og:image" content="${URL}assets/subtitles.png">
<meta name="twitter:card" content="summary_large_image">
HEAD
  printf '%s\n' "$HEAD_PART"
  echo "</head>"
  echo "<body>"
  printf '%s\n' "$BODY_PART"
  echo "</body>"
  echo "</html>"
} > "$OUT/index.html"

echo "dist-site/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes)"
