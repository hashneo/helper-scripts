#!/usr/bin/env python3
"""
md-to-pdf.py

Convert one or more Markdown files to styled PDFs using md-to-pdf (via npx).
Mermaid diagrams are pre-rendered to PNG via @mermaid-js/mermaid-cli and
substituted inline before PDF generation.

Usage:
    # Single file
    python3 md-to-pdf.py README.md

    # Prefix match inside a directory (finds docs/adr-009-*.md)
    python3 md-to-pdf.py adr-009 --docs-dir ./docs

    # All markdown files in a directory tree
    python3 md-to-pdf.py --all --docs-dir ./docs

    # Explicit output directory
    python3 md-to-pdf.py notes.md --out ./output

Output: <out-dir>/<stem>.pdf   (default out-dir: ./pdf)

Dependencies (resolved via npx — no global install required):
    npx md-to-pdf
    npx @mermaid-js/mermaid-cli
"""

from __future__ import annotations

import argparse
import base64
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import List, Optional

# ── Default styling ────────────────────────────────────────────────────────────

LAUNCH_CONFIG = """{
  "launch_options": {
    "args": ["--no-sandbox", "--disable-setuid-sandbox"]
  },
  "pdf_options": {
    "format": "A4",
    "margin": {
      "top": "20mm",
      "bottom": "20mm",
      "left": "20mm",
      "right": "20mm"
    },
    "printBackground": true
  },
  "stylesheet_encoding": "utf-8",
  "highlight_style": "github",
  "body_class": "markdown-body",
  "css": "body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; font-size: 13px; line-height: 1.6; } h1 { border-bottom: 2px solid #333; padding-bottom: 8px; } h2 { border-bottom: 1px solid #e1e4e8; padding-bottom: 4px; } table { border-collapse: collapse; width: 100%; } th, td { border: 1px solid #d0d7de; padding: 6px 12px; } th { background: #f6f8fa; font-weight: 600; } code { background: #f6f8fa; padding: 2px 4px; border-radius: 3px; font-size: 12px; } pre { background: #f6f8fa; padding: 12px; border-radius: 6px; overflow-x: auto; } blockquote { border-left: 4px solid #555; margin: 0; padding-left: 16px; color: #57606a; } strong { color: #0a0a0a; } img { max-width: 100%; height: auto; display: block; margin: 16px auto; }"
}
"""

# ── Mermaid rendering ──────────────────────────────────────────────────────────

def _run_mermaid(
    src_file: Path,
    png_file: Path,
    extra_flags: Optional[List[str]] = None,
) -> subprocess.CompletedProcess:
    """Invoke @mermaid-js/mermaid-cli to render src_file → png_file."""
    cmd = [
        "npx", "--yes", "@mermaid-js/mermaid-cli",
        "-i", str(src_file),
        "-o", str(png_file),
        "--backgroundColor", "white",
        "--width", "1400",
    ]
    if extra_flags:
        cmd.extend(extra_flags)
    return subprocess.run(cmd, capture_output=True, text=True)


def render_mermaid_blocks(md_text: str, work_dir: Path) -> str:
    """
    Find all ```mermaid ... ``` fenced blocks, render each to PNG, and replace
    the block with a Markdown image reference pointing at the PNG.

    If the first render attempt fails, retries once with --quiet to suppress
    mermaid internal warnings that can cause puppeteer evaluation errors.
    Falls back to leaving the raw fenced block in place when both attempts fail.
    """
    pattern = re.compile(r"```mermaid\s*\n(.*?)```", re.DOTALL)
    counter = [0]

    def replace_block(match: re.Match) -> str:
        counter[0] += 1
        n = counter[0]
        diagram_src = match.group(1).strip()
        src_file = work_dir / f"mermaid-{n}.mmd"
        png_file  = work_dir / f"mermaid-{n}.png"

        src_file.write_text(diagram_src, encoding="utf-8")

        result = _run_mermaid(src_file, png_file)
        if result.returncode != 0:
            png_file.unlink(missing_ok=True)
            result = _run_mermaid(src_file, png_file, extra_flags=["--quiet"])

        if result.returncode != 0 or not png_file.exists():
            first_error = next(
                (l for l in result.stderr.splitlines() if l.strip() and not l.startswith(" ")),
                result.stderr.splitlines()[0] if result.stderr.strip() else "unknown error",
            )
            print(
                f"  WARNING: Mermaid block {n} failed to render — leaving as code block.\n"
                f"           {first_error}",
                file=sys.stderr,
            )
            return match.group(0)

        print(f"  Rendered: mermaid block {n} → {png_file.name}")
        # Embed as a base64 data URI so Chromium/Puppeteer (used by md-to-pdf)
        # never needs local file access — the image travels inline in the HTML.
        b64 = base64.b64encode(png_file.read_bytes()).decode("ascii")
        return f"![](data:image/png;base64,{b64})"

    return pattern.sub(replace_block, md_text)


