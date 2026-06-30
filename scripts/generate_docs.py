#!/usr/bin/env python3
"""Generate docs.json and index.html from Hammerspoon-style docstrings in init.lua."""

import json
import re
import sys
from datetime import date
from html import escape as h
from pathlib import Path

REPO_URL = "https://github.com/hugoh/AudioPilot.spoon"


def extract_blocks(source: str) -> list[list[str]]:
    """Return a list of docstring blocks; each block is a list of content lines."""
    blocks: list[list[str]] = []
    current: list[str] = []

    for raw_line in source.splitlines():
        line = raw_line.rstrip()
        if line.startswith("---"):
            content = line[3:]
            if content.startswith(" "):
                content = content[1:]
            current.append(content)
        else:
            if current:
                blocks.append(current)
                current = []

    if current:
        blocks.append(current)

    return blocks


_ITEM_TYPES = frozenset(("Method", "Variable", "Function", "Constructor", "Field"))


def parse_sections(body: list[str]) -> dict:
    """Parse a block body into desc, parameters, returns, and notes."""
    desc_lines: list[str] = []
    parameters: list[str] = []
    returns: list[str] = []
    notes: list[str] = []
    current: list[str] = desc_lines
    past_type = False

    for line in body:
        stripped = line.strip()

        if not past_type:
            if stripped in _ITEM_TYPES:
                past_type = True
                continue
            if stripped == "":
                continue
            past_type = True  # no explicit type line; start collecting desc

        if stripped == "Parameters:":
            current = parameters
        elif stripped == "Returns:":
            current = returns
        elif stripped == "Notes:":
            current = notes
        elif stripped.startswith("* "):
            current.append(stripped[2:])
        elif current is desc_lines:
            if stripped or desc_lines:
                desc_lines.append(line.strip())

    return {
        "desc": " ".join(desc_lines).strip(),
        "parameters": parameters,
        "returns": returns,
        "notes": notes,
    }


def parse_module(blocks: list[list[str]]) -> dict:
    """Parse all blocks into a structured module dict."""
    module: dict = {"name": "", "desc": "", "doc": "", "items": []}

    for block in blocks:
        if not block:
            continue
        first = block[0]

        m = re.match(r"^=== (\w+) ===$", first)
        if m:
            module["name"] = m.group(1)
            body = block[1:]
            module["doc"] = "\n".join(body).strip()
            for line in body:
                if line.strip():
                    module["desc"] = line.strip()
                    break
            continue

        m = re.match(r"^(\w+)[.:](\w+)", first)
        if not m:
            continue

        item_name = re.split(r"[(\s]", m.group(2))[0]
        body = block[1:]

        item_type = "Method"
        for line in body:
            s = line.strip()
            if s in _ITEM_TYPES:
                item_type = s
                break
            if s:
                break

        sections = parse_sections(body)

        module["items"].append(
            {
                "name": item_name,
                "type": item_type,
                "signature": first,
                "desc": sections["desc"],
                "doc": "\n".join(body).strip(),
                "parameters": sections["parameters"],
                "returns": sections["returns"],
                "notes": sections["notes"],
            }
        )

    return module


def to_json(module: dict) -> str:
    payload = [
        {
            "name": module["name"],
            "type": "Module",
            "desc": module["desc"],
            "doc": module["doc"],
            "items": [
                {
                    "name": item["name"],
                    "type": item["type"],
                    "signature": item["signature"],
                    "def": item["signature"],
                    "desc": item["desc"],
                    "doc": item["doc"],
                    "parameters": item["parameters"],
                    "returns": item["returns"],
                    "notes": item["notes"],
                }
                for item in module["items"]
            ],
        }
    ]
    return json.dumps(payload, indent=2)


