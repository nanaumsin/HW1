# 배포 모니터링 결과 요약: Actions 로그 출력 + Job Summary(Markdown) + 산출물(UTF-8) 생성
# (UTF-8 with BOM 으로 저장: Windows PowerShell 5.1 에서 한글이 깨지지 않도록)
param(
    [Parameter(Mandatory = $true)][string]$MonitorLog,
    [Parameter(Mandatory = $true)][string]$PhaseFile,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Url = 'http://localhost:8000/predict',
    [string]$ExpectedVersion = '',
    [string]$PreviousVersion = '',
    [string]$RunUrl = '',
    [double]$IntervalSec = 1.0,
    [double]$GapToleranceSec = 1.0
)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force $OutDir | Out-Null

function P([string]$s) { [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
function K($t) { if ($null -eq $t) { '-' } else { $t.AddHours(9).ToString('yyyy-MM-dd HH:mm:ss.fff') } }
function KS($t) { if ($null -eq $t) { '-' } else { $t.AddHours(9).ToString('HH:mm:ss.fff') } }
function Short([string]$v) { if (-not $v) { '(없음)' } elseif ($v.Length -gt 12) { $v.Substring(0, 7) } else { $v } }

$recs = @()
if (Test-Path $MonitorLog) {
    $recs = @(Get-Content $MonitorLog -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
        $r = $_ | ConvertFrom-Json
        $r | Add-Member -NotePropertyName s -NotePropertyValue (P $r.start) -PassThru |
             Add-Member -NotePropertyName e -NotePropertyValue (P $r.end) -PassThru
    } | Sort-Object s)
}
$phases = @()
if (Test-Path $PhaseFile) {
    $phases = @(Get-Content $PhaseFile -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
        $p = $_ | ConvertFrom-Json; $p | Add-Member -NotePropertyName t -NotePropertyValue (P $p.time) -PassThru })
}
function PhaseTime([string]$name) { ($phases | Where-Object { $_.phase -eq $name } | Select-Object -First 1).t }

$tStart = PhaseTime 'deploy_start'
$tSwitch = PhaseTime 'switched'
$tEnd = PhaseTime 'deploy_end'
$failedPhase = $phases | Where-Object { $_.phase -eq 'deploy_failed' } | Select-Object -First 1
$deployOk = [bool]$tEnd
if (-not $tEnd -and $phases.Count) { $tEnd = ($phases | Select-Object -Last 1).t }

foreach ($r in $recs) {
    $stage = if ($tStart -and $r.s -lt $tStart) { '배포 전' } elseif ($tEnd -and $r.s -le $tEnd) { '배포 중' } else { '배포 후' }
    $r | Add-Member -NotePropertyName stage -NotePropertyValue $stage
}

# --- 통계 ------------------------------------------------------------------------------
$n = $recs.Count
$okCount = @($recs | Where-Object { $_.ok }).Count
$failCount = $n - $okCount
$intervals = @(); $gaps = @(); $unverified = @()
for ($i = 1; $i -lt $n; $i++) {
    $intervals += ($recs[$i].s - $recs[$i - 1].s).TotalSeconds
    $g = ($recs[$i].s - $recs[$i - 1].e).TotalSeconds
    $gaps += $g
    if ($g -gt ($IntervalSec + $GapToleranceSec)) { $unverified += [pscustomobject]@{ from = $recs[$i - 1].e; to = $recs[$i].s; sec = $g } }
}
function Stat($a, [string]$f) { if ($a.Count) { ($a | Measure-Object -Average -Maximum -Minimum) } else { $null } }
$iv = Stat $intervals; $gp = Stat $gaps
$lat = if ($n) { $recs | Measure-Object -Property latency_ms -Average -Maximum } else { $null }

# 버전 구간 (연속 동일 버전)
$segments = @()
foreach ($r in $recs) {
    $v = if ($r.ok) { [string]$r.version } else { '(실패)' }
    if ($segments.Count -and $segments[-1].version -eq $v) { $segments[-1].last = $r.s; $segments[-1].count++ }
    else { $segments += [pscustomobject]@{ version = $v; first = $r.s; last = $r.s; count = 1 } }
}
$firstNew = if ($ExpectedVersion) { $recs | Where-Object { $_.ok -and $_.version -eq $ExpectedVersion } | Select-Object -First 1 } else { $null }
$lastOld = if ($firstNew) { $recs | Where-Object { $_.ok -and $_.s -lt $firstNew.s -and $_.version -ne $ExpectedVersion } | Select-Object -Last 1 } else { $null }
$mixedAfter = if ($firstNew) { @($recs | Where-Object { $_.ok -and $_.s -gt $firstNew.s -and $_.version -ne $ExpectedVersion }).Count } else { 0 }