# ── Doc resolution ─────────────────────────────────────────────────────────────

def resolve_input(target: str, docs_dir: Path) -> Path:
    """
    Resolve a target string to an absolute .md file path.

    Resolution order:
      1. Absolute path or relative path to an existing .md file.
      2. Relative path from the current working directory.
      3. Prefix match anywhere under docs_dir (e.g. "adr-009", "chapter-1").
         Raises FileNotFoundError when the prefix is ambiguous or unmatched.
    """
    p = Path(target)

    # Direct file path
    if p.suffix == ".md" and p.is_file():
        return p.resolve()

    # Relative to cwd
    cwd_relative = Path.cwd() / target
    if cwd_relative.exists():
        if cwd_relative.is_file() and cwd_relative.suffix == ".md":
            return cwd_relative.resolve()
        raise ValueError(f"Path exists but is not a .md file: {cwd_relative}")

    # Prefix match under docs_dir
    matches = sorted(docs_dir.rglob(f"{target}*.md"))
    if len(matches) == 1:
        return matches[0].resolve()
    if len(matches) > 1:
        # Prefer an exact stem match before reporting ambiguity
        exact = [m for m in matches if m.stem == target]
        if len(exact) == 1:
            return exact[0].resolve()
        candidates = "\n".join(f"  - {m}" for m in matches)
        raise FileNotFoundError(
            f"Ambiguous prefix {target!r} — multiple matches:\n{candidates}\n"
            f"Provide a more specific prefix or an explicit file path."
        )

    raise FileNotFoundError(
        f"Cannot resolve {target!r} — no match in {docs_dir}/**/{target}*.md"
    )


# ── PDF export ─────────────────────────────────────────────────────────────────

def export(md_path: Path, out_dir: Path, config_path: Path) -> Path:
    """
    Pre-render Mermaid diagrams, write processed Markdown to a temp directory,
    run md-to-pdf, and move the result to out_dir.

    Returns the output PDF path.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / (md_path.stem + ".pdf")

    with tempfile.TemporaryDirectory() as tmp:
        work_dir = Path(tmp)

        md_text = md_path.read_text(encoding="utf-8")
        md_text = render_mermaid_blocks(md_text, work_dir)

        tmp_md = work_dir / md_path.name
        tmp_md.write_text(md_text, encoding="utf-8")

        source_pdf = tmp_md.with_suffix(".pdf")
        cmd = [
            "npx", "--yes", "md-to-pdf",
            "--config-file", str(config_path),
            str(tmp_md),
        ]

        print(f"  Exporting: {md_path}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  ERROR:\n{result.stderr}", file=sys.stderr)
            sys.exit(1)

        out_path.unlink(missing_ok=True)
        shutil.move(str(source_pdf), str(out_path))

    print(f"  Written:   {out_path}")
    return out_path


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert Markdown file(s) to styled PDF via md-to-pdf.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "target",
        nargs="?",
        help="Markdown file path or filename prefix (e.g. adr-009, README)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Export every .md file found under --docs-dir",
    )
    parser.add_argument(
        "--docs-dir",
        default=".",
        metavar="DIR",
        help="Directory to search when resolving prefixes or --all (default: .)",
    )
    parser.add_argument(
        "--out",
        default="./pdf",
        metavar="DIR",
        help="Output directory for generated PDFs (default: ./pdf)",
    )
    args = parser.parse_args()

    if not args.all and not args.target:
        parser.error("Provide a target file/prefix or use --all.")

    docs_dir = Path(args.docs_dir).resolve()
    out_dir  = Path(args.out).resolve()

    if not docs_dir.is_dir():
        parser.error(f"--docs-dir does not exist: {docs_dir}")

    # Write launch config to a temp file so it doesn't pollute the working dir
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as f:
        f.write(LAUNCH_CONFIG)
        config_path = Path(f.name)

    try:
        if args.all:
            docs = sorted(docs_dir.rglob("*.md"))
            if not docs:
                print(f"No .md files found under {docs_dir}.", file=sys.stderr)
                sys.exit(1)
            print(f"Exporting {len(docs)} file(s) → {out_dir}/\n")
            for md in docs:
                export(md, out_dir, config_path)
            print(f"\nDone. {len(docs)} PDF(s) written to {out_dir}/")
        else:
            md_path = resolve_input(args.target, docs_dir)
            print(f"Exporting → {out_dir}/\n")
            out = export(md_path, out_dir, config_path)
            print(f"\nDone. Output:\n  {out}")
    finally:
        config_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
