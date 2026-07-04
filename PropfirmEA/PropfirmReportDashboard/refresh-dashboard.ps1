$reportDir = "C:\Users\Satyam.RAJ.000\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
$files = Get-ChildItem -Path $reportDir -Filter "Propfirm_*_Report_*.html" | Where-Object { $_.Name -like "Propfirm_*_Report_*.html" -and $_.Name -notlike "dashboard*" } | Sort-Object Name -Descending

$reports = @()
foreach ($f in $files) {
    $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8
    if (-not $content) { continue }

    function ExtractKv($html, $key) {
        $m = [regex]::Match($html, '<div class="kv"><span class="k">' + [regex]::Escape($key) + '</span><span class="v">([^<]+)</span></div>')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return ""
    }

    function ExtractCard($html, $class, $label) {
        $m = [regex]::Match($html, '<div class="card ' + [regex]::Escape($class) + '"><div class="label">' + [regex]::Escape($label) + '</div><div class="value">([^<]+)</div>')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return ""
    }

    $symbol = ExtractKv $content "Symbol"
    $period = ExtractKv $content "Period"
    $spawnInterval = ExtractKv $content "Spawn Interval"
    $rollingMode = ExtractKv $content "Rolling Start Mode"
    $testStarted = ExtractKv $content "Test Started"
    $reportGenerated = ExtractKv $content "Report Generated"
    $totalStrategies = ExtractKv $content "Total Strategies"
    $totalRunsSim = ExtractKv $content "Total Runs Simulated"
    $propMode = ExtractKv $content "Prop Strategy Mode"

    $passed = ExtractCard $content "pass" "Passed Runs"
    $blown = ExtractCard $content "blow" "Blown Runs"
    $active = ExtractCard $content "act" "Active Runs"
    $passRate = ExtractCard $content "rate" "Overall Pass Rate"
    $trades = ExtractCard $content "avg" "Total Trades"
    $signals = ExtractCard $content "sig" "Total Signals"
    $runs = ExtractCard $content "tot" "Total Runs"

    $topStrat = ""
    $topRecency = ""
    $topAlltime = ""
    $recMatch = [regex]::Match($content, '<div class="card rec"><div class="label">Top Strategy \(Recent\)</div><div class="value"[^>]*>([^<]+)</div><div class="sub">Recency:\s*([^%]+)%[^&]*&nbsp;\|&nbsp;\s*All-time:\s*([^%]+)%')
    if ($recMatch.Success) {
        $topStrat = $recMatch.Groups[1].Value.Trim()
        $topRecency = $recMatch.Groups[2].Value.Trim()
        $topAlltime = $recMatch.Groups[3].Value.Trim()
    }

    $topPersistStrat = ""
    $topPersistScore = ""
    $persistMatch = [regex]::Match($content, '<div class="card persist"><div class="label">Top Strategy \(Persistence\)</div><div class="value"[^>]*>([^<]+)</div><div class="sub">Score:\s*([^<]+)</div>')
    if ($persistMatch.Success) {
        $topPersistStrat = $persistMatch.Groups[1].Value.Trim()
        $topPersistScore = $persistMatch.Groups[2].Value.Trim()
    }

    $reportTitle = ""
    $titleMatch = [regex]::Match($content, '<h1>([^<]+)</h1>')
    if ($titleMatch.Success) { $reportTitle = $titleMatch.Groups[1].Value.Trim() }
    $isForwardTest = ($reportTitle -like "*Forward*") -or ($propMode -like "*CUSTOM*")

    $generated = ""
    $genMatch = [regex]::Match($content, 'Generated:\s*([^<]+)</div>')
    if ($genMatch.Success) { $generated = $genMatch.Groups[1].Value.Trim() }

    $bestStrat = ""
    $bestRate = ""
    $noteMatch = [regex]::Match($content, 'Best strategy:\s*<b>([^<]+)</b>\s*\(([^)]+)\)')
    if ($noteMatch.Success) {
        $bestStrat = $noteMatch.Groups[1].Value.Trim()
        $bestRate = $noteMatch.Groups[2].Value.Trim()
    }

    $top5Codes = @()
    $tableStart = $content.IndexOf('<table id="strat">')
    if ($tableStart -ge 0) {
        $tableContent = $content.Substring($tableStart)
        $codeMatches = [regex]::Matches($tableContent, "onclick=\x22filterRuns\('(\d+)_")
        for ($i = 0; $i -lt [Math]::Min(5, $codeMatches.Count); $i++) {
            $top5Codes += $codeMatches[$i].Groups[1].Value
        }
    }

    $reports += @{
        Filename = $f.Name
        FilePath = $f.Name
        FileTime = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        Symbol = $symbol
        Period = $period
        SpawnInterval = $spawnInterval
        RollingMode = $rollingMode
        TestStarted = $testStarted
        ReportGenerated = $reportGenerated
        TotalStrategies = $totalStrategies
        TotalRunsSim = $totalRunsSim
        PropMode = $propMode
        Passed = $passed
        Blown = $blown
        Active = $active
        PassRate = $passRate
        Trades = $trades
        Signals = $signals
        Runs = $runs
        TopStrat = $topStrat
        TopRecency = $topRecency
        TopAlltime = $topAlltime
        TopPersistStrat = $topPersistStrat
        TopPersistScore = $topPersistScore
        ReportTitle = $reportTitle
        Generated = $generated
        BestStrat = $bestStrat
        BestRate = $bestRate
        Top5Codes = $top5Codes
        IsForwardTest = $isForwardTest
    }
}

