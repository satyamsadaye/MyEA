#!/usr/bin/env python3
"""
Local MT5 report hub.

Open a browser UI for:
- converting randomEA Strategy Tester HTML reports into copier trade tapes
- copying the generated CSV into the MT5 Common Files folder
- comparing two MT5 HTML reports side by side

No third-party packages are required.
"""

from __future__ import annotations

import csv
import html
import json
import os
import shutil
import sys
import time
import zipfile
from dataclasses import asdict
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from mt5_report_to_trade_tape import (
    TableRowParser,
    build_completed_trades,
    build_tape,
    extract_sections,
    parse_deal,
    parse_order,
)


ROOT = Path(__file__).resolve().parent
HUB_DIR = ROOT / "mt5_report_hub_data"
UPLOADS_DIR = HUB_DIR / "uploads"
TAPES_DIR = HUB_DIR / "tapes"


def common_files_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"
    return HUB_DIR / "Common" / "Files"


def safe_name(name: str, fallback: str = "report.html") -> str:
    clean = "".join(ch if ch.isalnum() or ch in " ._-()" else "_" for ch in name)
    clean = clean.strip(" .")
    return clean or fallback


def parse_content_disposition(value: str) -> dict[str, str]:
    result: dict[str, str] = {}
    parts = [part.strip() for part in value.split(";")]
    if parts:
        result["type"] = parts[0].lower()
    for part in parts[1:]:
        if "=" not in part:
            continue
        key, raw = part.split("=", 1)
        raw = raw.strip()
        if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
            raw = raw[1:-1]
        result[key.strip().lower()] = raw
    return result


def parse_multipart(headers, body: bytes) -> dict[str, dict]:
    content_type = headers.get("Content-Type", "")
    marker = "boundary="
    if marker not in content_type:
        raise ValueError("Upload is missing multipart boundary.")

    boundary = content_type.split(marker, 1)[1].strip()
    if boundary.startswith('"') and boundary.endswith('"'):
        boundary = boundary[1:-1]
    boundary_bytes = ("--" + boundary).encode("utf-8")

    fields: dict[str, dict] = {}
    for raw_part in body.split(boundary_bytes):
        raw_part = raw_part.strip()
        if not raw_part or raw_part == b"--":
            continue
        if raw_part.endswith(b"--"):
            raw_part = raw_part[:-2].strip()

        header_blob, sep, payload = raw_part.partition(b"\r\n\r\n")
        if not sep:
            header_blob, sep, payload = raw_part.partition(b"\n\n")
        if not sep:
            continue

        part_headers: dict[str, str] = {}
        for line in header_blob.decode("utf-8", errors="ignore").splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            part_headers[key.strip().lower()] = value.strip()

        disposition = parse_content_disposition(part_headers.get("content-disposition", ""))
        name = disposition.get("name", "")
        if not name:
            continue

        if payload.endswith(b"\r\n"):
            payload = payload[:-2]
        elif payload.endswith(b"\n"):
            payload = payload[:-1]

        fields[name] = {
            "filename": disposition.get("filename", ""),
            "data": payload,
            "value": payload.decode("utf-8", errors="ignore"),
            "headers": part_headers,
        }

    return fields


def read_report_rows(path: Path) -> list[list[str]]:
    raw = path.read_bytes()
    for enc in ("utf-16", "utf-8", "cp1252"):
        try:
            text = raw.decode(enc)
            parser = TableRowParser()
            parser.feed(text)
            if parser.rows:
                return parser.rows
        except UnicodeDecodeError:
            continue
    text = raw.decode("utf-8", errors="ignore")
    parser = TableRowParser()
    parser.feed(text)
    return parser.rows


def parse_float(value: str) -> float | None:
    text = value.strip().replace(" ", "").replace("%", "")
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def find_setting(rows: list[list[str]], label: str) -> str:
    for row in rows:
        for i, cell in enumerate(row[:-1]):
            if cell == label:
                return row[i + 1].strip()
    return ""


def collect_metrics(rows: list[list[str]]) -> dict[str, str]:
    wanted = {
        "Total Net Profit",
        "Gross Profit",
        "Gross Loss",
        "Profit Factor",
        "Expected Payoff",
        "Total Trades",
        "Total Deals",
        "Balance Drawdown Absolute",
        "Balance Drawdown Maximal",
        "Balance Drawdown Relative",
        "Equity Drawdown Absolute",
        "Equity Drawdown Maximal",
        "Equity Drawdown Relative",
        "Profit Trades (% of total)",
        "Loss Trades (% of total)",
        "Short Trades (won %)",
        "Long Trades (won %)",
    }
    metrics: dict[str, str] = {}
    for row in rows:
        for i, cell in enumerate(row[:-1]):
            key = cell.strip().rstrip(":")
            if key in wanted and i + 1 < len(row):
                metrics[key] = row[i + 1].strip()
    return metrics


def money(value: float, currency: str = "USD") -> str:
    sign = "+" if value > 0 else ""
    return f"{sign}{value:.2f} {currency}"


def excel_column_name(index: int) -> str:
    name = ""
    while index > 0:
        index, remainder = divmod(index - 1, 26)
        name = chr(65 + remainder) + name
    return name


def xlsx_cell_xml(row: int, col: int, value) -> str:
    ref = f"{excel_column_name(col)}{row}"
    text = "" if value is None else str(value)
    numeric = False
    if text:
        try:
            float(text)
            numeric = text.strip() == text and not any(ch in text for ch in " :|,")
        except ValueError:
            numeric = False

    if numeric:
        return f'<c r="{ref}"><v>{html.escape(text)}</v></c>'

    escaped = html.escape(text, quote=False)
    return f'<c r="{ref}" t="inlineStr"><is><t>{escaped}</t></is></c>'


