# Zero-downtime blue/green deployment behind an nginx proxy on the same address (port 8000).
#   proxy  : hw1-proxy (nginx) publishes 0.0.0.0:8000 -> active color
#   colors : hw1-sentiment-blue (127.0.0.1:18001), hw1-sentiment-green (127.0.0.1:18002)
# Flow: start idle color with new image -> verify directly -> switch proxy (graceful reload)
#       -> verify through proxy -> drain and remove old color.
# If anything fails before the switch, the active color keeps serving (no impact).
# Phase markers are appended to PhaseFile (JSONL) for the monitoring summary. ASCII-only file.
param(
    [Parameter(Mandatory = $true)][string]$ImageRef,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$PhaseFile,
    [string]$NginxImage = 'nginx:1.30.6-alpine',
    [int]$PublicPort = 8000,
    [int]$DrainSec = 10
)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$Network = 'hw1-net'
$Proxy = 'hw1-proxy'
$Ports = @{ blue = 18001; green = 18002 }

function Mark([string]$phase, [string]$detail = '') {
    $line = ([ordered]@{ phase = $phase; time = [DateTime]::UtcNow.ToString('o'); detail = $detail } | ConvertTo-Json -Compress)
    [IO.File]::AppendAllText($PhaseFile, $line + "`n", $utf8)
    Write-Host ("[{0}] {1} {2}" -f ([DateTime]::UtcNow.ToString('HH:mm:ss.fff')), $phase, $detail)
}
function Exists([string]$name) {
    $id = docker ps -aq --filter "name=^/$name$" 2>$null
    return [bool]$id
}
function Running([string]$name) {
    $id = docker ps -q --filter "name=^/$name$" 2>$null
    return [bool]$id
}
function Write-ProxyConf([string]$color, [string]$ver) {
    $conf = @'
upstream hw1_app {
    server hw1-sentiment-__COLOR__:8000;
    keepalive 8;
}
server {
    listen 8000;
    client_max_body_size 1m;
    location / {
        proxy_pass http://hw1_app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 3s;
        proxy_read_timeout 60s;
        add_header X-Active-Color __COLOR__ always;
        add_header X-Deploy-Version __VERSION__ always;
    }
}
'@
    $conf = $conf.Replace('__COLOR__', $color).Replace('__VERSION__', $ver)
    $tmp = Join-Path $env:TEMP "hw1-proxy-$color.conf"
    [IO.File]::WriteAllText($tmp, ($conf -replace "`r`n", "`n"), $utf8)
    docker cp $tmp "${Proxy}:/etc/nginx/conf.d/default.conf" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp proxy config failed" }
}
function Wait-App([string]$baseUrl, [string]$expectVersion, [int]$timeoutSec, [switch]$AllowLegacy) {
    # Served version = JSON 'version' (app) -> X-App-Version header -> X-Deploy-Version header (proxy).
    # -AllowLegacy: only for the direct check of a pre-versioning image (no version anywhere).
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $body = [Text.Encoding]::UTF8.GetBytes('{"text": "deploy health check"}')
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "$baseUrl/" -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) {
                $p = Invoke-WebRequest "$baseUrl/predict" -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15
                $j = [Text.Encoding]::UTF8.GetString($p.RawContentStream.ToArray()) | ConvertFrom-Json
                $served = if ($j.version) { [string]$j.version } elseif ($p.Headers['X-App-Version']) { [string]$p.Headers['X-App-Version'] } else { [string]$p.Headers['X-Deploy-Version'] }
                $j | Add-Member -NotePropertyName served_version -NotePropertyValue $served -Force
                $versionOk = (-not $expectVersion) -or ($served -eq $expectVersion) -or ($AllowLegacy -and -not $served)
                if ($p.StatusCode -eq 200 -and $j.label -and $versionOk) { return $j }
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    return $null
}
function Docker-Quiet([string]$args1) {
    # run docker via cmd so stderr notices (nginx prints to stderr) are shown as plain text
    $out = cmd /c "docker $args1 2>&1"
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { Write-Host "  $_" } }
    return $code
}

Mark 'deploy_start' "image=$ImageRef version=$Version"

# --- infrastructure (idempotent) ---------------------------------------------------------
docker network inspect $Network 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { docker network create $Network | Out-Null; Write-Host "created network $Network" }

$active = $null
if (Running $Proxy) {
    $conf = docker exec $Proxy cat /etc/nginx/conf.d/default.conf 2>$null | Out-String
    $m = [regex]::Match($conf, 'server hw1-sentiment-(blue|green):8000')
    if ($m.Success) { $active = $m.Groups[1].Value }
}
if (-not $active) {
    Mark 'bootstrap' 'proxy not found: first zero-downtime setup (a short port hand-over gap is expected once)'
}
$idle = if ($active -eq 'blue') { 'green' } else { 'blue' }
$new = "hw1-sentiment-$idle"
$old = if ($active) { "hw1-sentiment-$active" } else { $null }
Write-Host "active=$active -> new=$idle"

# --- start new color -----------------------------------------------------------------------
if (Exists $new) { docker rm -f $new | Out-Null }
docker run -d --name $new --network $Network --restart unless-stopped `
    --label "hw1.version=$Version" -e "APP_VERSION=$Version" `
    -p "127.0.0.1:$($Ports[$idle]):8000" $ImageRef | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker run $new failed" }
Mark 'new_started' $new

$ready = Wait-App "http://127.0.0.1:$($Ports[$idle])" $Version 240 -AllowLegacy
if (-not $ready) {
    docker logs --tail 80 $new
    docker rm -f $new | Out-Null
    Mark 'deploy_failed' 'new container did not become ready; previous version keeps serving'
    throw "new container $new not ready"
}
Mark 'new_ready' "model=$($ready.model)"

# --- switch traffic ------------------------------------------------------------------------
if (-not $active) {
    # one-time migration from the legacy single container bound to port 8000
    if (-not (Exists $Proxy)) {
        docker create --name $Proxy --network $Network --restart unless-stopped -p "$($PublicPort):8000" $NginxImage | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker create proxy failed" }
    }
    Write-ProxyConf $idle $Version
    if (Exists 'hw1-sentiment') { docker rm -f hw1-sentiment | Out-Null }
    docker start $Proxy | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "proxy start failed" }
} else {
    Write-ProxyConf $idle $Version
    if ((Docker-Quiet "exec $Proxy nginx -t") -ne 0) {
        Write-ProxyConf $active ''
        docker rm -f $new | Out-Null
        throw "nginx config test failed"
    }
    if ((Docker-Quiet "exec $Proxy nginx -s reload") -ne 0) { throw "nginx reload failed" }
}
Mark 'switched' "proxy -> $idle"

$through = Wait-App "http://127.0.0.1:$PublicPort" $Version 60
if (-not $through) { throw "service through proxy does not return version $Version" }
Mark 'verified_via_proxy' "version=$($through.served_version) model=$($through.model)"

# --- drain and remove old color ----------------------------------------------------------
if ($old) {
    Start-Sleep -Seconds $DrainSec
    docker stop -t 10 $old | Out-Null
    docker rm $old | Out-Null
    Mark 'old_removed' $old
}
Mark 'deploy_end' "active=$idle version=$Version"
docker ps --filter "name=hw1-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
