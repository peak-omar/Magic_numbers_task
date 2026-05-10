#!/usr/bin/env python3


from __future__ import annotations

import csv
import datetime as dt
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

ROOT     = Path(__file__).resolve().parent.parent
SRC_DIR  = ROOT / "src"
OUT_DIR  = ROOT / "reports"
DB_PATH  = ROOT / "annie.duckdb"
SQL_FILE = ROOT / "analysis" / "pipeline.sql"
DUCKDB   = ROOT / "bin" / "duckdb.exe"   # Windows in this environment


def _resolve_duckdb() -> str:
    if DUCKDB.exists():
        return str(DUCKDB)
    on_path = shutil.which("duckdb")
    if on_path:
        return on_path
    sys.exit(
        f"{DUCKDB} or put it on PATH."
    )


def _render_sql() -> str:

    sql = SQL_FILE.read_text(encoding="utf-8")
    # Forward slashes so the same SQL works on Windows and POSIX.
    sql = sql.replace("__SRC__", str(SRC_DIR).replace("\\", "/"))
    sql = sql.replace("__OUT__", str(OUT_DIR).replace("\\", "/"))
    return sql


def run_pipeline() -> str:
    OUT_DIR.mkdir(exist_ok=True)
    duckdb = _resolve_duckdb()
    sql = _render_sql()

    started = dt.datetime.now()
    print(f"[{started:%H:%M:%S}] running pipeline against {SRC_DIR} ...")

    # come back as parseable CSV.
    proc = subprocess.run(
        [duckdb, "-csv", "-header", str(DB_PATH)],
        input=sql,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        sys.exit(f"DuckDB failed with exit code {proc.returncode}")

    elapsed = (dt.datetime.now() - started).total_seconds()
    print(f"[done in {elapsed:5.1f}s]\n")
    return proc.stdout


def _parse_check_blocks(stdout: str) -> dict[str, dict[str, str]]:

    blocks: dict[str, dict[str, str]] = {}
    current_header: list[str] | None = None
    for raw in stdout.splitlines():
        if not raw.strip():
            continue
        row = next(csv.reader([raw]))
        if row and row[0] == "check_name":
            current_header = row
            continue
        if current_header is None:
            continue
        record = dict(zip(current_header, row))
        name = record.get("check_name")
        if name:
            blocks[name] = record
    return blocks


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _fmt_money(s: str | float | int) -> str:
    try:
        n = float(s)
    except (TypeError, ValueError):
        return str(s)
    return f"${n:,.0f}"


def _fmt_pct(s: str | float | int) -> str:
    try:
        return f"{float(s):.1f}%"
    except (TypeError, ValueError):
        return str(s)


def _md_table(rows: list[dict[str, str]], cols: list[tuple[str, str, str]]) -> str:
    if not rows:
        return "_(no rows)_\n"
    headers = [c[0] for c in cols]
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        cells = []
        for _, key, kind in cols:
            v = r.get(key, "")
            if kind == "money":
                cells.append(_fmt_money(v))
            elif kind == "pct":
                cells.append(_fmt_pct(v))
            elif kind == "int":
                try:
                    cells.append(f"{int(float(v)):,}")
                except (TypeError, ValueError):
                    cells.append(str(v))
            else:
                cells.append(str(v))
        out.append("| " + " | ".join(cells) + " |")
    return "\n".join(out) + "\n"


PRODUCT_COLS = [
    ("Brand",   "Brand",          "raw"),
    ("Size",    "Size",           "raw"),
    ("Product", "Description",    "raw"),
    ("Units",   "units_sold",     "int"),
    ("Revenue", "revenue",        "money"),
    ("COGS",    "cogs",           "money"),
    ("Net $",   "net_profit",     "money"),
    ("Net %",   "net_margin_pct", "pct"),
]

BRAND_COLS = [
    ("Brand",   "Brand",          "raw"),
    ("Example", "Description",    "raw"),
    ("Units",   "units_sold",     "int"),
    ("Revenue", "revenue",        "money"),
    ("COGS",    "cogs",           "money"),
    ("Net $",   "net_profit",     "money"),
    ("Net %",   "net_margin_pct", "pct"),
]


def render_report(checks: dict[str, dict[str, str]]) -> str:
    totals       = checks.get("company_totals", {})
    coverage     = checks.get("cost_coverage", {})
    rollforward  = checks.get("inventory_rollforward", {})

    md = []


    md.append("\n## 1. Top 10 products by profit ($)\n")
    md.append(_md_table(_read_csv(OUT_DIR / "top10_products_by_profit.csv"), PRODUCT_COLS))

    md.append("\n## 2. Top 10 products by margin (%) — minimum $10k revenue\n")
    md.append(_md_table(_read_csv(OUT_DIR / "top10_products_by_margin.csv"), PRODUCT_COLS))

    md.append("\n## 3. Top 10 brands by profit ($)\n")
    md.append(_md_table(_read_csv(OUT_DIR / "top10_brands_by_profit.csv"), BRAND_COLS))

    md.append("\n## 4. Top 10 brands by margin (%) — minimum $25k revenue\n")
    md.append(_md_table(_read_csv(OUT_DIR / "top10_brands_by_margin.csv"), BRAND_COLS))

    drop_products = _read_csv(OUT_DIR / "drop_candidates_products.csv")
    drop_brands   = _read_csv(OUT_DIR / "drop_candidates_brands.csv")

    md.append("\n## 5. Drop candidates\n")
    md.append(
        "These items lost money in 2016 with non-trivial volume "
        "(>= 12 units, >= $500 revenue for products; >= $1,000 revenue "
        "for brands).  SKUs whose cost we could not reconcile are excluded "
        "to avoid false positives.\n"
    )

    md.append(f"\n### Products to consider dropping ({len(drop_products)})\n")
    md.append(_md_table(drop_products[:25], PRODUCT_COLS))
    if len(drop_products) > 25:
        md.append(
            f"\n_...{len(drop_products) - 25} more rows in "
            "[drop_candidates_products.csv](drop_candidates_products.csv)._\n"
        )

    md.append(f"\n### Brands to consider dropping ({len(drop_brands)})\n")
    md.append(_md_table(drop_brands[:25], BRAND_COLS))
    if len(drop_brands) > 25:
        md.append(
            f"\n_...{len(drop_brands) - 25} more rows in "
            "[drop_candidates_brands.csv](drop_candidates_brands.csv)._\n"
        )

    md.append("\n## Sanity checks\n")
    if rollforward:
        md.append(textwrap.dedent(f"""
            **Inventory roll-forward at cost basis** —
            BegInv + Purchases - EndInv should approximate the COGS we
            computed per-SKU.  A small gap is expected (shrinkage, mid-year
            cost drift, the handful of unreconciled SKUs).

            | Component | Value |
            |-----------|------:|
            | Beginning inventory @ cost | {_fmt_money(rollforward.get('beg_inv_at_cost', 0))} |
            | Purchases @ cost           | {_fmt_money(rollforward.get('purchases_at_cost', 0))} |
            | Ending inventory @ cost    | {_fmt_money(rollforward.get('end_inv_at_cost', 0))} |
            | Implied COGS               | {_fmt_money(rollforward.get('implied_cogs', 0))} |
            | Computed COGS (per-SKU)    | {_fmt_money(rollforward.get('computed_cogs', 0))} |
            | Variance vs. roll-forward  | {_fmt_pct(rollforward.get('rollforward_variance_pct', 0))} |
        """).strip() + "\n")
    if coverage:
        md.append(textwrap.dedent(f"""

            **Cost-lookup coverage** — sales rows where we could not find a
            unit cost (these are excluded from drop-candidate lists, but
            are included in totals with COGS=0 — so totals slightly
            overstate profit):

            * Sales rows with missing cost: **{int(float(coverage.get('rows_missing_cost', 0))):,}**
              of {int(float(coverage.get('sales_rows', 0))):,}
              ({_fmt_pct(coverage.get('pct_rows_missing_cost', 0))})
            * Revenue with missing cost: **{_fmt_money(coverage.get('dollars_missing_cost', 0))}**
        """).strip() + "\n")

    return "".join(md)


def main():
    if not SRC_DIR.exists():
        sys.exit(f"input dir not found: {SRC_DIR}")
    if not SQL_FILE.exists():
        sys.exit(f"sql file not found: {SQL_FILE}")

    stdout = run_pipeline()
    checks = _parse_check_blocks(stdout)
    md     = render_report(checks)

    report_path = OUT_DIR / "REPORT.md"
    report_path.write_text(md, encoding="utf-8")
    print(f"wrote {report_path}")
    print(f"raw CSVs in {OUT_DIR}/")
    print()
    print("Sanity checks:")
    for name, row in checks.items():
        print(f"  - {name}: {row}")


if __name__ == "__main__":
    main()
