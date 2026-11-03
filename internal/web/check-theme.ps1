# Checks the dashboard's spider-web theme in headless Microsoft Edge over
# the DevTools protocol (no install: Edge ships with Windows). Edge runs on
# CPUs 12-15 at low priority so it stays off the replicas' cores.
#
# Checked: naming; both charts' tops visible without scrolling; the empty
# charts' text; the offline banner's start command; the corner webs spinning
# in and then staying still; the theme toggle by keyboard (Tab, Enter, Space)
# and mouse, its stored choice and labels; the webs trembling in proportion to
# the request rate; Calm (manual, automatic on real replicas, overridable);
# hidden tab; reduced motion.
#
#   ./internal/web/check-theme.ps1                                # the static files
#   ./internal/web/check-theme.ps1 -Url http://127.0.0.1:8090/    # a running demo
#   ./internal/web/check-theme.ps1 -Width 1920 -Height 1080
param(
  [string]$Url = ('file:///' + ((Join-Path $PSScriptRoot 'static/index.html') -replace '\\', '/')),
  [string]$Shots = $env:TEMP,
  [int]$Port = 9333, [int]$Width = 1366, [int]$Height = 768,
  [string]$Edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
)
$ErrorActionPreference = 'Stop'
$prof = Join-Path $env:TEMP 'tenantscaler-theme-check'
if (Test-Path $prof) { Remove-Item -Recurse -Force $prof }
# A throwaway InPrivate profile: no sign-in, no sync, no extensions (a fresh
# normal profile signs in with the Windows account and syncs its extensions).
$isolate = '--inprivate --no-first-run --no-default-browser-check --disable-extensions --disable-sync --disable-features=msImplicitSignin,msEdgeSyncConsent'
# Start-Process, not a direct cmd call: Edge must not inherit this script's
# output pipe, or a caller that pipes the output waits until Edge exits.
Start-Process -FilePath cmd.exe -WindowStyle Hidden -ArgumentList "/c start `"`" /low /affinity F000 `"$Edge`" --headless=new $isolate --user-data-dir=`"$prof`" --remote-debugging-port=$Port --window-size=$Width,$Height `"$Url`""
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; try { Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 | Out-Null; break } catch {} }

try {
  # Drive only the tab this script opened.
  $tabs = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 5
  $page = $tabs | Where-Object { $_.type -eq 'page' -and $_.url -like "$($Url.TrimEnd('/'))*" } | Select-Object -First 1
  if (-not $page) { throw "the dashboard tab is not among the DevTools targets on port $Port (another browser on that port?)" }
  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  if (-not $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(10000)) { throw "DevTools connection timed out" }
  $script:id = 0

  function Receive-Msg {
    $buf = New-Object byte[] 1048576
    $ms = New-Object System.IO.MemoryStream
    do {
      $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
      $r = $ws.ReceiveAsync($seg, [Threading.CancellationTokenSource]::new(20000).Token).Result
      $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
  }

  function Cdp($method, $params = @{}) {
    $script:id++
    $json = @{ id = $script:id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).Wait()
    while ($true) {
      $m = Receive-Msg
      if ($m.id -eq $script:id) {
        if ($m.error) { throw "$method failed: $($m.error.message)" }
        return $m.result
      }
    }
  }

  function Eval($expr) {
    $r = Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
    if ($r.exceptionDetails) { throw "eval failed: $expr :: $($r.exceptionDetails.text) $($r.exceptionDetails.exception.description)" }
    $r.result.value
  }

  function Key($key, $code, $vk, $text) {
    $down = @{ type = 'keyDown'; key = $key; code = $code; windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk }
    if ($text) { $down.text = $text }
    Cdp 'Input.dispatchKeyEvent' $down | Out-Null
    Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $key; code = $code; windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk } | Out-Null
  }

  function Shot($name) {
    $r = Cdp 'Page.captureScreenshot' @{ format = 'png' }
    [IO.File]::WriteAllBytes((Join-Path $Shots $name), [Convert]::FromBase64String($r.data))
  }

  function Media($extra) {
    $f = @(@{ name = 'prefers-color-scheme'; value = 'dark' })
    if ($extra) { $f += $extra }
    Cdp 'Emulation.setEmulatedMedia' @{ features = $f } | Out-Null
  }

  # Frames drawn by the 2D webs (decor) over $ms.
  function Frames($ms) {
    Eval "new Promise(r => { const d0 = TS.Decor.frames(); setTimeout(() => r(JSON.stringify({decor: TS.Decor.frames() - d0})), $ms); })" | ConvertFrom-Json
  }

  # WaitReady waits until the page's scripts have run.
  function WaitReady {
    for ($i = 0; $i -lt 600; $i++) {
      if (Eval "!!(window.TS && TS.Decor)") { break }
      Start-Sleep -Milliseconds 50
    }
  }

  $results = [ordered]@{}
  function Check($name, $ok, $detail) { $results[$name] = $(if ($ok) { "PASS" } else { "FAIL" }) + "  $detail" }

  # Wait until the tab shows the dashboard itself (not the blank start page).
  for ($i = 0; $i -lt 300; $i++) {
    try { if (Eval "document.readyState === 'complete' && !!document.getElementById('theme-toggle')") { break } } catch {}
    Start-Sleep -Milliseconds 100
  }
  Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false } | Out-Null
  Media
  Cdp 'Page.enable' | Out-Null
  Eval "localStorage.clear(); location.reload(); true" | Out-Null
  Start-Sleep -Milliseconds 100
  WaitReady
  Start-Sleep -Milliseconds 200
  $spin0 = Eval "TS.Decor.frames()"
  Start-Sleep -Milliseconds 1500
  $spin1 = Eval "TS.Decor.frames()"
  Start-Sleep -Milliseconds 1000
  $spin2 = Eval "TS.Decor.frames()"
  Check 'corner webs spin in, then stay still' ($spin1 -gt $spin0 -and $spin2 -eq $spin1) "frames at +0.2 s: $spin0, +1.7 s: $spin1, +2.7 s: $spin2"
  Check 'spin-in at <= 30 fps' ((($spin1 - $spin0) / 1.3) -le 30.5) "$([math]::Round(($spin1 - $spin0) / 1.3, 1)) frames/s"
  Shot "theme-dark-$($Width)x$($Height).png"

  $st = "JSON.stringify({theme: document.documentElement.dataset.theme, label: document.getElementById('theme-toggle').getAttribute('aria-label'), stored: localStorage.getItem('tenantscaler-theme'), calm: document.getElementById('calm-toggle').getAttribute('aria-checked'), svg: getComputedStyle(document.querySelector('.spider-toggle .spider')).visibility})"
  $s0 = Eval $st | ConvertFrom-Json
  Check 'first load follows prefers-color-scheme (dark)' ($s0.theme -eq 'dark' -and $s0.stored -eq $null -and $s0.label -eq 'Switch to light theme') ($s0 | ConvertTo-Json -Compress)

  # Naming and layout.
  $names = Eval "JSON.stringify({title: document.title, mark: getComputedStyle(document.querySelector('.wordmark')).textTransform, tab: document.getElementById('tab-ab').innerText, run: document.getElementById('run-btn').innerText, h2: document.getElementById('h-baseline').innerText})" | ConvertFrom-Json
  Check 'naming: TenantScaler, acronyms in caps, sentence case' ($names.title -eq 'TenantScaler A/B demo' -and $names.mark -eq 'none' -and $names.tab -eq 'Live A/B' -and $names.run -eq 'Run A/B' -and $names.h2 -eq 'Baseline: queue-based KEDA') ($names | ConvertTo-Json -Compress)
  $tops = Eval "JSON.stringify(Array.from(document.querySelectorAll('canvas[data-role=ttft]')).map(c => Math.round(c.getBoundingClientRect().top)).concat([innerHeight]))" | ConvertFrom-Json
  Check "both charts' tops visible at $($Width)x$($Height)" ($tops[0] -lt $tops[2] - 20 -and $tops[1] -lt $tops[2] - 20) "chart tops $($tops[0]) and $($tops[1]) px, viewport $($tops[2]) px"
  $aria = Eval "document.querySelector('canvas[data-role=ttft]').getAttribute('aria-label')"
  Check 'empty chart says what to do' ($aria -like '*Waiting for a run: press Run A/B*') $aria
  $banner = Eval "(() => { const b = document.getElementById('conn-error'); return b.hidden ? '' : b.innerText; })()"
  if ($banner) {
    Check 'offline banner shows the start command' ($banner -like '*run-demo.ps1*' -and $banner -like '*tenantscaler.exe demo*') $banner
    $off = Eval "JSON.stringify({pill: document.getElementById('backend-badge').innerText, badges: Array.from(document.querySelectorAll('.panel .status')).map(s => s.innerText), loading: /Loading/.test(document.body.innerText)})" | ConvertFrom-Json
    Check 'offline: pill and panel badges say Offline, no Loading text' ($off.pill -eq 'Offline' -and ($off.badges | Where-Object { $_ -ne 'Offline' }).Count -eq 0 -and -not $off.loading) ($off | ConvertTo-Json -Compress)
  }

  # Toggle by keyboard: Tab to the spider, Enter.
  $found = $false
  for ($i = 0; $i -lt 14; $i++) {
    Key 'Tab' 'Tab' 9 $null
    if ((Eval "document.activeElement && document.activeElement.id") -eq 'theme-toggle') { $found = $true; break }
  }
  $ring = Eval "getComputedStyle(document.getElementById('theme-toggle')).outlineStyle + ' ' + getComputedStyle(document.getElementById('theme-toggle')).outlineWidth"
  Check 'spider reachable by Tab, focus ring visible' ($found -and $ring -like 'solid*') "after $($i + 1) Tab presses; outline $ring"
  Key 'Enter' 'Enter' 13 "`r"
  Start-Sleep -Milliseconds 200
  Shot "theme-drop.png"
  $midSvg = Eval "getComputedStyle(document.querySelector('.spider-toggle .spider')).transform"
  Start-Sleep -Milliseconds 1500
  $s1 = Eval $st | ConvertFrom-Json
  Check 'Enter switches to light, stores it, relabels' ($s1.theme -eq 'light' -and $s1.stored -eq 'light' -and $s1.label -eq 'Switch to dark theme') ($s1 | ConvertTo-Json -Compress)
  Check 'the spider drops on its thread' ($midSvg -ne 'none' -and $s0.svg -eq 'visible') "SVG spider transform 200 ms after Enter: $midSvg"
  Key ' ' 'Space' 32 ' '
  Start-Sleep -Milliseconds 1800
  $s2 = Eval $st | ConvertFrom-Json
  Check 'Space switches back to dark' ($s2.theme -eq 'dark' -and $s2.stored -eq 'dark') ($s2 | ConvertTo-Json -Compress)
  $rect = Eval "(() => { const r = document.getElementById('theme-toggle').getBoundingClientRect(); return JSON.stringify({x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height}); })()" | ConvertFrom-Json
  Check 'hit area is at least 44 x 44' ($rect.w -ge 44 -and $rect.h -ge 44) "$($rect.w) x $($rect.h)"
  foreach ($t in 'mousePressed', 'mouseReleased') { Cdp 'Input.dispatchMouseEvent' @{ type = $t; x = $rect.x; y = $rect.y; button = 'left'; clickCount = 1 } | Out-Null }
  Start-Sleep -Milliseconds 1800
  $s3 = Eval $st | ConvertFrom-Json
  Check 'mouse click switches to light' ($s3.theme -eq 'light') ($s3 | ConvertTo-Json -Compress)
  Shot "theme-light-$($Width)x$($Height).png"
  Eval "location.reload(); true" | Out-Null
  Start-Sleep -Milliseconds 100
  WaitReady
  Start-Sleep -Milliseconds 2000
  $s4 = Eval $st | ConvertFrom-Json
  Check 'stored choice survives reload (system is dark)' ($s4.theme -eq 'light') ($s4 | ConvertTo-Json -Compress)

  # Tremble: amplitude proportional to each stack's request rate. The test
  # rates are re-applied every 100 ms, so the page's own state polls (an
  # idle demo) cannot overwrite them mid-measurement.
  $tr = Eval "new Promise(r => { let rates = {baseline: 0.8, tenantscaler: 0}; window.__hold = setInterval(() => TS.Decor.setActivity({running: true, real: false, rates}), 100); setTimeout(() => { const a = TS.Decor.amplitudes(); rates = {baseline: 3.6, tenantscaler: 0}; setTimeout(() => r(JSON.stringify({before: a, spike: TS.Decor.amplitudes()})), 1500); }, 1500); })" | ConvertFrom-Json
  $b = $tr.before | Where-Object { $_.stack -eq 'baseline' } | Select-Object -First 1
  $sp = $tr.spike | Where-Object { $_.stack -eq 'baseline' } | Select-Object -First 1
  $ts = $tr.spike | Where-Object { $_.stack -eq 'tenantscaler' } | Select-Object -First 1
  Check 'tremble proportional to request rate (2 px per req/s)' ([math]::Abs($b.target - 1.6) -lt 0.01 -and [math]::Abs($sp.target - 7.2) -lt 0.01 -and $sp.amp -gt 3 * $b.amp -and $ts.amp -eq 0) "targets $($b.target) and $($sp.target) px; amplitude at 0.8 req/s: $([math]::Round($b.amp, 2)) px, at 3.6 req/s: $([math]::Round($sp.amp, 2)) px; idle stack: $($ts.amp) px"
  Shot "theme-tremble.png"
  $trf = Frames 1500
  Eval "clearInterval(window.__hold); true" | Out-Null
  Check 'tremble at <= 30 fps' ($trf.decor -gt 0 -and ($trf.decor / 1.5) -le 30.5) "$([math]::Round($trf.decor / 1.5, 1)) frames/s"
  $calm1 = Eval "new Promise(r => { document.getElementById('calm-toggle').click(); const d0 = TS.Decor.frames(); setTimeout(() => r(JSON.stringify({calm: document.getElementById('calm-toggle').getAttribute('aria-checked'), frames: TS.Decor.frames() - d0})), 1200); })" | ConvertFrom-Json
  Check 'Calm on: tremble stops' ($calm1.calm -eq 'true' -and $calm1.frames -eq 0) ($calm1 | ConvertTo-Json -Compress)
  Eval "document.getElementById('theme-toggle').click(); true" | Out-Null
  Start-Sleep -Milliseconds 60
  $cs = Eval "JSON.stringify({theme: document.documentElement.dataset.theme, drop: document.getElementById('theme-toggle').classList.contains('drop')})" | ConvertFrom-Json
  Check 'Calm: theme switches at once, no animation' ($cs.theme -eq 'dark' -and -not $cs.drop) ($cs | ConvertTo-Json -Compress)
  Eval "document.getElementById('calm-toggle').click(); TS.Decor.setActivity({running: false}); true" | Out-Null

  # Auto Calm on real replicas, overridable; reset after the run.
  $auto = Eval "new Promise(r => { TS.Decor.setActivity({running: true, real: true, rates: {baseline: 0, tenantscaler: 3}}); const b = document.getElementById('calm-toggle'); const on = {checked: b.getAttribute('aria-checked'), note: !document.getElementById('calm-note').hidden}; b.click(); const d0 = TS.Decor.frames(); setTimeout(() => { const off = {checked: b.getAttribute('aria-checked'), frames: TS.Decor.frames() - d0}; TS.Decor.setActivity({running: false}); r(JSON.stringify({on, off, after: b.getAttribute('aria-checked')})); }, 1000); })" | ConvertFrom-Json
  Check 'auto Calm on real replicas, can be switched off, reset after' ($auto.on.checked -eq 'true' -and $auto.on.note -and $auto.off.checked -eq 'false' -and $auto.off.frames -gt 0 -and $auto.after -eq 'false') ($auto | ConvertTo-Json -Compress)

  # Hidden tab: nothing draws.
  $hid = Eval "new Promise(r => { TS.Decor.setActivity({running: true, real: false, rates: {baseline: 3, tenantscaler: 3}}); Object.defineProperty(document, 'hidden', {configurable: true, get: () => true}); document.dispatchEvent(new Event('visibilitychange')); const d0 = TS.Decor.frames(); setTimeout(() => { const n = {decor: TS.Decor.frames() - d0}; delete document.hidden; document.dispatchEvent(new Event('visibilitychange')); TS.Decor.setActivity({running: false}); r(JSON.stringify(n)); }, 1500); })" | ConvertFrom-Json
  Check 'hidden tab: no frames' ($hid.decor -eq 0) ($hid | ConvertTo-Json -Compress)

  # Comic layer: chrome only, data stays plain.
  $cm = Eval "(async () => { await document.fonts.ready; const cs = (sel, p) => { const e = document.querySelector(sel); return e ? getComputedStyle(e)[p] : ''; }; return JSON.stringify({font: document.fonts.check('1em Bangers'), h2: cs('#h-baseline', 'fontFamily'), h2shadow: cs('#h-baseline', 'textShadow'), body: cs('.setup', 'textShadow'), th: cs('.panel th', 'fontFamily'), border: cs('.panel', 'borderTopWidth'), shadow: cs('.panel', 'boxShadow'), head: cs('.panel-head', 'backgroundImage'), chart: cs('.chart-box', 'backgroundImage'), table: cs('.panel table', 'backgroundImage'), legend: cs('.legend', 'fontFamily')}); })()" | ConvertFrom-Json
  Check 'comic: Bangers headings with misregistration' ($cm.font -and $cm.h2 -like '*Bangers*' -and $cm.h2shadow -like '*rgba*rgba*' -and $cm.body -eq 'none') "font loaded $($cm.font); h2 $($cm.h2); shadow $($cm.h2shadow); body text shadow $($cm.body)"
  Check 'comic: ink panels, halftone in headers only' ($cm.shadow -like '*0px 0px 0px 2.5px*' -and $cm.shadow -like '*4px 4px 0px 2.5px*' -and $cm.head -like '*radial-gradient*' -and $cm.chart -eq 'none' -and $cm.table -eq 'none') "outline and shadow $($cm.shadow); chart $($cm.chart); table $($cm.table)"
  Check 'comic: tables and legends keep the body font' ($cm.th -notlike '*Bangers*' -and $cm.legend -notlike '*Bangers*') "th $($cm.th)"
  # Captions from decision records (a test reply, as /api/decisions sends them).
  $cap = Eval "new Promise(r => { const rec = (cycle, tenant, demand, grant, shedding) => ({cycle, tenant, time: new Date().toISOString(), policyVersion: cycle, failStatic: false, reason: 'test', steps: [{rule: 'guarantee', grant}], inputs: {demand, guaranteed: 1}, final: {grant, shedding, weight: 1}}); TS.Comic.configure({scenario: {noisy: 'C'}, poolRecordTenant: 'pool'}); TS.Comic.read({trafficStartedAt: 'check-' + Date.now(), records: [rec(2, 'C', 3, 1, true), rec(1, 'C', 1, 1, false)]}); setTimeout(() => { const b = document.getElementById('caption-box'); r(JSON.stringify({shown: !b.hidden, text: b.innerText, mirrored: TS.Comic.captionsFor('2/C')})); }, 400); })" | ConvertFrom-Json
  Check 'comic: caption from the decision log, mirrored in the log' ($cap.shown -and $cap.text -like 'Tenant C spike detected*3 replicas*' -and @($cap.mirrored).Count -eq 2) "caption '$($cap.text)'; on the record: $(@($cap.mirrored) -join ' | ')"
  Shot "theme-caption.png"
  $capCalm = Eval "new Promise(r => { document.getElementById('calm-toggle').click(); setTimeout(() => { const v = getComputedStyle(document.getElementById('caption-box')).display; document.getElementById('calm-toggle').click(); r(v); }, 300); })"
  Check 'comic: captions off in Calm' ($capCalm -eq 'none') "caption display in Calm: $capCalm"
  Start-Sleep -Milliseconds 4500
  $gl = Eval "new Promise(r => { document.getElementById('tab-results').click(); setTimeout(() => { const on = document.getElementById('glitch').classList.contains('on'); setTimeout(() => { const off = !document.getElementById('glitch').classList.contains('on'); const shown = !document.getElementById('view-results').hidden; document.getElementById('tab-ab').click(); r(JSON.stringify({on, off, shown})); }, 300); }, 40); })" | ConvertFrom-Json
  Check 'comic: 250 ms glitch on view switch' ($gl.on -and $gl.off -and $gl.shown) ($gl | ConvertTo-Json -Compress)
  Start-Sleep -Milliseconds 400

  # Reduced motion: instant switch, no tremble.
  Media @(@{ name = 'prefers-reduced-motion'; value = 'reduce' })
  Start-Sleep -Milliseconds 300   # let the media change event reach the page
  $rm = Eval "new Promise(r => { TS.Decor.setActivity({running: true, real: false, rates: {baseline: 3, tenantscaler: 3}}); let d0 = 0; setTimeout(() => { d0 = TS.Decor.frames(); }, 300); setTimeout(() => { const n = TS.Decor.frames() - d0; const before = document.documentElement.dataset.theme; document.getElementById('theme-toggle').click(); r(JSON.stringify({frames: n, switched: document.documentElement.dataset.theme !== before, drop: document.getElementById('theme-toggle').classList.contains('drop')})); TS.Decor.setActivity({running: false}); }, 1200); })" | ConvertFrom-Json
  Check 'reduced motion: instant switch, no tremble' ($rm.frames -eq 0 -and $rm.switched -and -not $rm.drop) ($rm | ConvertTo-Json -Compress)
  $rmg = Eval "new Promise(r => { document.getElementById('tab-results').click(); setTimeout(() => { const on = document.getElementById('glitch').classList.contains('on'); const shown = !document.getElementById('view-results').hidden; document.getElementById('tab-ab').click(); r(JSON.stringify({glitch: on, shown})); }, 30); })" | ConvertFrom-Json
  Check 'reduced motion: view switch without glitch' (-not $rmg.glitch -and $rmg.shown) ($rmg | ConvertTo-Json -Compress)

  $results.GetEnumerator() | ForEach-Object { "{0,-62} {1}" -f $_.Key, $_.Value }
  $ws.Dispose()
} finally {
  Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*tenantscaler-theme-check*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 800
  # A second pass: Edge can restart a helper process while the first stops.
  Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*tenantscaler-theme-check*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue # the throwaway profile
}
if ($results.Values | Where-Object { $_ -like 'FAIL*' }) { exit 1 }