$jsonData = $reports | ConvertTo-Json -Depth 3

$dashboardHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
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
</style>
</head>
<body>
<div class="wrap">
<div class="header">
<div>
<h1>Prop Backtester Reports Hub</h1>
<div class="sub">Propfirm virtual simulation reports</div>
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
<a href="refresh-dashboard.bat" class="btn" onclick="return confirm('Re-scan all reports and regenerate?')">&#x21bb; Refresh Data</a>
</div>

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
<div class="footer">Double-click <code>refresh-dashboard.bat</code> or click Refresh above &mdash; <span id="footerDate"></span></div>
</div>

<script>
var reports = $jsonData;

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
    if(f==='fwd')return r.Filename.indexOf('Forward_Test')>=0;
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
                '<div class="meta">'+escapeHtml(report.Symbol)+' <span>'+escapeHtml(periodShort)+'</span> '+tag+' '+escapeHtml(totalStrats)+' &middot; '+escapeHtml(rollLabel)+(spawnShort?' <span class="spawn-badge">'+escapeHtml(spawnShort)+'</span>':'')+(report.PropMode?' <span class="prop">'+escapeHtml(report.PropMode)+'</span>':'')+(report.IsForwardTest?' <span class="fwd-label">&#10132;&#10132; forward test</span>':'')+'</div>';
            tr.appendChild(c2);
            var c3=document.createElement('td');c3.className='col-stats';
            c3.innerHTML='<div class="stat-row">'+
                '<span class="lbl">Total Runs <b>'+escapeHtml(report.TotalRunsSim)+'</b></span>'+
                '<span class="stat-item"><span class="num pass">'+passed+'</span> passed</span>'+
                '<span class="stat-item"><span class="num blow">'+blown+'</span> blown</span>'+
                '<span class="stat-item"><span class="num act">'+active+'</span> active</span>'+
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
                var html='<div class="top5">';
                for(var ci=0;ci<codes.length;ci++){html+='<span class="code r'+(ci+1)+'">'+codes[ci]+'</span>'}
                var copyStr='';for(var ci=0;ci<codes.length;ci++){if(ci>0)copyStr+=',';copyStr+=('000'+codes[ci]).slice(-3)}
                html+='<button class="btn-copy" data-codes="'+escapeHtml(copyStr)+'" onclick="copyCodes(this)">Copy</button></div>';
                return html;
            }(report.Top5Codes):'');
            tr.appendChild(c3);
            var c4=document.createElement('td');c4.className='col-action';
            c4.innerHTML='<a href="'+escapeHtml(report.FilePath)+'" class="btn-open" target="_blank">Open</a>';
            tr.appendChild(c4);
            tbody.appendChild(tr);
        })(filtered[i],i);
    }
    updateAggregates(filtered);
}