# 대표 응답
$repBefore = $recs | Where-Object { $_.stage -eq '배포 전' } | Select-Object -Last 1
$repDuring = if ($firstNew -and $firstNew.stage -eq '배포 중') { $firstNew } else { $recs | Where-Object { $_.stage -eq '배포 중' } | Select-Object -Last 1 }
$repAfter = $recs | Where-Object { $_.stage -eq '배포 후' } | Select-Object -Last 1

# 무중단 판정 (관측 범위 내)
$obsFrom = if ($n) { $recs[0].s } else { $null }
$obsTo = if ($n) { $recs[-1].e } else { $null }
$duringFails = @($recs | Where-Object { $_.stage -eq '배포 중' -and -not $_.ok }).Count
$duringGaps = @($unverified | Where-Object { $tStart -and $tEnd -and $_.to -ge $tStart -and $_.from -le $tEnd })
if (-not $deployOk) {
    $verdict = "❌ 배포 실패 — 단계: $($failedPhase.detail). 실패 전까지 수집된 기록은 아래와 같습니다."
} elseif ($failCount -eq 0 -and $duringGaps.Count -eq 0) {
    $verdict = "✅ **무중단 확인** — 관측 범위 $(KS $obsFrom) ~ $(KS $obsTo) (KST) 동안 요청 $n 건이 모두 정상 응답했고, 배포 구간에 미검증 공백이 없습니다."
} elseif ($failCount -eq 0) {
    $verdict = "⚠️ 실패 응답은 0건이지만 배포 구간에 기록 공백 $($duringGaps.Count)개가 있어 해당 구간은 미검증입니다."
} else {
    $verdict = "❌ 실패 응답 $failCount 건 발생 (배포 중 $duringFails 건) — 무중단 아님."
}

function Row($r) {
    if (-not $r) { return '| - | - | - | - | - | - | - |' }
    $res = if ($r.ok) { "$($r.sentiment) / $($r.label)" } else { "오류: $($r.error)" }
    "| $($r.stage) | #$($r.seq) | $(KS $r.s) | $(KS $r.e) | $($r.latency_ms) ms | $($r.status) | $(Short $r.version) | $res |"
}

