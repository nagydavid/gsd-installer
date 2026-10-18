#!/usr/bin/env python3
"""parse-pricing.py <models-and-pricing.html> <out.json>
Extracts the official GitHub Copilot model pricing table (per-token USD)
into [{model, category, tier, input, cached, output}]. Exits 1 if no rows."""
import re, html, json, sys

src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
rows = re.findall(r'<tr[^>]*>(.*?)</tr>', src, re.S)
out, seen = [], set()
for r in rows:
    cells = [re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', '', c)).strip())
             for c in re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', r, re.S)]
    if len(cells) < 4:
        continue
    if not any(x in ' '.join(cells) for x in ('GPT', 'Claude', 'Gemini', 'MAI', 'Kimi', 'Grok')):
        continue
    k = tuple(cells)
    if k in seen:
        continue
    seen.add(k)
    prices = [c for c in cells if re.match(r'^\$[\d.]+$', c)]
    cat = next((c for c in cells if c in ('Lightweight', 'Versatile', 'Powerful')), None)
    tier = next((c for c in cells if c in ('Default', 'Long context')), 'Default')
    if cat and len(prices) >= 2:
        out.append({
            "model": cells[0], "category": cat, "tier": tier,
            "input": float(prices[0].lstrip('$')),
            "cached": float(prices[1].lstrip('$')) if len(prices) > 1 else None,
            "output": float(prices[-1].lstrip('$')),
        })
if not out:
    sys.exit(1)
json.dump({"source": "live", "models": out}, open(sys.argv[2], 'w'))