def write_xlsx(path: Path, rows: list[dict[str, str]], sheet_name: str = "Trade Tape") -> None:
    if not rows:
        return

    headers = list(rows[0].keys())
    sheet_rows = []
    sheet_rows.append(
        '<row r="1">' +
        "".join(xlsx_cell_xml(1, col + 1, header) for col, header in enumerate(headers)) +
        "</row>"
    )
    for row_index, item in enumerate(rows, start=2):
        sheet_rows.append(
            f'<row r="{row_index}">' +
            "".join(xlsx_cell_xml(row_index, col + 1, item.get(header, "")) for col, header in enumerate(headers)) +
            "</row>"
        )

    last_col = excel_column_name(len(headers))
    dimension = f"A1:{last_col}{len(rows) + 1}"
    worksheet = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <dimension ref="{dimension}"/>
  <sheetViews><sheetView workbookViewId="0"/></sheetViews>
  <sheetFormatPr defaultRowHeight="15"/>
  <sheetData>
    {''.join(sheet_rows)}
  </sheetData>
  <autoFilter ref="{dimension}"/>
</worksheet>'''

    workbook = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="{html.escape(sheet_name, quote=True)}" sheetId="1" r:id="rId1"/></sheets>
</workbook>'''

    rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>'''
    workbook_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>'''
    content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>'''

    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", rels)
        zf.writestr("xl/workbook.xml", workbook)
        zf.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        zf.writestr("xl/worksheets/sheet1.xml", worksheet)


def ratio_text(value: float | None, suffix: str = "") -> str:
    if value is None:
        return "n/a"
    if value >= 999:
        return "infinite"
    return f"{value:.2f}{suffix}"


def short_dt(value: str) -> str:
    try:
        dt = datetime.strptime(value, "%Y.%m.%d %H:%M:%S")
        return dt.strftime("%m/%d %H:%M")
    except ValueError:
        return value


def build_closed_trades(deals) -> list[dict]:
    trades = []
    for trade in build_completed_trades(deals):
        entry = trade["entry"]
        exit_deal = trade["exit"]
        if exit_deal is None:
            continue

        trades.append(
            {
                "entryTime": entry.time,
                "closeTime": exit_deal.time,
                "symbol": entry.symbol,
                "side": entry.type.title(),
                "entryPrice": entry.price,
                "exitPrice": round(trade["weighted_exit_price"], 8),
                "volume": entry.volume,
                "closedVolume": round(trade["closed_volume"], 8),
                "net": trade["net"],
                "partialCloses": trade["partial_closes"],
                "exitDeals": ",".join(trade["exit_deals"]),
                "comment": " | ".join(trade["exit_comments"]),
            }
        )
    return trades


def streak_stats(trades: list[dict], be_threshold: float = 0.0) -> dict:
    streak_type = 0
    streak_len = 0
    max_win = max_loss = 0
    win_count = loss_count = 0
    win_sum = loss_sum = 0

    def finish(kind: int, length: int):
        nonlocal max_win, max_loss, win_count, loss_count, win_sum, loss_sum
        if length <= 0:
            return
        if kind > 0:
            max_win = max(max_win, length)
            win_count += 1
            win_sum += length
        elif kind < 0:
            max_loss = max(max_loss, length)
            loss_count += 1
            loss_sum += length

    for trade in trades:
        net = trade["net"]
        outcome = 1 if net > be_threshold else (-1 if net < -be_threshold else 0)
        if outcome == 0:
            finish(streak_type, streak_len)
            streak_type = 0
            streak_len = 0
            continue
        if outcome == streak_type:
            streak_len += 1
        else:
            finish(streak_type, streak_len)
            streak_type = outcome
            streak_len = 1

    active_type = streak_type
    active_len = streak_len
    finish(streak_type, streak_len)

    current_text = "none"
    if active_type > 0:
        current_text = f"{active_len} wins"
    elif active_type < 0:
        current_text = f"{active_len} losses"

    return {
        "current": current_text,
        "winStreaks": win_count,
        "maxWinStreak": max_win,
        "avgWinStreak": round(win_sum / win_count, 1) if win_count else 0,
        "lossStreaks": loss_count,
        "maxLossStreak": max_loss,
        "avgLossStreak": round(loss_sum / loss_count, 1) if loss_count else 0,
    }


def advanced_stats(deals, metrics: dict[str, str], be_abs_threshold: float = 10.0, be_loss_fraction: float = 0.20) -> dict:
    trades = build_closed_trades(deals)
    count = len(trades)
    raw_losses = [abs(t["net"]) for t in trades if t["net"] < 0]
    avg_loss_for_be = sum(raw_losses) / len(raw_losses) if raw_losses else 0.0
    dynamic_be = avg_loss_for_be * be_loss_fraction if avg_loss_for_be > 0 else 0.0
    be_threshold = max(be_abs_threshold, dynamic_be)
    wins_list = [t for t in trades if t["net"] > be_threshold]
    losses_list = [t for t in trades if t["net"] < -be_threshold]
    be_list = [t for t in trades if -be_threshold <= t["net"] <= be_threshold]
    wins = len(wins_list)
    losses = len(losses_list)
    breakevens = len(be_list)
    decisive = wins + losses

    gross_profit = sum(t["net"] for t in wins_list)
    gross_loss_abs = abs(sum(t["net"] for t in losses_list))
    net = sum(t["net"] for t in trades)
    avg_win = gross_profit / wins if wins else 0.0
    avg_loss = gross_loss_abs / losses if losses else 0.0
    average_pnl = net / count if count else 0.0
    expectancy = net / decisive if decisive else 0.0
    profit_factor = gross_profit / gross_loss_abs if gross_loss_abs else (999.0 if gross_profit > 0 else 0.0)
    payoff_ratio = avg_win / avg_loss if avg_loss else (999.0 if avg_win > 0 else 0.0)
    win_rate = 100.0 * wins / count if count else 0.0
    win_rate_ex_be = 100.0 * wins / decisive if decisive else 0.0
    breakeven_win_rate = (100.0 / (1.0 + payoff_ratio)) if payoff_ratio > 0.0 else 0.0
    edge_percent = win_rate_ex_be - breakeven_win_rate if decisive else 0.0
    avg_realized_r = average_pnl / avg_loss if avg_loss else (999.0 if average_pnl > 0 else 0.0)
    net_gross_loss_r = net / gross_loss_abs if gross_loss_abs else (999.0 if net > 0 else 0.0)

    best = max(trades, key=lambda t: t["net"], default=None)
    worst = min(trades, key=lambda t: t["net"], default=None)

    balance_values = [d.balance for d in deals if d.balance > 0]
    starting_balance = balance_values[0] if balance_values else 0.0
    current_balance = balance_values[-1] if balance_values else 0.0
    balance_change = current_balance - starting_balance if balance_values else net
    balance_change_pct = (balance_change / starting_balance * 100.0) if starting_balance else 0.0

    return {
        "account": {
            "sequenceStart": trades[0]["entryTime"] if trades else "",
            "startingBalance": round(starting_balance, 2),
            "currentBalance": round(current_balance, 2),
            "balanceChange": round(balance_change, 2),
            "balanceChangePct": round(balance_change_pct, 2),
            "closedPnl": round(net, 2),
        },
        "performance": {
            "outcome": "Net profit" if net > 0 else ("Net loss" if net < 0 else "Flat"),
            "netPnl": round(net, 2),
            "closedTrades": count,
            "wins": wins,
            "losses": losses,
            "breakevens": breakevens,
            "winRate": round(win_rate, 1),
            "winRateExBe": round(win_rate_ex_be, 1),
            "breakevenWinRate": round(breakeven_win_rate, 1),
            "edgePercent": round(edge_percent, 1),
            "averagePnl": round(average_pnl, 2),
            "averageWin": round(avg_win, 2),
            "averageLoss": round(-avg_loss, 2),
            "payoffRatio": ratio_text(payoff_ratio, ":1"),
            "expectancyExBe": round(expectancy, 2),
            "bestTrade": best,
            "worstTrade": worst,
            "breakevenThreshold": round(be_threshold, 2),
            "breakevenRule": f"+/- max({be_abs_threshold:.2f}, {be_loss_fraction:.0%} of avg raw loss)",
        },
        "streaks": streak_stats(trades, be_threshold),
        "risk": {
            "avgRealizedR": ratio_text(avg_realized_r, "R"),
            "netGrossLossR": ratio_text(net_gross_loss_r, "R"),
            "profitFactor": ratio_text(profit_factor),
            "grossProfit": round(gross_profit, 2),
            "grossLoss": round(-gross_loss_abs, 2),
        },
        "closedTrades": trades[:1500],
    }


def report_summary(path: Path) -> dict:
    rows = read_report_rows(path)
    order_rows, deal_rows = extract_sections(rows)
    deals = [deal for row in deal_rows if (deal := parse_deal(row)) is not None]

    balance_curve = [
        {"time": deal.time, "balance": deal.balance}
        for deal in deals
        if deal.balance > 0
    ]
    trade_deals = [deal for deal in deals if deal.symbol and deal.direction in {"in", "out", "inout", "out by"}]
    metrics = collect_metrics(rows)
    closed_deals = [deal for deal in deals if deal.direction in {"out", "inout", "out by"}]

    wins = sum(1 for d in closed_deals if d.profit + d.swap + d.commission >= 0)
    losses = sum(1 for d in closed_deals if d.profit + d.swap + d.commission < 0)
    net = sum(d.profit + d.swap + d.commission for d in closed_deals)

    return {
        "file": path.name,
        "expert": find_setting(rows, "Expert:"),
        "symbol": find_setting(rows, "Symbol:"),
        "period": find_setting(rows, "Period:"),
        "metrics": metrics,
        "advanced": advanced_stats(deals, metrics),
        "derived": {
            "closedDeals": len(closed_deals),
            "wins": wins,
            "losses": losses,
            "winRate": round((wins / len(closed_deals)) * 100, 2) if closed_deals else 0,
            "netClosedProfit": round(net, 2),
        },
        "balanceCurve": balance_curve,
        "deals": [asdict(d) for d in trade_deals[:1500]],
        "dealCount": len(trade_deals),
        "ordersCount": len(order_rows),
    }


def convert_report_to_tape(report_path: Path, output_name: str) -> dict:
    rows = read_report_rows(report_path)
    order_rows, deal_rows = extract_sections(rows)
    orders = [parse_order(row) for row in order_rows]
    deals = [deal for row in deal_rows if (deal := parse_deal(row)) is not None]
    tape = build_tape(orders, deals)
    if not tape:
        raise ValueError("No completed trades found in the report Deals table.")

    TAPES_DIR.mkdir(parents=True, exist_ok=True)
    output_path = TAPES_DIR / safe_name(output_name, "randomEA_trade_tape.csv")
    if output_path.suffix.lower() != ".csv":
        output_path = output_path.with_suffix(".csv")

    with output_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(tape[0].keys()), delimiter=";")
        writer.writeheader()
        writer.writerows(tape)

    excel_path = output_path.with_suffix(".xlsx")
    write_xlsx(excel_path, tape, "Trade Tape")

    common_dir = common_files_dir()
    common_dir.mkdir(parents=True, exist_ok=True)
    common_path = common_dir / output_path.name
    shutil.copy2(output_path, common_path)

    return {
        "rows": len(tape),
        "tapePath": str(output_path),
        "excelPath": str(excel_path),
        "commonPath": str(common_path),
        "tradeTapeFileName": output_path.name,
    }


HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MT5 Report Hub</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --panel: #ffffff;
      --line: #d8dde8;
      --ink: #182033;
      --muted: #607087;
      --accent: #0f766e;
      --violet: #665cff;
      --accent-2: #334155;
      --bad: #b42318;
      --good: #067647;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Segoe UI, Arial, sans-serif;
      background: var(--bg);
      color: var(--ink);
      font-size: 14px;
    }
    header {
      height: 56px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 18px;
      border-bottom: 1px solid var(--line);
      background: #fff;
      position: sticky;
      top: 0;
      z-index: 2;
    }
    h1 { font-size: 18px; margin: 0; font-weight: 650; }
    main { max-width: 1500px; margin: 0 auto; padding: 16px; }
    .grid { display: grid; grid-template-columns: 1fr; gap: 14px; align-items: start; }
    .top-tools { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; align-items: stretch; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
    }
    .panel h2 { margin: 0 0 10px; font-size: 14px; }
    .drop {
      border: 1px dashed #94a3b8;
      border-radius: 8px;
      min-height: 104px;
      display: flex;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 12px;
      color: var(--muted);
      background: #f8fafc;
      cursor: pointer;
    }
    .drop.active { border-color: var(--accent); background: #ecfdf5; color: var(--accent); }
    input[type=file] { display: none; }
    label { display: block; font-size: 12px; color: var(--muted); margin: 10px 0 4px; }
    input[type=text] {
      width: 100%;
      padding: 8px 9px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #fff;
      color: var(--ink);
    }
    button {
      border: 1px solid #0f766e;
      background: var(--accent);
      color: white;
      border-radius: 6px;
      padding: 8px 10px;
      cursor: pointer;
      font-weight: 600;
    }
    button.secondary { background: #fff; color: var(--accent-2); border-color: var(--line); }
    .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
    .status {
      margin-top: 10px;
      padding: 8px;
      border-radius: 6px;
      background: #f1f5f9;
      color: var(--muted);
      overflow-wrap: anywhere;
      min-height: 34px;
    }
    .account-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; align-items: stretch; }
    .account-card {
      background: #fff;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      box-shadow: 0 2px 8px rgba(15, 23, 42, 0.06);
    }
    .account-head { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; }
    .account-name { font-size: 18px; font-weight: 700; margin: 0; overflow-wrap: anywhere; }
    .account-sub { color: var(--muted); font-size: 12px; margin-top: 4px; }
    .pill { display: inline-flex; align-items: center; border-radius: 999px; padding: 4px 8px; font-size: 11px; font-weight: 700; background: #eef2ff; color: #4f46e5; white-space: nowrap; }
    .hero-kpis { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin: 18px 0 12px; }
    .hero-kpi .label { color: #4b5563; font-size: 12px; }
    .hero-kpi .value { margin-top: 5px; font-size: 20px; font-weight: 800; letter-spacing: 0; }
    .hero-kpi .badge { display: inline-flex; margin-top: 4px; border-radius: 999px; padding: 2px 6px; color: #fff; font-size: 10px; font-weight: 700; background: var(--good); }
    .hero-kpi .badge.bad { background: var(--bad); color: #fff; }
    .dashboard-row { display: grid; grid-template-columns: minmax(0, 2.2fr) minmax(220px, 0.8fr); gap: 12px; align-items: stretch; }
    .curve-card, .side-card { border: 1px solid var(--line); border-radius: 8px; padding: 10px; background: #fff; min-height: 286px; }
    .curve-toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; color: var(--muted); font-size: 12px; }
    .segmented { display: inline-flex; border: 1px solid var(--violet); border-radius: 999px; overflow: hidden; color: var(--violet); font-size: 11px; }
    .segmented span { padding: 4px 28px; }
    .segmented span.active { background: var(--violet); color: #fff; }
    .side-bars { height: 220px; display: flex; align-items: end; gap: 10px; padding: 12px 4px 0; border-bottom: 1px solid #e5e7eb; }
    .side-bar { flex: 1; background: var(--violet); min-height: 4px; border-radius: 2px 2px 0 0; position: relative; opacity: 0.9; }
    .side-bar span { position: absolute; left: 50%; transform: translateX(-50%); top: -18px; font-size: 10px; color: #334155; font-weight: 700; white-space: nowrap; }
    .compare-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .report-title { display: flex; justify-content: space-between; gap: 8px; align-items: baseline; margin-bottom: 8px; }
    .report-title strong { font-size: 14px; }
    .report-title span { color: var(--muted); font-size: 12px; }
    .metrics { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
    .metric { border: 1px solid var(--line); border-radius: 6px; padding: 8px; min-height: 58px; }
    .metric .k { color: var(--muted); font-size: 11px; }
    .metric .v { font-size: 15px; margin-top: 4px; font-weight: 650; overflow-wrap: anywhere; }
    .section-title { margin: 12px 0 6px; font-weight: 650; font-size: 13px; }
    .stat-list {
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: hidden;
      background: #fff;
    }
    .stat-line {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      padding: 7px 9px;
      border-bottom: 1px solid #e5e7eb;
    }
    .stat-line:last-child { border-bottom: 0; }
    .stat-line span:first-child { color: var(--muted); }
    .stat-line span:last-child { font-weight: 600; text-align: right; overflow-wrap: anywhere; }
    canvas { width: 100%; height: 260px; display: block; }
    table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 12px; }
    th, td { border-bottom: 1px solid #e5e7eb; padding: 6px; text-align: right; white-space: nowrap; }
    th { position: sticky; top: 0; background: #f8fafc; z-index: 3; color: #475569; box-shadow: 0 1px 0 #e5e7eb, 0 2px 8px rgba(15, 23, 42, 0.08); }
    td:first-child, th:first-child, td:nth-child(3), th:nth-child(3) { text-align: left; }
    .table-wrap { max-height: 420px; overflow: auto; border: 1px solid var(--line); border-radius: 8px; margin-top: 12px; position: relative; }
    .good { color: var(--good); }
    .bad { color: var(--bad); }
    @media (max-width: 1000px) {
      .grid, .top-tools, .account-grid, .compare-grid, .dashboard-row { grid-template-columns: 1fr; }
      .hero-kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
  </style>
</head>
<body>
  <header>
    <h1>MT5 Report Hub</h1>
    <div class="row">
      <button class="secondary" onclick="clearReports()">Clear Compare</button>
    </div>
  </header>
  <main>
    <div class="grid">
      <section class="top-tools">
        <div class="panel">
          <h2>Convert RandomEA Report</h2>
          <div class="drop" id="convertDrop">Drop randomEA HTML report here<br>or click to choose</div>
          <input id="convertFile" type="file" accept=".html,.htm">
          <label for="tapeName">Output CSV name</label>
          <input id="tapeName" type="text" value="randomEA_trade_tape.csv">
          <div class="row" style="margin-top:10px">
            <button onclick="convertReport()">Convert + Copy To Common Files</button>
          </div>
          <div class="status" id="convertStatus">Waiting for report.</div>
        </div>

        <div class="panel">
          <h2>Compare Reports</h2>
          <div class="drop" id="compareDrop">Drop one or two MT5 HTML reports here<br>or click to choose</div>
          <input id="compareFile" type="file" accept=".html,.htm" multiple>
          <div class="status" id="compareStatus">Waiting for reports.</div>
        </div>
      </section>

      <section>
        <div class="account-grid" id="accountDashboards"></div>
        <div class="compare-grid" id="reports"></div>
      </section>
    </div>
  </main>
  <script>
    const reports = [];
    let convertFile = null;

    function setupDrop(dropId, inputId, handler) {
      const drop = document.getElementById(dropId);
      const input = document.getElementById(inputId);
      drop.onclick = () => input.click();
      input.onchange = () => handler([...input.files]);
      drop.ondragover = e => { e.preventDefault(); drop.classList.add('active'); };
      drop.ondragleave = () => drop.classList.remove('active');
      drop.ondrop = e => {
        e.preventDefault();
        drop.classList.remove('active');
        handler([...e.dataTransfer.files]);
      };
    }

    setupDrop('convertDrop', 'convertFile', files => {
      convertFile = files[0] || null;
      document.getElementById('convertStatus').textContent = convertFile ? `Selected ${convertFile.name}` : 'Waiting for report.';
    });

    setupDrop('compareDrop', 'compareFile', files => {
      files.slice(0, 2).forEach(uploadCompare);
    });

    async function convertReport() {
      if (!convertFile) {
        document.getElementById('convertStatus').textContent = 'Choose a report first.';
        return;
      }
      const fd = new FormData();
      fd.append('report', convertFile);
      fd.append('name', document.getElementById('tapeName').value || 'randomEA_trade_tape.csv');
      document.getElementById('convertStatus').textContent = 'Converting...';
      const res = await fetch('/api/convert', { method: 'POST', body: fd });
      const data = await res.json();
      document.getElementById('convertStatus').textContent = data.ok
        ? `Converted ${data.rows} trades. MT5 input: ${data.tradeTapeFileName}. Excel: ${data.excelPath}. Copied to ${data.commonPath}`
        : `Failed: ${data.error}`;
    }

    async function uploadCompare(file) {
      const fd = new FormData();
      fd.append('report', file);
      document.getElementById('compareStatus').textContent = `Reading ${file.name}...`;
      const res = await fetch('/api/report', { method: 'POST', body: fd });
      const data = await res.json();
      if (!data.ok) {
        document.getElementById('compareStatus').textContent = `Failed: ${data.error}`;
        return;
      }
      reports.push(data.report);
      while (reports.length > 2) reports.shift();
      document.getElementById('compareStatus').textContent = `${reports.length} report(s) loaded.`;
      renderReports();
    }

    function clearReports() {
      reports.length = 0;
      renderReports();
      document.getElementById('compareStatus').textContent = 'Waiting for reports.';
    }

    function metricValue(report, key) {
      return report.metrics[key] || report.derived[key] || '';
    }

    function renderReports() {
      const el = document.getElementById('reports');
      const dash = document.getElementById('accountDashboards');
      dash.innerHTML = reports.map((report, idx) => accountDashboard(report, idx)).join('');
      el.innerHTML = reports.map(report => reportCard(report)).join('');
      drawAccountCurves();
    }

    function accountDashboard(report, idx) {
      const adv = report.advanced || {};
      const account = adv.account || {};
      const perf = adv.performance || {};
      const risk = adv.risk || {};
      const totalProfit = Number(perf.netPnl || 0);
      const start = Number(account.startingBalance || 0);
      const monthProxy = totalProfit;
      const avgTrade = Number(perf.averagePnl || 0);
      const winRate = Number(perf.winRate || 0);
      const curveId = `accountCurve${idx}`;
      const bars = monthlyBars(report).map(item => `
        <div class="side-bar" style="height:${item.height}%"><span>${fmt(item.value)}%</span></div>
      `).join('');
      return `<article class="account-card">
        <div class="account-head">
          <div>
            <h2 class="account-name">${esc(report.file)}</h2>
            <div class="account-sub">${esc(report.expert || 'MT5 report')} ${esc(report.symbol || '')}</div>
          </div>
          <span class="pill">Report ${idx + 1}</span>
        </div>
        <div class="hero-kpis">
          ${heroKpi('Initial Balance', money(start, false), account.balanceChangePct)}
          ${heroKpi('Total Profit', money(totalProfit), account.balanceChangePct)}
          ${heroKpi('This Run', money(monthProxy), account.balanceChangePct)}
          ${heroKpi('Avg / Trade', money(avgTrade), avgTrade)}
          ${heroKpi('Win Rate', `${fmt(winRate)}%`, winRate)}
        </div>
        <div class="dashboard-row">
          <div class="curve-card">
            <div class="curve-toolbar">
              <span class="pill">Growth</span>
              <span class="segmented"><span class="active">Growth</span><span>Drawdown</span></span>
            </div>
            <canvas id="${curveId}" width="760" height="300"></canvas>
          </div>
          <div class="side-card">
            <div class="curve-toolbar">
              <span class="pill">Quality</span>
              <span>${risk.profitFactor || 'PF n/a'}</span>
            </div>
            <div class="side-bars">${bars}</div>
            <div class="account-sub" style="margin-top:10px">Trade buckets by closed P&L sequence</div>
          </div>
        </div>
      </article>`;
    }

    function heroKpi(label, value, change) {
      const n = Number(change || 0);
      const cls = n < 0 ? 'bad' : '';
      const pct = Math.abs(n) > 100 ? '' : `${n >= 0 ? '+' : ''}${fmt(n)}%`;
      return `<div class="hero-kpi">
        <div class="label">${esc(label)}</div>
        <div class="value ${cls}">${esc(value)}</div>
        ${pct ? `<span class="badge ${cls}">${pct}</span>` : ''}
      </div>`;
    }

    function monthlyBars(report) {
      const trades = (report.advanced && report.advanced.closedTrades) || [];
      if (!trades.length) return [{value: 0, height: 4}, {value: 0, height: 4}, {value: 0, height: 4}];
      const buckets = [0, 0, 0, 0, 0, 0];
      trades.forEach((trade, i) => {
        const idx = Math.min(buckets.length - 1, Math.floor(i / Math.max(1, trades.length / buckets.length)));
        buckets[idx] += Number(trade.net || 0);
      });
      const base = Math.max(1, Number(report.advanced?.account?.startingBalance || 0));
      const pct = buckets.map(v => (v / base) * 100);
      const maxAbs = Math.max(1, ...pct.map(v => Math.abs(v)));
      return pct.map(v => ({value: v, height: Math.max(4, Math.abs(v) / maxAbs * 88)}));
    }

    function reportCard(report) {
      const adv = report.advanced || {};
      const account = adv.account || {};
      const perf = adv.performance || {};
      const streaks = adv.streaks || {};
      const risk = adv.risk || {};
      const keys = [
        ['Total Net Profit', 'Total Net Profit'],
        ['Profit Factor', 'profitFactor'],
        ['Closed Deals', 'closedDeals'],
        ['Total Wins', 'wins'],
        ['Total Losses', 'losses'],
        ['Total BE', 'breakevens'],
        ['Win Rate', 'winRate'],
        ['BE Win Rate', 'breakevenWinRate'],
        ['Edge', 'edgePercent'],
        ['Balance DD Max', 'Balance Drawdown Maximal'],
        ['Equity DD Max', 'Equity Drawdown Maximal'],
        ['Expectancy', 'expectancyExBe'],
        ['Avg R', 'avgRealizedR'],
        ['Derived Net', 'netPnl'],
      ];
      const metrics = keys.map(([label, key]) => {
        let value = metricValue(report, key);
        if (key in perf) value = perf[key];
        if (key in risk) value = risk[key];
        if (['wins', 'losses', 'breakevens'].includes(key)) value = perf[key] ?? 0;
        if (key === 'winRate') value = `${perf.winRate ?? value}%`;
        if (key === 'breakevenWinRate') value = `${fmt(perf.breakevenWinRate || 0)}%`;
        if (key === 'edgePercent') value = `${Number(perf.edgePercent || 0) >= 0 ? '+' : ''}${fmt(perf.edgePercent || 0)}%`;
        if (key === 'expectancyExBe' && value !== '') value = money(value);
        if (key === 'netPnl' && value !== '') value = money(value);
        const cls = String(value).startsWith('-') ? 'bad' : '';
        return `<div class="metric"><div class="k">${label}</div><div class="v ${cls}">${value || '-'}</div></div>`;
      }).join('');
      const best = perf.bestTrade ? `${money(perf.bestTrade.net)} ${esc(perf.bestTrade.symbol)} ${esc(perf.bestTrade.side)} ${esc(shortTime(perf.bestTrade.closeTime))}` : 'n/a';
      const worst = perf.worstTrade ? `${money(perf.worstTrade.net)} ${esc(perf.worstTrade.symbol)} ${esc(perf.worstTrade.side)} ${esc(shortTime(perf.worstTrade.closeTime))}` : 'n/a';
      const accountHtml = statList([
        ['Sequence start', shortTime(account.sequenceStart || '')],
        ['Starting balance', money(account.startingBalance || 0, false)],
        ['Current balance', money(account.currentBalance || 0, false)],
        ['Balance change', `${money(account.balanceChange || 0)} (${fmt(account.balanceChangePct || 0)}%)`],
        ['Closed P&L in report', money(account.closedPnl || 0)],
      ]);
      const perfHtml = statList([
        ['Outcome', perf.outcome || 'n/a'],
        ['Net P&L', money(perf.netPnl || 0)],
        ['Trades', `${perf.closedTrades || 0} closed | ${perf.wins || 0} wins | ${perf.losses || 0} losses | ${perf.breakevens || 0} BE`],
        ['Win rate', `${fmt(perf.winRate || 0)}%`],
        ['Win rate excl BE', `${fmt(perf.winRateExBe || 0)}%`],
        ['Breakeven win rate', `${fmt(perf.breakevenWinRate || 0)}%`],
        ['Edge', `${Number(perf.edgePercent || 0) >= 0 ? '+' : ''}${fmt(perf.edgePercent || 0)}%`],
        ['Average P&L/trade', money(perf.averagePnl || 0)],
        ['Avg win / loss', `${money(perf.averageWin || 0)} / ${money(perf.averageLoss || 0)}`],
        ['Payoff ratio', perf.payoffRatio || 'n/a'],
        ['Expectancy excl BE', `${money(perf.expectancyExBe || 0)}/trade`],
        ['Breakeven band', `${money(perf.breakevenThreshold || 0)} (${esc(perf.breakevenRule || '+/- 10.00')})`],
        ['Best trade', best],
        ['Worst trade', worst],
      ]);
      const streakHtml = statList([
        ['Current streak', streaks.current || 'none'],
        ['Win streaks', `${streaks.winStreaks || 0} | max ${streaks.maxWinStreak || 0} | avg ${fmt(streaks.avgWinStreak || 0)}`],
        ['Loss streaks', `${streaks.lossStreaks || 0} | max ${streaks.maxLossStreak || 0} | avg ${fmt(streaks.avgLossStreak || 0)}`],
      ]);
      const riskHtml = statList([
        ['Avg realized R', risk.avgRealizedR || 'n/a'],
        ['Net / gross loss', risk.netGrossLossR || 'n/a'],
        ['Profit factor', risk.profitFactor || report.metrics['Profit Factor'] || 'n/a'],
        ['Gross profit', money(risk.grossProfit || 0)],
        ['Gross loss', money(risk.grossLoss || 0)],
      ]);
      const rows = report.deals.slice(0, 250).map(d => {
        const p = Number(d.profit || 0) + Number(d.swap || 0) + Number(d.commission || 0);
        return `<tr>
          <td>${esc(d.time)}</td><td>${esc(d.deal)}</td><td>${esc(d.symbol)}</td>
          <td>${esc(d.type)}</td><td>${esc(d.direction)}</td><td>${esc(String(d.volume))}</td>
          <td>${esc(String(d.price))}</td><td class="${p >= 0 ? 'good' : 'bad'}">${p.toFixed(2)}</td>
          <td>${esc(String(d.balance))}</td><td>${esc(d.comment)}</td>
        </tr>`;
      }).join('');
      return `<article class="panel">
        <div class="report-title">
          <strong>${esc(report.file)}</strong>
          <span>${esc(report.expert || '')} ${esc(report.symbol || '')}</span>
        </div>
        <div style="color:var(--muted);font-size:12px;margin-bottom:8px">${esc(report.period || '')}</div>
        <div class="metrics">${metrics}</div>
        <div class="section-title">Account Balance</div>
        ${accountHtml}
        <div class="section-title">Performance Summary</div>
        ${perfHtml}
        <div class="section-title">Streak Analysis</div>
        ${streakHtml}
        <div class="section-title">Risk & Quality</div>
        ${riskHtml}
        <div class="table-wrap">
          <table>
            <thead><tr><th>Time</th><th>Deal</th><th>Symbol</th><th>Type</th><th>Dir</th><th>Vol</th><th>Price</th><th>P/L</th><th>Balance</th><th>Comment</th></tr></thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </article>`;
    }

    function statList(items) {
      return `<div class="stat-list">${items.map(([k, v]) => {
        const cls = String(v).includes('-') ? 'bad' : '';
        return `<div class="stat-line"><span>${esc(k)}</span><span class="${cls}">${v}</span></div>`;
      }).join('')}</div>`;
    }

    function fmt(value) {
      const n = Number(value);
      return Number.isFinite(n) ? n.toFixed(1).replace(/\.0$/, '.0') : String(value ?? '');
    }

    function money(value, withCurrency = true) {
      const n = Number(value || 0);
      const sign = n > 0 ? '+' : '';
      return `${sign}${n.toFixed(2)}${withCurrency ? ' USD' : ' USD'}`;
    }

    function shortTime(value) {
      if (!value) return '';
      const m = String(value).match(/^(\d{4})\.(\d{2})\.(\d{2}) (\d{2}):(\d{2})/);
      if (!m) return String(value);
      return `${m[2]}/${m[3]} ${m[4]}:${m[5]}`;
    }

    function drawAccountCurves() {
      reports.forEach((report, idx) => {
        drawSingleCurve(`accountCurve${idx}`, report, idx);
      });
    }

    function drawSingleCurve(canvasId, report, idx) {
      const canvas = document.getElementById(canvasId);
      if (!canvas) return;
      const ctx = canvas.getContext('2d');
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      const data = report.balanceCurve || [];
      const vals = data.map(p => Number(p.balance)).filter(Number.isFinite);
      if (vals.length < 2) return;
      const min = Math.min(...vals), max = Math.max(...vals);
      const color = idx === 0 ? '#665cff' : '#0f766e';
      const padLeft = 46;
      const padRight = 14;
      const padTop = 18;
      const padBottom = 34;
      const plotW = canvas.width - padLeft - padRight;
      const plotH = canvas.height - padTop - padBottom;
      const yFor = value => padTop + plotH - ((Number(value) - min) / Math.max(1, max - min)) * plotH;
      const xFor = i => padLeft + (i / (data.length - 1)) * plotW;

      ctx.font = '11px Segoe UI, Arial';
      ctx.strokeStyle = '#e5e7eb';
      ctx.lineWidth = 1;
      for (let i = 0; i <= 4; i++) {
        const y = padTop + (plotH / 4) * i;
        ctx.beginPath();
        ctx.moveTo(padLeft, y);
        ctx.lineTo(canvas.width - padRight, y);
        ctx.stroke();
      }

      const points = data.map((p, i) => ({x: xFor(i), y: yFor(Number(p.balance))}));
      const gradient = ctx.createLinearGradient(0, padTop, 0, canvas.height - padBottom);
      gradient.addColorStop(0, idx === 0 ? 'rgba(102, 92, 255, 0.36)' : 'rgba(15, 118, 110, 0.28)');
      gradient.addColorStop(1, 'rgba(102, 92, 255, 0.04)');

      ctx.beginPath();
      points.forEach((point, i) => {
        if (i === 0) ctx.moveTo(point.x, point.y); else ctx.lineTo(point.x, point.y);
      });
      ctx.lineTo(points[points.length - 1].x, canvas.height - padBottom);
      ctx.lineTo(points[0].x, canvas.height - padBottom);
      ctx.closePath();
      ctx.fillStyle = gradient;
      ctx.fill();

      ctx.strokeStyle = color;
      ctx.lineWidth = 3;
      ctx.beginPath();
      points.forEach((point, i) => {
        if (i === 0) ctx.moveTo(point.x, point.y); else ctx.lineTo(point.x, point.y);
      });
      ctx.stroke();

      ctx.strokeStyle = '#cbd5e1';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(padLeft, padTop);
      ctx.lineTo(padLeft, canvas.height - padBottom);
      ctx.lineTo(canvas.width - padRight, canvas.height - padBottom);
      ctx.stroke();

      ctx.fillStyle = '#475569';
      ctx.fillText(max.toFixed(0), 4, padTop + 4);
      ctx.fillText(min.toFixed(0), 4, canvas.height - padBottom);
      ctx.fillStyle = '#334155';
      ctx.font = 'bold 11px Segoe UI, Arial';
      ctx.fillText('Number of trades', canvas.width / 2 - 44, canvas.height - 8);
      ctx.fillStyle = 'rgba(71, 85, 105, 0.18)';
      ctx.font = 'bold 24px Segoe UI, Arial';
      ctx.fillText(`REPORT ${idx + 1}`, canvas.width / 2 - 62, canvas.height / 2 + 8);
    }

    function esc(value) {
      return String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[ch]));
    }
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def send_json(self, data: dict, status: int = 200) -> None:
        raw = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if urlparse(self.path).path != "/":
            self.send_error(404)
            return
        raw = HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            form = parse_multipart(self.headers, body)
            if "report" not in form:
                self.send_json({"ok": False, "error": "No report file was uploaded."}, 400)
                return

            file_item = form["report"]
            filename = safe_name(Path(file_item.get("filename") or "report.html").name)
            UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
            report_path = UPLOADS_DIR / f"{int(time.time() * 1000)}_{filename}"
            with report_path.open("wb") as f:
                f.write(file_item["data"])

            if path == "/api/convert":
                output_name = "randomEA_trade_tape.csv"
                if "name" in form:
                    output_name = str(form["name"].get("value") or output_name)
                result = convert_report_to_tape(report_path, output_name)
                self.send_json({"ok": True, **result})
                return

            if path == "/api/report":
                self.send_json({"ok": True, "report": report_summary(report_path)})
                return

            self.send_error(404)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, 500)


def main() -> None:
    HUB_DIR.mkdir(exist_ok=True)
    port = int(os.environ.get("MT5_REPORT_HUB_PORT", "8765"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"MT5 Report Hub running at http://127.0.0.1:{port}")
    print(f"Data folder: {HUB_DIR}")
    print(f"MT5 Common Files: {common_files_dir()}")
    server.serve_forever()


if __name__ == "__main__":
    main()
