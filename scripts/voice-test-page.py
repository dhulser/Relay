#!/usr/bin/env python3
"""Builds build/voice-test/index.html from whatever samples are in that folder."""
import os, re, html
out = os.path.join(os.path.dirname(__file__), "..", "build", "voice-test")
files = sorted(f for f in os.listdir(out) if f.endswith(".m4a"))
EN = "Sorry, could you repeat the last part? I want to make sure we agree on the delivery date before we move on."
ES = "Perdón, ¿podrías repetir la última parte? Quiero asegurarme de que estamos de acuerdo con la fecha de entrega antes de continuar."
rows = {}
for f in files:
    m = re.match(r"(\w+)-(en|es)-(f|m)-([\w-]+)\.m4a", f)
    if not m: continue
    eng, lang, g, voice = m.groups()
    rows.setdefault(eng, []).append((lang, g, voice, f))
labels = {"apple": "Apple (built in, compact voices — the ones a fresh Mac has)",
          "openai": "OpenAI gpt-4o-mini-tts",
          "eleven": "ElevenLabs"}
order = ["openai", "eleven", "apple"]
parts = ["""<!doctype html><meta charset=utf-8><title>Speak voice test</title>
<style>
:root{--bg:#fff;--fg:#111;--mute:#666;--line:#e5e5e5;--card:#f7f7f7}
@media(prefers-color-scheme:dark){:root{--bg:#141414;--fg:#eee;--mute:#999;--line:#2a2a2a;--card:#1d1d1d}}
body{background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui;margin:0;padding:24px 16px;max-width:900px;margin-inline:auto}
h1{font-size:22px;margin:0 0 4px}p.sub{color:var(--mute);margin:0 0 24px}
h2{font-size:17px;margin:28px 0 10px;padding-top:16px;border-top:1px solid var(--line)}
table{width:100%;border-collapse:collapse}td{padding:8px 6px;vertical-align:middle;border-bottom:1px solid var(--line)}
td.v{width:120px;font-weight:600}td.g{width:60px;color:var(--mute)}audio{width:100%;height:36px}
blockquote{color:var(--mute);margin:0 0 18px;padding-left:12px;border-left:3px solid var(--line)}
</style>
<h1>Speak: which voice?</h1>
<p class=sub>Same two sentences in every voice. The far side of the call hears one of these.</p>
<blockquote>EN: __EN__<br>ES: __ES__</blockquote>""".replace("__EN__", html.escape(EN)).replace("__ES__", html.escape(ES))]
for eng in order + [e for e in rows if e not in order]:
    if eng not in rows: continue
    parts.append("<h2>%s</h2><table>" % html.escape(labels.get(eng, eng)))
    for lang in ("en", "es"):
        for lang_, g, voice, f in rows[eng]:
            if lang_ != lang: continue
            parts.append("<tr><td class=v>%s</td><td class=g>%s · %s</td><td><audio controls preload=none src='%s'></audio></td></tr>"
                         % (html.escape(voice), lang.upper(), "female" if g == "f" else "male", html.escape(f)))
    parts.append("</table>")
open(os.path.join(out, "index.html"), "w").write("\n".join(parts))
print("wrote", os.path.join(out, "index.html"), "with", len(files), "samples")