# --- Markdown Summary ------------------------------------------------------------------
$md = New-Object System.Collections.Generic.List[string]
$md.Add("## 🚀 무중단 배포 검증 결과")
$md.Add("")
$md.Add($verdict)
$md.Add("")
$md.Add("| 항목 | 값 |")
$md.Add("|---|---|")
$md.Add("| 검증 주소 | ``POST $Url`` (고정 테스트 문장, 응답 완료 후 $IntervalSec 초 간격) |")
$md.Add("| 검증 시간 (KST) | $(K $obsFrom) ~ $(K $obsTo) |")
$md.Add("| 배포 시작 / 트래픽 전환 / 배포 완료 | $(KS $tStart) / $(KS $tSwitch) / $(KS $tEnd) |")
$md.Add("| 버전 전환 | ``$(Short $PreviousVersion)`` → ``$(Short $ExpectedVersion)`` (첫 신규 응답 $(if ($firstNew) { KS $firstNew.s } else { '-' }), 마지막 이전 응답 $(if ($lastOld) { KS $lastOld.s } else { '-' }), 전환 후 이전 버전 응답 $mixedAfter 건) |")
$md.Add("| 전체 요청 | **$n 건** — 성공 **$okCount** / 실패 **$failCount** |")
$md.Add("| 구간별 요청 | 배포 전 $(@($recs | ? { $_.stage -eq '배포 전' }).Count) · 배포 중 $(@($recs | ? { $_.stage -eq '배포 중' }).Count) · 배포 후 $(@($recs | ? { $_.stage -eq '배포 후' }).Count) |")
$md.Add("| 실제 요청 간격 (시작→시작) | 평균 $(if ($iv) { '{0:N2}' -f $iv.Average } else { '-' }) 초 · 최대 $(if ($iv) { '{0:N2}' -f $iv.Maximum } else { '-' }) 초 |")
$md.Add("| 최대 기록 공백 (응답 종료→다음 요청 시작) | **$(if ($gp) { '{0:N2}' -f $gp.Maximum } else { '-' }) 초** (허용 $($IntervalSec + $GapToleranceSec) 초 초과 시 미검증 구간) |")
$md.Add("| 응답 시간 | 평균 $(if ($lat) { '{0:N0}' -f $lat.Average } else { '-' }) ms · 최대 $(if ($lat) { '{0:N0}' -f $lat.Maximum } else { '-' }) ms |")
$md.Add("")
$md.Add("### 대표 응답 (배포 전 · 중 · 후)")
$md.Add("| 구간 | 요청 | 시작 | 종료 | 응답시간 | 상태 | 버전 | 분석 결과 |")
$md.Add("|---|---|---|---|---|---|---|---|")
$md.Add((Row $repBefore)); $md.Add((Row $repDuring)); $md.Add((Row $repAfter))
$md.Add("")
$md.Add("### 버전 전환 타임라인")
$md.Add("| 버전 | 첫 응답 | 마지막 응답 | 요청 수 |")
$md.Add("|---|---|---|---|")
foreach ($s in $segments) { $md.Add("| ``$(Short $s.version)`` | $(KS $s.first) | $(KS $s.last) | $($s.count) |") }
$md.Add("")
$md.Add("### 기록 공백 (미검증 구간)")
if ($unverified.Count) {
    $md.Add("| 시작 | 끝 | 길이 |"); $md.Add("|---|---|---|")
    foreach ($u in $unverified) { $md.Add("| $(KS $u.from) | $(KS $u.to) | $('{0:N2}' -f $u.sec) 초 |") }
} else {
    $md.Add("없음 — 모든 요청 사이 공백이 $($IntervalSec + $GapToleranceSec) 초 이하입니다.")
}
$md.Add("")
$md.Add("> 판정 범위: 모니터가 실제로 요청을 보낸 시간(첫 요청 시작 ~ 마지막 응답 종료)에 한정됩니다. 요청과 요청 사이(최대 $(if ($gp) { '{0:N2}' -f $gp.Maximum } else { '-' }) 초)는 관측하지 않았으며, 허용치를 넘는 공백은 위 표에 미검증 구간으로 표시합니다.")
if ($RunUrl) { $md.Add(""); $md.Add("전체 요청 로그(UTF-8)는 이 실행의 Artifacts **deploy-monitoring-logs** 에 있습니다. ($RunUrl)") }
$mdText = ($md -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $OutDir 'summary.md'), $mdText, $utf8)
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $mdText, $utf8) }

# --- CSV + Actions 로그 출력 -------------------------------------------------------------
$csv = New-Object System.Collections.Generic.List[string]
$csv.Add('seq,stage,start_kst,end_kst,latency_ms,status,ok,version,label,sentiment,error')
foreach ($r in $recs) {
    $csv.Add(('{0},{1},{2},{3},{4},{5},{6},{7},"{8}","{9}","{10}"' -f $r.seq, $r.stage, (K $r.s), (K $r.e), $r.latency_ms, $r.status, $r.ok, $r.version, $r.label, $r.sentiment, ([string]$r.error).Replace('"', "'")))
}
[IO.File]::WriteAllText((Join-Path $OutDir 'requests.csv'), ($csv -join "`n") + "`n", $utf8)

Write-Host "================ 요청 기록 ($n 건) ================"
Write-Host ('{0,-5} {1,-6} {2,-13} {3,-13} {4,9} {5,6} {6,-5} {7,-9} {8}' -f 'seq', 'stage', 'start(KST)', 'end(KST)', 'latency', 'status', 'ok', 'version', 'result')
foreach ($r in $recs) {
    $res = if ($r.ok) { "$($r.sentiment) $($r.label)" } else { "ERROR $($r.error)" }
    Write-Host ('{0,-5} {1,-6} {2,-13} {3,-13} {4,7}ms {5,6} {6,-5} {7,-9} {8}' -f $r.seq, $r.stage, (KS $r.s), (KS $r.e), $r.latency_ms, $r.status, $r.ok, (Short $r.version), $res)
}
Write-Host "================ 요약 ================"
Write-Host $mdText
if (-not $deployOk) { exit 0 }
