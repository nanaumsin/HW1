# Independent availability monitor (runs as a separate process during CD).
# Sends a fixed test request to the analysis API; waits IntervalSec AFTER each response
# completes, then sends the next one. Every request is appended to a UTF-8 JSONL log:
#   seq, start/end (UTC ISO-8601 ms), latency_ms, status, ok (analysis valid), version, label, sentiment, error
# Stops when StopFile exists. ASCII-only file (Windows PowerShell 5.1 safe).
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$StopFile,
    [double]$IntervalSec = 1.0,
    [int]$TimeoutSec = 10,
    [string]$Body = ''
)
$ErrorActionPreference = 'Continue'
if (-not $Body) {
    # fixed test text (Korean), built from code points to keep this file ASCII-only
    $codes = 0xC774,0xBC88,0x20,0xD504,0xB85C,0xC81D,0xD2B8,0x20,0xC815,0xB9D0,0x20,0xAE30,0xB300,0x20,0xC774,0xC0C1,0xC774,0xB124,0xC694,0x21
    $Body = '{"text": "' + (-join ($codes | ForEach-Object { [char]$_ })) + '"}'
}
Add-Type -AssemblyName System.Net.Http
$utf8 = New-Object System.Text.UTF8Encoding($false)
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
$seq = 0
[IO.File]::WriteAllText($LogPath, '', $utf8)

while (-not (Test-Path $StopFile)) {
    $seq++
    $rec = [ordered]@{ seq = $seq; start = $null; end = $null; latency_ms = $null; status = 0; ok = $false;
                       version = $null; label = $null; sentiment = $null; error = $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rec.start = [DateTime]::UtcNow.ToString('o')
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Url)
        $req.Headers.ConnectionClose = $true
        $req.Content = New-Object System.Net.Http.StringContent($Body, $utf8, 'application/json')
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $rec.status = [int]$resp.StatusCode
        $text = $utf8.GetString($bytes)
        $hdr = $null
        $vals = $null
        if ($resp.Headers.TryGetValues('X-App-Version', [ref]$vals)) { $hdr = ($vals | Select-Object -First 1) }
        elseif ($resp.Headers.TryGetValues('X-Deploy-Version', [ref]$vals)) { $hdr = ($vals | Select-Object -First 1) }
        try {
            $json = $text | ConvertFrom-Json
            $rec.label = $json.label
            $rec.sentiment = $json.sentiment
            $rec.version = if ($json.version) { [string]$json.version } else { $hdr }
            $rec.ok = ($rec.status -eq 200) -and [bool]$json.label -and [bool]$json.sentiment
        } catch {
            $rec.version = $hdr
            $rec.error = 'invalid JSON: ' + $text.Substring(0, [Math]::Min(200, $text.Length))
        }
        $resp.Dispose()
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $rec.error = $e.Message
    }
    $sw.Stop()
    $rec.end = [DateTime]::UtcNow.ToString('o')
    $rec.latency_ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    [IO.File]::AppendAllText($LogPath, (($rec | ConvertTo-Json -Compress) + "`n"), $utf8)
    Start-Sleep -Milliseconds ([int]($IntervalSec * 1000))
}
$client.Dispose()