function updateAggregates(filtered){
    var passed=0,blown=0,active=0,trades=0,runs=0,rateSum=0,rateCount=0,backtestCount=0;
    var fwdPassed=0,fwdBlown=0,fwdActive=0,fwdTrades=0,fwdRuns=0,fwdRateSum=0,fwdRateCount=0,fwdCount=0;
    for(var i=0;i<filtered.length;i++){
        var p=parseInt(filtered[i].Passed)||0,b=parseInt(filtered[i].Blown)||0,a=parseInt(filtered[i].Active)||0;
        var t=parseInt(filtered[i].Trades)||0,r=parseInt(filtered[i].Runs)||0;
        var rt=parseFloat(filtered[i].PassRate)||0;
        if(filtered[i].IsForwardTest){
            fwdPassed+=p;fwdBlown+=b;fwdActive+=a;fwdTrades+=t;fwdRuns+=r;
            if(rt>0){fwdRateSum+=rt;fwdRateCount++;}fwdCount++;
        }else{
            passed+=p;blown+=b;active+=a;trades+=t;runs+=r;
            if(rt>0){rateSum+=rt;rateCount++;}backtestCount++;
        }
    }
    var avgRate=rateCount>0?(rateSum/rateCount).toFixed(1):'0.0';
    var resolved=passed+blown;var blowRate=resolved>0?((blown/resolved)*100).toFixed(1):'0.0';
    var completedPassRate=resolved>0?((passed/resolved)*100).toFixed(1):'0.0';
    var bar=document.getElementById('aggregateStats');
    bar.innerHTML=
        '<div class="stat-card"><div class="val green">'+passed+'</div><div class="lbl">Passed</div></div>'+
        '<div class="stat-card"><div class="val red">'+blown+'</div><div class="lbl">Blown</div></div>'+
        '<div class="stat-card"><div class="val blue">'+active+'</div><div class="lbl">Active</div></div>'+
        '<div class="stat-card"><div class="val">'+avgRate+'%</div><div class="lbl">Avg Pass</div></div>'+
        '<div class="stat-card"><div class="val orange">'+blowRate+'%</div><div class="lbl">Blow Risk</div></div>'+
        '<div class="stat-card"><div class="val purple">'+completedPassRate+'%</div><div class="lbl">Completed Pass</div></div>'+
        '<div class="stat-card"><div class="val">'+trades+'</div><div class="lbl">Trades</div></div>'+
        '<div class="stat-card"><div class="val">'+runs+'</div><div class="lbl">Runs</div></div>'+
        '<div class="stat-card"><div class="val">'+backtestCount+'</div><div class="lbl">Reports</div></div>';
    var fwdAvgRate=fwdRateCount>0?(fwdRateSum/fwdRateCount).toFixed(1):'0.0';
    var fwdResolved=fwdPassed+fwdBlown;var fwdBlowRate=fwdResolved>0?((fwdBlown/fwdResolved)*100).toFixed(1):'0.0';
    var fwdCompletedPassRate=fwdResolved>0?((fwdPassed/fwdResolved)*100).toFixed(1):'0.0';
    var fwdBar=document.getElementById('forwardAggregateStats');
    fwdBar.innerHTML=
        '<div class="stat-card"><div class="val green">'+fwdPassed+'</div><div class="lbl">Passed</div></div>'+
        '<div class="stat-card"><div class="val red">'+fwdBlown+'</div><div class="lbl">Blown</div></div>'+
        '<div class="stat-card"><div class="val blue">'+fwdActive+'</div><div class="lbl">Active</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdAvgRate+'%</div><div class="lbl">Avg Pass</div></div>'+
        '<div class="stat-card"><div class="val orange">'+fwdBlowRate+'%</div><div class="lbl">Blow Risk</div></div>'+
        '<div class="stat-card"><div class="val purple">'+fwdCompletedPassRate+'%</div><div class="lbl">Completed Pass</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdTrades+'</div><div class="lbl">Trades</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdRuns+'</div><div class="lbl">Runs</div></div>'+
        '<div class="stat-card"><div class="val">'+fwdCount+'</div><div class="lbl">Reports</div></div>';
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

    sortDir['date']='desc';
    reports.sort(function(a,b){return sortKey(b).localeCompare(sortKey(a))});
    document.getElementById('footerDate').textContent=new Date().toLocaleString();
    render();
});
</script>
</body>
</html>
"@

$dashboardPath = Join-Path $reportDir "dashboard.html"
Set-Content -Path $dashboardPath -Value $dashboardHtml -Encoding UTF8
Write-Host "Dashboard generated: $dashboardPath"
Write-Host "Reports found: $($reports.Count)"
$fileUri = [System.Uri]::new($dashboardPath).AbsoluteUri + "?t=" + (Get-Date -Format "yyyyMMddHHmmss")
Start-Process $fileUri
