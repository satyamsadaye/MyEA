#!/usr/bin/env python3
import os, re, json, glob
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from datetime import datetime

REPORT_DIR = os.path.expanduser(
    "~/.wine/drive_c/users/satyam/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
)
PORT = 8080

cached_reports = []

def extract_kv(html, key):
    m = re.search(
        r'<div class="kv"><span class="k">' + re.escape(key) +
        r'</span><span class="v">([^<]+)</span></div>', html
    )
    return m.group(1).strip() if m else ""

def extract_card(html, cls, label):
    m = re.search(
        r'<div class="card ' + re.escape(cls) + r'"><div class="label">' +
        re.escape(label) + r'</div><div class="value">([^<]+)</div>', html
    )
    return m.group(1).strip() if m else ""

def extract_card_sub(html, cls, label):
    m = re.search(
        r'<div class="card ' + re.escape(cls) + r'"><div class="label">' +
        re.escape(label) + r'</div><div class="value">[^<]+</div><div class="sub">[^<]*' +
        r'&middot;\s*avg\s*([^<]+)</div>', html
    )
    return m.group(1).strip() if m else ""

def extract_section_cards(html, section_title):
    start = html.find("<h2>" + section_title + "</h2>")
    if start < 0:
        return {}
    section_html = html[start:]
    return {
        "T5Passed": extract_card(section_html, "pass", "Passed Runs"),
        "T5Blown": extract_card(section_html, "blow", "Blown Runs"),
        "T5Active": extract_card(section_html, "act", "Active Runs"),
        "T5ActiveProfit": extract_card(section_html, "profit", "Active in Profit"),
        "T5ActiveLoss": extract_card(section_html, "loss", "Active in Drawdown"),
        "T5ActiveProfitDepth": extract_card_sub(section_html, "profit", "Active in Profit"),
        "T5ActiveLossDepth": extract_card_sub(section_html, "loss", "Active in Drawdown"),
        "T5PassRate": extract_card(section_html, "rate", "Overall Pass Rate"),
        "T5CompletedPass": extract_card(section_html, "done", "Completed Pass Rate"),
        "T5Trades": extract_card(section_html, "tot", "Total Trades"),
        "T5Signals": extract_card(section_html, "sig", "Total Signals"),
        "T5Runs": extract_card(section_html, "avg", "Total Runs"),
    }

