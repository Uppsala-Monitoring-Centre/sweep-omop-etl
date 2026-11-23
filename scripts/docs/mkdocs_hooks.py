"""MkDocs hooks for the SWEEP OMOP ETL documentation site.

- Generates ``mapping_register.md`` at build time from
  ``docs/SWEEP_ETL_specification.xlsx``: one section per sheet, rendered as an
  HTML table that keeps the workbook's merged cells (rowspan/colspan).
- Rewrites links that leave ``docs/`` (e.g. ``../sql/omop/...``) to point at the
  file on GitHub, so they work on the website as well as in the repository view.

Nothing is written to disk: the register page exists only in the built site.
"""

from __future__ import annotations

import html
import re
from pathlib import Path

import openpyxl
from mkdocs.structure.files import File

WORKBOOK = "SWEEP_ETL_specification.xlsx"
REGISTER_PAGE = "mapping_register.md"
REPO_BLOB = "https://github.com/Uppsala-Monitoring-Centre/sweep-omop-etl/blob/main/"

_OUTSIDE_DOCS_LINK = re.compile(r"\]\(\.\./([^)\s]+)\)")


def _clean(value) -> str:
    if value is None:
        return ""
    text = str(value).replace("\xa0", " ").strip()
    return html.escape(text).replace("\n", "<br>")


def _used_extent(ws) -> tuple[int, int]:
    """Last row and column holding a value (sheets often report trailing blanks)."""
    last_row = last_col = 0
    for row in ws.iter_rows():
        for cell in row:
            if cell.value is not None and str(cell.value).strip():
                last_row = max(last_row, cell.row)
                last_col = max(last_col, cell.column)
    return last_row, last_col


def _sheet_table(ws) -> str:
    n_rows, n_cols = _used_extent(ws)
    if n_rows < 2:
        return "_No mapping rows documented in this sheet._"

    spans: dict[tuple[int, int], tuple[int, int]] = {}
    covered: set[tuple[int, int]] = set()
    for rng in ws.merged_cells.ranges:
        top, left = rng.min_row, rng.min_col
        bottom, right = min(rng.max_row, n_rows), min(rng.max_col, n_cols)
        if top > n_rows or left > n_cols:
            continue
        spans[(top, left)] = (bottom - top + 1, right - left + 1)
        covered.update(
            (r, c)
            for r in range(top, bottom + 1)
            for c in range(left, right + 1)
            if (r, c) != (top, left)
        )

    def cell_html(tag: str, r: int, c: int) -> str:
        rowspan, colspan = spans.get((r, c), (1, 1))
        attrs = (f' rowspan="{rowspan}"' if rowspan > 1 else "") + (
            f' colspan="{colspan}"' if colspan > 1 else ""
        )
        return f"<{tag}{attrs}>{_clean(ws.cell(r, c).value)}</{tag}>"

    header = "".join(cell_html("th", 1, c) for c in range(1, n_cols + 1) if (1, c) not in covered)
    body = []
    for r in range(2, n_rows + 1):
        cells = "".join(cell_html("td", r, c) for c in range(1, n_cols + 1) if (r, c) not in covered)
        if cells:
            body.append(f"<tr>{cells}</tr>")

    return (
        '<table class="spec-table">'
        f"<thead><tr>{header}</tr></thead>"
        f"<tbody>{''.join(body)}</tbody>"
        "</table>"
    )


def _register_markdown(workbook_path: Path) -> str:
    wb = openpyxl.load_workbook(workbook_path, data_only=True)
    parts = [
        "# Mapping register",
        "",
        "Field-level source-to-target mappings for each OMOP table, generated from "
        f"[`{WORKBOOK}`]({WORKBOOK}) (download the workbook for the original layout). "
        "The SQL under `sql/omop/` is the executable source of truth if the two differ.",
        "",
    ]
    for ws in wb.worksheets:
        parts += [f"## {ws.title}", "", _sheet_table(ws), ""]
    return "\n".join(parts)


def on_files(files, config):
    workbook_path = Path(config["docs_dir"]) / WORKBOOK
    files.append(
        File.generated(config, REGISTER_PAGE, content=_register_markdown(workbook_path))
    )
    return files


def on_page_markdown(markdown, page, config, files):
    return _OUTSIDE_DOCS_LINK.sub(lambda m: f"]({REPO_BLOB}{m.group(1)})", markdown)