_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{name} — Hammerspoon Spoon</title>
<style>
  :root {{
    --fg: #1a1a1a; --bg: #fff; --accent: #2563eb;
    --border: #e5e7eb; --muted-bg: #f3f4f6; --code-bg: #f8f8f8;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --fg: #e5e7eb; --bg: #111; --accent: #60a5fa;
             --border: #374151; --muted-bg: #1f2937; --code-bg: #1a1a1a; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ font: 16px/1.6 system-ui, sans-serif; color: var(--fg); background: var(--bg);
          max-width: 860px; margin: 0 auto; padding: 2rem 1.5rem; }}
  h1 {{ font-size: 1.8rem; margin-bottom: .25rem; }}
  .subtitle {{ color: #6b7280; margin-top: 0; }}
  nav {{ margin: 1.5rem 0; display: flex; gap: 1rem; flex-wrap: wrap; }}
  nav a {{ color: var(--accent); text-decoration: none; }}
  nav a:hover {{ text-decoration: underline; }}
  hr {{ border: none; border-top: 1px solid var(--border); margin: 2rem 0; }}
  h2 {{ font-size: 1.1rem; font-weight: 600; text-transform: uppercase;
        letter-spacing: .06em; color: #6b7280; margin: 2.5rem 0 .75rem; }}
  .item {{ border: 1px solid var(--border); border-radius: 6px; margin-bottom: 1.25rem; overflow: hidden; }}
  .item-header {{ display: flex; align-items: baseline; gap: .75rem;
                  padding: .6rem 1rem; background: var(--muted-bg);
                  border-bottom: 1px solid var(--border); }}
  .item-name {{ font-weight: 600; font-size: 1rem; }}
  .item-body {{ padding: .75rem 1rem; }}
  .sig {{ font-family: monospace; font-size: .875rem; background: var(--code-bg);
          border: 1px solid var(--border); border-radius: 4px;
          padding: .4rem .75rem; margin: .25rem 0 .75rem; white-space: pre-wrap; overflow-wrap: break-word; }}
  .section-label {{ font-weight: 600; font-size: .85rem; margin: .75rem 0 .2rem; }}
  ul.params {{ margin: .25rem 0 0; padding-left: 1.25rem; }}
  ul.params li {{ margin: .15rem 0; font-size: .95rem; }}
  footer {{ margin-top: 3rem; font-size: .85rem; color: #6b7280; text-align: center; }}
  footer a {{ color: var(--accent); }}
</style>
</head>
<body>
<h1>{name}</h1>
<p class="subtitle">{desc}</p>
<nav>
  <a href="{repo_url}">GitHub</a>
  <a href="{repo_url}/releases/latest">Latest release</a>
</nav>
<hr>
{body}
<footer>
  Generated {today} &mdash; <a href="{repo_url}">{repo_url}</a>
</footer>
</body>
</html>
"""


def _list_html(label: str, items: list[str]) -> str:
    if not items:
        return ""
    lis = "\n".join(f"      <li>{h(item)}</li>" for item in items)
    return (
        f'    <p class="section-label">{label}</p>\n'
        f'    <ul class="params">\n{lis}\n    </ul>\n'
    )


def to_html(module: dict) -> str:
    by_type: dict[str, list] = {}
    for item in module["items"]:
        by_type.setdefault(item["type"], []).append(item)

    sections: list[str] = []
    for type_name in ("Variable", "Field", "Method", "Function", "Constructor"):
        group = by_type.get(type_name)
        if not group:
            continue
        sections.append(f"<h2>{type_name}s</h2>")
        for item in group:
            params = _list_html("Parameters", item["parameters"])
            returns = _list_html("Returns", item["returns"])
            sections.append(
                f'<div class="item" id="{h(item["name"])}">\n'
                f'  <div class="item-header">'
                f'<span class="item-name">{h(item["name"])}</span>'
                f"</div>\n"
                f'  <div class="item-body">\n'
                f'    <div class="sig">{h(item["signature"])}</div>\n'
                f"    <p>{h(item['desc'])}</p>\n"
                f"{params}"
                f"{returns}"
                f"  </div>\n"
                f"</div>"
            )

    return _HTML.format(
        name=h(module["name"]),
        desc=h(module["desc"]),
        repo_url=REPO_URL,
        today=date.today().isoformat(),
        body="\n".join(sections),
    )


def main() -> None:
    repo_root = Path(__file__).parent.parent
    lua_file = repo_root / "init.lua"
    out_dir = repo_root / "docs"
    out_dir.mkdir(exist_ok=True)

    source = lua_file.read_text()
    blocks = extract_blocks(source)
    module = parse_module(blocks)

    if not module["name"]:
        print("ERROR: No module header (=== Name ===) found in init.lua", file=sys.stderr)
        sys.exit(1)

    json_path = out_dir / "docs.json"
    json_path.write_text(to_json(module))
    print(f"Wrote {json_path}")

    html_path = out_dir / "index.html"
    html_path.write_text(to_html(module))
    print(f"Wrote {html_path}")


if __name__ == "__main__":
    main()