def scan_reports():
    results = []
    files = sorted(
        glob.glob(os.path.join(REPORT_DIR, "Propfirm_*_Report_*.html")),
        key=os.path.getmtime, reverse=True
    )
    for fpath in files:
        fname = os.path.basename(fpath)
        if "dashboard" in fname.lower():
            continue
        content = None
        for enc in ("utf-16", "utf-8", "latin-1"):
            try:
                with open(fpath, "r", encoding=enc) as fh:
                    content = fh.read()
                break
            except (UnicodeDecodeError, UnicodeError):
                continue
        if content is None:
            continue
        if not content:
            continue
        symbol = extract_kv(content, "Symbol")
        period = extract_kv(content, "Period")
        spawn_interval = extract_kv(content, "Spawn Interval")
        rolling_mode = extract_kv(content, "Rolling Start Mode")
        test_started = extract_kv(content, "Test Started")
        report_generated = extract_kv(content, "Report Generated")
        total_strategies = extract_kv(content, "Total Strategies")
        total_runs_sim = extract_kv(content, "Total Runs Simulated")
        prop_mode = extract_kv(content, "Prop Strategy Mode")

        passed = extract_card(content, "pass", "Passed Runs")
        blown = extract_card(content, "blow", "Blown Runs")
        active = extract_card(content, "act", "Active Runs")
        active_profit = extract_card(content, "profit", "Active in Profit")
        active_loss = extract_card(content, "loss", "Active in Drawdown")
        pass_rate = extract_card(content, "rate", "Overall Pass Rate")
        trades = extract_card(content, "avg", "Total Trades")
        signals = extract_card(content, "sig", "Total Signals")
        runs = extract_card(content, "tot", "Total Runs")

        top_strat = ""
        top_recency = ""
        top_alltime = ""
        m = re.search(
            r'<div class="card rec"><div class="label">Top Strategy \(Recent\)</div>'
            r'<div class="value"[^>]*>([^<]+)</div>'
            r'<div class="sub">Recency:\s*([^%]+)%[^&]*&nbsp;\|&nbsp;\s*All-time:\s*([^%]+)%',
            content
        )
        if m:
            top_strat = m.group(1).strip()
            top_recency = m.group(2).strip()
            top_alltime = m.group(3).strip()

        top_persist_strat = ""
        top_persist_score = ""
        m = re.search(
            r'<div class="card persist"><div class="label">Top Strategy \(Persistence\)</div>'
            r'<div class="value"[^>]*>([^<]+)</div>'
            r'<div class="sub">Score:\s*([^<]+)</div>',
            content
        )
        if m:
            top_persist_strat = m.group(1).strip()
            top_persist_score = m.group(2).strip()

        report_title = ""
        m = re.search(r'<h1>([^<]+)</h1>', content)
        if m:
            report_title = m.group(1).strip()

        is_forward = "Forward" in report_title or "CUSTOM" in prop_mode.upper()

        generated = ""
        m = re.search(r'Generated:\s*([^<]+)</div>', content)
        if m:
            generated = m.group(1).strip()

        best_strat = ""
        best_rate = ""
        m = re.search(
            r'Best strategy:\s*<b>([^<]+)</b>\s*\(([^)]+)\)', content
        )
        if m:
            best_strat = m.group(1).strip()
            best_rate = m.group(2).strip()

        top5_data = extract_section_cards(content, "Top 5 Strategies Summary")

        t5_names = ""
        m = re.search(r'<div class="note">Top 5 strategies: <b>([^<]+)</b></div>', content)
        if m:
            t5_names = m.group(1).strip()

        top5_codes = []
        table_start = content.find('<table id="strat">')
        if table_start >= 0:
            table_content = content[table_start:]
            for m in re.finditer(r"onclick=\"filterRuns\('(\d+)_", table_content):
                top5_codes.append(m.group(1))
                if len(top5_codes) >= 5:
                    break

        mtime = datetime.fromtimestamp(os.path.getmtime(fpath))
        results.append({
            "Filename": fname,
            "FilePath": fname,
            "FileTime": mtime.strftime("%Y-%m-%d %H:%M:%S"),
            "Symbol": symbol,
            "Period": period,
            "SpawnInterval": spawn_interval,
            "RollingMode": rolling_mode,
            "TestStarted": test_started,
            "ReportGenerated": report_generated,
            "TotalStrategies": total_strategies,
            "TotalRunsSim": total_runs_sim,
            "PropMode": prop_mode,
            "Passed": passed,
            "Blown": blown,
            "Active": active,
            "ActiveProfit": active_profit,
            "PassRate": pass_rate,
            "ActiveLoss": active_loss,
            "Trades": trades,
            "Signals": signals,
            "Runs": runs,
            "TopStrat": top_strat,
            "TopRecency": top_recency,
            "TopAlltime": top_alltime,
            "TopPersistStrat": top_persist_strat,
            "TopPersistScore": top_persist_score,
            "ReportTitle": report_title,
            "Generated": generated,
            "BestStrat": best_strat,
            "BestRate": best_rate,
            "Top5Codes": top5_codes,
            "IsForwardTest": is_forward,
            "T5Passed": top5_data.get("T5Passed", ""),
            "T5Blown": top5_data.get("T5Blown", ""),
            "T5Active": top5_data.get("T5Active", ""),
            "T5ActiveProfit": top5_data.get("T5ActiveProfit", ""),
            "T5ActiveLoss": top5_data.get("T5ActiveLoss", ""),
            "T5ActiveProfitDepth": top5_data.get("T5ActiveProfitDepth", ""),
            "T5ActiveLossDepth": top5_data.get("T5ActiveLossDepth", ""),
            "T5PassRate": top5_data.get("T5PassRate", ""),
            "T5CompletedPass": top5_data.get("T5CompletedPass", ""),
            "T5Trades": top5_data.get("T5Trades", ""),
            "T5Signals": top5_data.get("T5Signals", ""),
            "T5Runs": top5_data.get("T5Runs", ""),
            "T5Names": t5_names,
        })
    return results

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Prop Backtester Reports Hub</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#fff;color:#111;line-height:1.4;padding:20px}
.wrap{max-width:1600px;margin:0 auto}
.header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;padding:0 0 14px 0;border-bottom:1px solid #e5e7eb;margin-bottom:14px}
.header h1{font-size:26px;font-weight:700;color:#111}
.header .sub{font-size:15px;color:#6b7280}
.header .count-badge{background:#f3f4f6;color:#374151;padding:6px 16px;border-radius:999px;font-size:15px;font-weight:600;border:1px solid #e5e7eb}
.stats-bar{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:14px}
.stat-card{background:#fafafa;border:1px solid #e5e7eb;border-radius:8px;padding:10px 18px;text-align:center;flex:1;min-width:90px}
.stat-card .val{font-size:22px;font-weight:700;color:#111}
.stat-card .lbl{font-size:12px;color:#6b7280;text-transform:uppercase;margin-top:2px}
.stat-card .val.green{color:#059669}
.stat-card .val.red{color:#dc2626}
.stat-card .val.blue{color:#2563eb}
.stat-card .val.orange{color:#d97706}
.stat-card .val.purple{color:#7c3aed}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:14px}
.toolbar input{flex:1;min-width:200px;background:#fff;border:1px solid #d1d5db;color:#111;padding:10px 14px;border-radius:6px;font-size:16px;outline:none}
.toolbar input:focus{border-color:#6b7280}
.toolbar input::placeholder{color:#9ca3af}
.btn{background:#fff;color:#374151;border:1px solid #d1d5db;padding:8px 14px;border-radius:6px;font-size:14px;cursor:pointer;font-weight:500}
.btn:hover{background:#f3f4f6}
.btn.active{background:#111;color:#fff;border-color:#111}
.btn:disabled{opacity:.5;pointer-events:none}
.table-wrap{border:1px solid #e5e7eb;border-radius:6px;overflow-x:auto}
table{border-collapse:collapse;font-size:16px;width:100%;min-width:700px}
thead th{background:#f9fafb;padding:10px 12px;text-align:left;font-weight:600;position:sticky;top:0;cursor:pointer;user-select:none;white-space:nowrap;border-bottom:1px solid #e5e7eb;z-index:2;font-size:13px;color:#6b7280;text-transform:uppercase;letter-spacing:.4px}
thead th:hover{background:#f3f4f6}
thead th.sorted{color:#111}
tbody td{padding:10px 12px;border-bottom:1px solid #f3f4f6;white-space:nowrap;vertical-align:middle}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover{background:#fafafa}
tbody tr td:first-child{font-weight:600;color:#6b7280;width:34px;text-align:center;font-size:14px}
.col-date{min-width:170px}
.col-date .date-range{font-weight:600;font-size:16px;color:#111}
.col-date .meta{color:#6b7280;font-size:14px}
.col-date .meta span{font-weight:600;color:#111}
.col-date .meta .prop{color:#d97706;font-size:13px}
.col-stats{min-width:300px}
.col-stats .stat-row{display:flex;gap:14px;flex-wrap:wrap;margin:3px 0;align-items:center}
.col-stats .stat-item{font-size:16px;white-space:nowrap}
.col-stats .stat-item .num{font-weight:700}
.col-stats .stat-item .num.purple{color:#7c3aed}
.col-stats .stat-item .pass{color:#059669}
.col-stats .stat-item .blow{color:#dc2626}
.col-stats .stat-item .act{color:#2563eb}
.col-stats .stat-item .rate{color:#d97706}
.col-stats .stat-row .lbl{font-size:15px;color:#6b7280}
.col-stats .stat-row .lbl b{color:#111}
.col-stats .strat-name{font-weight:600;font-size:15px;color:#111}
.col-stats .sub{font-size:14px;color:#6b7280}
.col-stats .top5{display:flex;gap:4px;flex-wrap:wrap;align-items:center;margin:3px 0}
.col-stats .top5 .code{background:#f3f4f6;color:#374151;padding:1px 6px;border-radius:3px;font-size:12px;font-weight:600;font-family:monospace}
.col-stats .top5 .code.r1{background:#fef3c7;color:#92400e}
.col-stats .top5 .code.r2{background:#fef3c7;color:#92400e}
.col-stats .top5 .code.r3{background:#fef3c7;color:#92400e}
.col-stats .top5 .code.r4{background:#f3f4f6;color:#374151}
.col-stats .top5 .code.r5{background:#f3f4f6;color:#374151}
.btn-copy{background:none;border:1px solid #d1d5db;color:#6b7280;padding:1px 7px;border-radius:3px;font-size:11px;cursor:pointer;line-height:1.5}
.btn-copy:hover{background:#f3f4f6;color:#111}
.col-action{text-align:center;width:90px}
.btn-open{background:#111;color:#fff;border:none;padding:8px 18px;border-radius:6px;font-size:15px;font-weight:500;cursor:pointer;text-decoration:none;display:inline-block}
.btn-open:hover{background:#374151}
.tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:12px;font-weight:600;margin-right:3px;vertical-align:middle}
.tag-100{background:#ecfdf5;color:#059669;border:1px solid #a7f3d0}
.tag-500{background:#eef2ff;color:#4f46e5;border:1px solid #c7d2fe}
.tag-fwd{background:#fffbeb;color:#d97706;border:1px solid #fde68a}
.footer{color:#9ca3af;font-size:14px;text-align:center;padding:16px 0 0 0;border-top:1px solid #f3f4f6;margin-top:14px}
.footer code{background:#f3f4f6;padding:2px 7px;border-radius:3px;color:#6b7280;font-size:12px}
.empty-state{text-align:center;padding:50px 20px;color:#6b7280}
.empty-state h2{font-size:17px;color:#374151;margin-bottom:5px;font-weight:600}
.spawn-badge{background:#f3f4f6;color:#374151;padding:0 7px;border-radius:2px;font-size:12px}
.fwd-label{font-size:11px;color:#d97706;font-weight:600;background:#fffbeb;padding:1px 6px;border-radius:3px;border:1px solid #fde68a;vertical-align:middle}
.status-bar{font-size:13px;color:#6b7280;text-align:center;padding:4px;display:none}
.status-bar.show{display:block}
.progress-wrap{height:4px;background:#e5e7eb;border-radius:2px;margin:6px auto 2px;overflow:hidden;max-width:400px}
.progress-bar{height:100%;width:30%;background:#111;border-radius:2px;animation:progress 1.5s ease-in-out infinite}
@keyframes progress{0%{transform:translateX(-100%)}100%{transform:translateX(400%)}}
</style>
</head>
<body>
<div class="wrap">
<div class="header">
<div>
<h1>Prop Backtester Reports Hub</h1>
<div class="sub">Propfirm virtual simulation reports <span id="serverBadge" style="color:#059669;font-weight:600">&#9679; Live</span></div>
</div>
<div class="count-badge" id="reportCount">0 reports</div>
</div>
<div class="stats-bar" id="aggregateStats"></div>
<div style="margin:2px 0 4px 0;font-size:13px;color:#6b7280;font-weight:600;text-transform:uppercase;letter-spacing:.4px">Forward Test Results</div>
<div class="stats-bar" id="forwardAggregateStats"></div>
<div class="toolbar">
<input type="text" id="searchInput" placeholder="Search symbol, period, strategy...">
<button class="btn active" data-filter="all">All</button>
<button class="btn" data-filter="100">100</button>
<button class="btn" data-filter="500">500</button>
<button class="btn" data-filter="fwd">Forward</button>
<button class="btn" id="refreshBtn">&#x21bb; Refresh</button>
</div>
<div class="status-bar" id="statusBar"><span id="statusText">Loading...</span><div class="progress-wrap"><div class="progress-bar"></div></div></div>
<div class="table-wrap">
<table>
<thead>
<tr>
<th style="width:32px" data-sort="num">#</th>
<th data-sort="date" class="sorted">Date &amp; Config</th>
<th data-sort="stats">Stats</th>
<th style="width:90px" data-sort="action">Result</th>
</tr>
</thead>
<tbody id="reportBody"></tbody>
</table>
</div>
<div class="footer">Server running at <code>http://localhost:""" + str(PORT) + """</code> &mdash; <span id="footerDate"></span></div>
</div>
<script>
var reports = [];

function escapeHtml(s){if(!s)return '';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
var MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
function fmtDate(ds){if(!ds)return'';var p=ds.match(/(\d{4})\.(\d{2})\.(\d{2})/);if(!p)return ds;return parseInt(p[3])+' '+MONTHS[parseInt(p[2])-1]}
function fmtRange(startStr,endStr){
    if(!startStr||!endStr)return fmtDate(startStr||endStr);
    var ps=startStr.match(/(\d{4})\.(\d{2})\.(\d{2})/);
    var pe=endStr.match(/(\d{4})\.(\d{2})\.(\d{2})/);
    if(!ps||!pe)return fmtDate(startStr)+' &rarr; '+fmtDate(endStr);
    var sm=parseInt(ps[2]),sd=parseInt(ps[3]),em=parseInt(pe[2]),ed=parseInt(pe[3]);
    return sd+' '+MONTHS[sm-1]+' &rarr; '+ed+' '+MONTHS[em-1];
}
function fmtGenerated(ft){
    if(!ft)return'';
    var p=ft.match(/(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/);
    if(!p)return ft;
    var h=parseInt(p[4]),m=p[5],ampm=h>=12?'PM':'AM';
    if(h>12)h-=12;if(h===0)h=12;
    return parseInt(p[3])+' '+MONTHS[parseInt(p[2])-1]+' '+h+':'+m+' '+ampm;
}
function periodLabel(p){if(!p)return'';return p.replace('PERIOD_','')}
function spawnLabel(s){if(!s)return'';return s.replace('every ','')}
function rollingLabel(m){return m==='true'?'Rolling':m==='false'?'Single':m}
function sortKey(r){return r.FileTime||r.ReportGenerated||r.TestStarted||r.Filename}
function copyCodes(btn){
    var codes=btn.getAttribute('data-codes');
    if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(codes)}
    else{var ta=document.createElement('textarea');ta.value=codes;document.body.appendChild(ta);ta.select();document.execCommand('copy');document.body.removeChild(ta)}
    btn.textContent='Copied!';setTimeout(function(){btn.textContent='Copy'},1500);
}
var currentFilter='all',currentSearch='';
function getStratCount(fn){
    var m=fn.match(/Propfirm_(\d+)_/);if(m)return parseInt(m[1]);
    return fn.indexOf('Forward_Test')>=0?0:0;
}
function matchesFilter(r,f){
    if(f==='all')return true;
    if(f==='fwd')return r.IsForwardTest||r.Filename.indexOf('Forward_Test')>=0;
    var c=getStratCount(r.Filename);
    if(f==='100')return c===100;
    if(f==='500')return c===500;
    return true;
}
function matchesSearch(r,q){
    if(!q)return true;q=q.toLowerCase();
    return!!(r.Symbol&&r.Symbol.toLowerCase().indexOf(q)>=0)||
           !!(r.Period&&r.Period.toLowerCase().indexOf(q)>=0)||
           !!(r.TopStrat&&r.TopStrat.toLowerCase().indexOf(q)>=0)||
           !!(r.BestStrat&&r.BestStrat.toLowerCase().indexOf(q)>=0)||
           !!(r.PropMode&&r.PropMode.toLowerCase().indexOf(q)>=0)||
           !!(r.Filename&&r.Filename.toLowerCase().indexOf(q)>=0);
}
function render(){
    var filtered=reports.filter(function(r){return matchesFilter(r,currentFilter)&&matchesSearch(r,currentSearch)});
    var tbody=document.getElementById('reportBody');tbody.innerHTML='';
    document.getElementById('reportCount').textContent=filtered.length+' report'+(filtered.length!==1?'s':'');
    if(filtered.length===0){
        tbody.innerHTML='<tr><td colspan="4"><div class="empty-state"><h2>No reports found</h2><p>Run a backtest or adjust your filter.</p></div></td></tr>';
        updateAggregates([]);return;
    }
    var aggPassed=0,aggBlown=0,aggActive=0,aggTrades=0,aggRuns=0,aggRateSum=0,aggRateCount=0;
    for(var i=0;i<filtered.length;i++){
        (function(report,idx){
            var tr=document.createElement('tr');
            var count=getStratCount(report.Filename);
            var tag='';
            if(count===100)tag='<span class="tag tag-100">100</span>';
            else if(count===500)tag='<span class="tag tag-500">500</span>';
            else if(report.Filename.indexOf('Forward_Test')>=0)tag='<span class="tag tag-fwd">FWD</span>';
            var periodShort=periodLabel(report.Period);
            var spawnShort=spawnLabel(report.SpawnInterval);
            var rollLabel=rollingLabel(report.RollingMode);
            var dateRange=fmtRange(report.TestStarted,report.ReportGenerated);
            var totalStrats=report.TotalStrategies||(count>0?count.toString():'?');
            var passed=parseInt(report.Passed)||0,blown=parseInt(report.Blown)||0,active=parseInt(report.Active)||0;
            var completedPass=passed+blown>0?((passed/(passed+blown))*100).toFixed(1):'0.0';
            var trad=parseInt(report.Trades)||0,sigs=parseInt(report.Signals)||0,runs=parseInt(report.Runs)||0;
            aggPassed+=passed;aggBlown+=blown;aggActive+=active;aggTrades+=trad;aggRuns+=runs;
            var rateNum=parseFloat(report.PassRate)||0;if(rateNum>0){aggRateSum+=rateNum;aggRateCount++;}
            var c1=document.createElement('td');c1.textContent=idx+1;tr.appendChild(c1);
            var c2=document.createElement('td');c2.className='col-date';
            c2.innerHTML='<div class="date-range">'+dateRange+'</div>'+
                '<div class="meta">'+escapeHtml(report.Symbol)+' <span>'+escapeHtml(periodShort)+'</span> '+tag+' '+escapeHtml(totalStrats)+' &middot; '+escapeHtml(rollLabel)+(spawnShort?' <span class="spawn-badge">'+escapeHtml(spawnShort)+'</span>':'')+(report.PropMode?' <span class="prop">'+escapeHtml(report.PropMode)+'</span>':'')+(report.IsForwardTest?' <span class="fwd-label">&#10132;&#10132; forward test</span>':'')+'</div>'+
                '<div class="gen-time" style="font-size:13px;color:#9ca3af;margin:2px 0 1px">Generated: '+fmtGenerated(report.FileTime)+'</div>';
            tr.appendChild(c2);
            var c3=document.createElement('td');c3.className='col-stats';
            c3.innerHTML='<div class="stat-row">'+
                '<span class="lbl">Total Runs <b>'+escapeHtml(report.TotalRunsSim)+'</b></span>'+
                '<span class="stat-item"><span class="num pass">'+passed+'</span> passed</span>'+
                '<span class="stat-item"><span class="num blow">'+blown+'</span> blown</span>'+
                '<span class="stat-item"><span class="num act">'+active+'</span> active'+
                (report.ActiveProfit?' <span class="act-profit" style="font-size:13px;color:#059669">'+escapeHtml(report.ActiveProfit)+' profit</span>':'')+
                (report.ActiveLoss?' <span class="act-loss" style="font-size:13px;color:#dc2626">'+escapeHtml(report.ActiveLoss)+' DD</span>':'')+
                '</span>'+
                '<span class="stat-item"><span class="num rate">'+escapeHtml(report.PassRate)+'</span> pass rate</span>'+
                '<span class="stat-item"><span class="num purple">'+completedPass+'%</span> completed pass rate</span>'+
                '</div>'+
                '<div class="stat-row">'+
                '<span class="lbl">Trades <b>'+trad+'</b></span>'+
                '<span class="lbl">Signals <b>'+sigs+'</b></span>'+
                '<span class="lbl">Runs <b>'+runs+'</b></span>'+
                (report.TopStrat?' <span class="strat-name">&#9733;'+escapeHtml(report.TopStrat)+'</span>'+
                (report.TopRecency?' <span class="sub">('+escapeHtml(report.TopRecency)+'% rec, '+escapeHtml(report.TopAlltime)+'% all)</span>':'')+
                (report.TopPersistStrat?' <span class="strat-name" style="color:#059669">P:'+escapeHtml(report.TopPersistStrat)+'</span>':'')+
                (report.BestStrat&&report.BestStrat!==report.TopStrat?' <span class="sub">Best: '+escapeHtml(report.BestStrat)+'</span>':''):'')+
                '</div>'+
                (report.Top5Codes&&report.Top5Codes.length>0?function(codes){
                var h='<div class="top5">';
                for(var ci=0;ci<codes.length;ci++){h+='<span class="code r'+(ci+1)+'">'+codes[ci]+'</span>'}
                var cstr='';for(var ci=0;ci<codes.length;ci++){if(ci>0)cstr+=',';cstr+=('000'+codes[ci]).slice(-3)}
                h+='<button class="btn-copy" data-codes="'+escapeHtml(cstr)+'" onclick="copyCodes(this)">Copy</button></div>';
                return h;
            }(report.Top5Codes):'')+
                (report.T5Names?'<div class="stat-row" style="margin-top:6px;padding-top:6px;border-top:1px solid #e5e7eb">'+
                '<span class="lbl" style="font-size:13px;color:#7c3aed;font-weight:700">&#9733; Top 5</span>'+
                '<span class="stat-item"><span class="num pass">'+escapeHtml(report.T5Passed)+'</span> pass</span>'+
                '<span class="stat-item"><span class="num blow">'+escapeHtml(report.T5Blown)+'</span> blown</span>'+
                '<span class="stat-item"><span class="num act">'+escapeHtml(report.T5Active)+'</span> act'+
                (report.T5ActiveProfit?' <span style="font-size:12px;color:#059669">'+escapeHtml(report.T5ActiveProfit)+' profit</span>':'')+
                (report.T5ActiveProfitDepth?' <span style="font-size:12px;color:#059669">avg +'+escapeHtml(report.T5ActiveProfitDepth)+'</span>':'')+
                (report.T5ActiveLoss?' <span style="font-size:12px;color:#dc2626">'+escapeHtml(report.T5ActiveLoss)+' DD</span>':'')+
                (report.T5ActiveLossDepth?' <span style="font-size:12px;color:#dc2626">avg '+escapeHtml(report.T5ActiveLossDepth)+'</span>':'')+
                '</span>'+
                '<span class="stat-item"><span class="num rate">'+escapeHtml(report.T5PassRate)+'</span> rate</span>'+
                '<span class="stat-item"><span class="num purple">'+escapeHtml(report.T5CompletedPass)+'</span> compl</span>'+
                '</div>'+
                '<div style="font-size:13px;color:#6b7280;margin-top:2px">'+escapeHtml(report.T5Names)+'</div>':'');
            tr.appendChild(c3);
            var c4=document.createElement('td');c4.className='col-action';
            c4.innerHTML='<a href="/report/'+escapeHtml(report.FilePath)+'" class="btn-open" target="_blank">Open</a>';
            tr.appendChild(c4);
            tbody.appendChild(tr);
        })(filtered[i],i);
    }
    updateAggregates(filtered);
}
function updateAggregates(filtered){
    var passed=0,blown=0,active=0,trades=0,runs=0,rateSum=0,rateCount=0,backtestCount=0;
    var activeProfitSum=0,activeProfitCount=0,activeLossSum=0,activeLossCount=0;
    var fwdPassed=0,fwdBlown=0,fwdActive=0,fwdTrades=0,fwdRuns=0,fwdRateSum=0,fwdRateCount=0,fwdCount=0;
    var fwdActiveProfitSum=0,fwdActiveProfitCount=0,fwdActiveLossSum=0,fwdActiveLossCount=0;
    for(var i=0;i<filtered.length;i++){
        var p=parseInt(filtered[i].Passed)||0,b=parseInt(filtered[i].Blown)||0,a=parseInt(filtered[i].Active)||0;
        var t=parseInt(filtered[i].Trades)||0,r=parseInt(filtered[i].Runs)||0;
        var rt=parseFloat(filtered[i].PassRate)||0;
        var ap=parseFloat(filtered[i].ActiveProfit)||0, al=parseFloat(filtered[i].ActiveLoss)||0;
        if(filtered[i].IsForwardTest){
            fwdPassed+=p;fwdBlown+=b;fwdActive+=a;fwdTrades+=t;fwdRuns+=r;
            if(rt>0){fwdRateSum+=rt;fwdRateCount++;}fwdCount++;
            if(ap>0){fwdActiveProfitSum+=ap*a;fwdActiveProfitCount+=a;}
            if(al>0){fwdActiveLossSum+=al*a;fwdActiveLossCount+=a;}
        }else{
            passed+=p;blown+=b;active+=a;trades+=t;runs+=r;
            if(rt>0){rateSum+=rt;rateCount++;}backtestCount++;
            if(ap>0){activeProfitSum+=ap*a;activeProfitCount+=a;}
            if(al>0){activeLossSum+=al*a;activeLossCount+=a;}
        }
    }
    var avgRate=rateCount>0?(rateSum/rateCount).toFixed(1):'0.0';
    var resolved=passed+blown;var blowRate=resolved>0?((blown/resolved)*100).toFixed(1):'0.0';
    var completedPassRate=resolved>0?((passed/resolved)*100).toFixed(1):'0.0';
    var avgActiveProfit=activeProfitCount>0?(activeProfitSum/activeProfitCount).toFixed(1):'0';
    var avgActiveLoss=activeLossCount>0?(activeLossSum/activeLossCount).toFixed(1):'0';
    var bar=document.getElementById('aggregateStats');
    bar.innerHTML=
        '<div class="stat-card"><div class="val green">'+passed+'</div><div class="lbl">Passed</div></div>'+
        '<div class="stat-card"><div class="val red">'+blown+'</div><div class="lbl">Blown</div></div>'+
        '<div class="stat-card"><div class="val blue">'+active+'</div><div class="lbl">Active'+
        (active>0?' <span style="font-size:11px;color:#059669">'+avgActiveProfit+'% profit</span> <span style="font-size:11px;color:#6b7280">|</span> <span style="font-size:11px;color:#dc2626">'+avgActiveLoss+'% DD</span>':'')+
        '</div></div>'+
        '<div class="stat-card"><div class="val">'+avgRate+'%</div><div class="lbl">Avg Pass</div></div>'+
        '<div class="stat-card"><div class="val orange">'+blowRate+'%</div><div class="lbl">Blow Risk</div></div>'+
        '<div class="stat-card"><div class="val purple">'+completedPassRate+'%</div><div class="lbl">Completed Pass</div></div>'+
        '<div class="stat-card"><div class="val">'+trades+'</div><div class="lbl">Trades</div></div>'+
        '<div class="stat-card"><div class="val">'+runs+'</div><div class="lbl">Runs</div></div>'+
        '<div class="stat-card"><div class="val">'+backtestCount+'</div><div class="lbl">Reports</div></div>';
    var fwdAvgRate=fwdRateCount>0?(fwdRateSum/fwdRateCount).toFixed(1):'0.0';
    var fwdResolved=fwdPassed+fwdBlown;var fwdBlowRate=fwdResolved>0?((fwdBlown/fwdResolved)*100).toFixed(1):'0.0';
    var fwdCompletedPassRate=fwdResolved>0?((fwdPassed/fwdResolved)*100).toFixed(1):'0.0';
    var fwdAvgActiveProfit=fwdActiveProfitCount>0?(fwdActiveProfitSum/fwdActiveProfitCount).toFixed(1):'0';
    var fwdAvgActiveLoss=fwdActiveLossCount>0?(fwdActiveLossSum/fwdActiveLossCount).toFixed(1):'0';
    var fwdBar=document.getElementById('forwardAggregateStats');
    fwdBar.innerHTML=
        '<div class="stat-card"><div class="val green">'+fwdPassed+'</div><div class="lbl">Passed</div></div>'+
        '<div class="stat-card"><div class="val red">'+fwdBlown+'</div><div class="lbl">Blown</div></div>'+
        '<div class="stat-card"><div class="val blue">'+fwdActive+'</div><div class="lbl">Active'+
        (fwdActive>0?' <span style="font-size:11px;color:#059669">'+fwdAvgActiveProfit+'% profit</span> <span style="font-size:11px;color:#6b7280">|</span> <span style="font-size:11px;color:#dc2626">'+fwdAvgActiveLoss+'% DD</span>':'')+
        '</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdAvgRate+'%</div><div class="lbl">Avg Pass</div></div>'+
        '<div class="stat-card"><div class="val orange">'+fwdBlowRate+'%</div><div class="lbl">Blow Risk</div></div>'+
        '<div class="stat-card"><div class="val purple">'+fwdCompletedPassRate+'%</div><div class="lbl">Completed Pass</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdTrades+'</div><div class="lbl">Trades</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdRuns+'</div><div class="lbl">Runs</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdCount+'</div><div class="lbl">Reports</div></div>';
}
function loadData(refresh){
    var url=refresh?'/api/refresh':'/api/reports';
    var sb=document.getElementById('statusBar');
    var st=document.getElementById('statusText');
    var btn=document.getElementById('refreshBtn');
    st.textContent=refresh?'Scanning reports (may take 20-30s)...':'Loading...';sb.classList.add('show');
    btn.disabled=true;btn.textContent='\\u{21BB} Please wait...';
    fetch(url).then(function(r){
        if(!r.ok)throw new Error('Server returned '+r.status);
        return r.json();
    }).then(function(data){
        reports=data;
        var sd={};sd['date']='desc';
        reports.sort(function(a,b){return sortKey(b).localeCompare(sortKey(a))});
        render();
        sb.classList.remove('show');
        btn.disabled=false;btn.textContent='\\u{21BB} Refresh';
        document.getElementById('footerDate').textContent=new Date().toLocaleString();
    }).catch(function(err){
        st.textContent='Error: '+err.message+' — Make sure the server is running.';
        sb.style.color='#dc2626';
        btn.disabled=false;btn.textContent='\\u{21BB} Refresh';
        setTimeout(function(){sb.classList.remove('show');sb.style.color=''},8000);
    });
    if(refresh){setTimeout(function(){
        if(btn.disabled){st.textContent='Still scanning... large report set. Please wait.';}
    },15000);}
}
document.addEventListener('DOMContentLoaded',function(){
    var sortDir={};
    document.querySelectorAll('thead th[data-sort]').forEach(function(th){
        th.addEventListener('click',function(){
            var key=th.getAttribute('data-sort');
            if(key==='action')return;
            sortDir[key]=sortDir[key]==='asc'?'desc':'asc';
            var dir=sortDir[key];
            document.querySelectorAll('thead th').forEach(function(h){h.classList.remove('sorted')});
            th.classList.add('sorted');
            reports.sort(function(a,b){
                if(key==='num'){var va=parseInt(a.Passed)||0,vb=parseInt(b.Passed)||0;return dir==='asc'?va-vb:vb-va;}
                if(key==='date'){return dir==='desc'?sortKey(b).localeCompare(sortKey(a)):sortKey(a).localeCompare(sortKey(b));}
                if(key==='stats'){var ra=parseFloat(a.PassRate)||0,rb=parseFloat(b.PassRate)||0;return dir==='asc'?ra-rb:rb-ra;}
                return 0;
            });
            render();
        });
    });
    document.getElementById('searchInput').addEventListener('input',function(){currentSearch=this.value;render()});
    document.querySelectorAll('.btn[data-filter]').forEach(function(btn){
        btn.addEventListener('click',function(){
            document.querySelectorAll('.btn[data-filter]').forEach(function(b){b.classList.remove('active')});
            this.classList.add('active');currentFilter=this.getAttribute('data-filter');render();
        });
    });
    document.getElementById('refreshBtn').addEventListener('click',function(){loadData(true)});
    loadData(false);
});
</script>
</body>
</html>"""

class Handler(BaseHTTPRequestHandler):
    reports = []

    def do_GET(self):
        self._serve_content(send_body=True)

    def do_HEAD(self):
        self._serve_content(send_body=False)

    def _serve_content(self, send_body):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")

        if path == "/api/reports":
            data = json.dumps(self.__class__.reports).encode("utf-8")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)

        elif path == "/api/refresh":
            self.__class__.reports = scan_reports()
            data = json.dumps(self.__class__.reports).encode("utf-8")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)

        elif path.startswith("/report/"):
            fname = path[len("/report/"):]
            fpath = os.path.normpath(os.path.join(REPORT_DIR, fname))
            if fpath.startswith(os.path.normpath(REPORT_DIR)) and os.path.isfile(fpath):
                content = None
                for enc in ("utf-16", "utf-8", "latin-1"):
                    try:
                        with open(fpath, "r", encoding=enc) as f:
                            content = f.read()
                        break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
                if content is None:
                    self.send_response(500)
                    data = b"Could not decode file"
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    if send_body:
                        self.wfile.write(data)
                    return
                data = content.encode("utf-8")
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if send_body:
                    self.wfile.write(data)
            else:
                self.send_response(404)
                data = b"Report not found"
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if send_body:
                    self.wfile.write(data)

        else:
            data = DASHBOARD_HTML.encode("utf-8")
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)

    def log_message(self, fmt, *args):
        if len(args) >= 3:
            print(f"[{self.log_date_time_string()}] {args[0]} {args[1]} {args[2]}")
        else:
            print(f"[{self.log_date_time_string()}] {fmt % args}")

if __name__ == "__main__":
    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    result = sock.connect_ex(("127.0.0.1", PORT))
    sock.close()
    if result == 0:
        print(f"Port {PORT} is already in use. Maybe the server is already running?")
        print(f"Open http://localhost:{PORT} in Chrome.")
        exit(1)

    print(f"Pre-scanning reports...", end=" ", flush=True)
    Handler.reports = scan_reports()
    print(f"{len(Handler.reports)} reports cached.")
    print(f"Dashboard server running at http://localhost:{PORT}")
    print("Press Ctrl+C to stop the server")

    import threading, webbrowser
    threading.Timer(1.0, lambda: webbrowser.open(f"http://localhost:{PORT}")).start()

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
        server.server_close()
