#Requires -Version 5.1
<#
.SYNOPSIS
    HTTP(S)-Ping - check a URL until expected text appears in the response body

.DESCRIPTION
    PowerShell equivalent of httping.sh. It continuously probes a URL, follows redirects,
    and reports a status change when the response is HTTP 200 and, if configured, the body
    contains the expected text.

.PARAMETER URL
    URL to request, for example https://example.com/login or example.com (HTTPS by default)

.PARAMETER Text
    Optional expected text to find in the HTTP response body

.PARAMETER Unsecure
    Use HTTP instead of the default HTTPS

.PARAMETER Port
    Optional port override (numeric or http/https)

.PARAMETER Deadtime
    HTTP timeout in seconds (default: 5)

.PARAMETER Interval
    Seconds between checks (default: 5)

.PARAMETER Fuzzy
    Number of failed checks before marking the URL down; 0 disables (default: 0)

.PARAMETER DebugMode
    Enable debug output

.PARAMETER Version
    Show version

.PARAMETER Help
    Show usage
#>

param(
    [Parameter(Position = 0)]
    [string]$URL,

    [Alias('t')]
    [string]$Text,

    [Alias('u')]
    [switch]$Unsecure,

    [Alias('P')]
    [string]$Port,

    [Alias('W')]
    [int]$Deadtime = 5,

    [Alias('i')]
    [int]$Interval = 5,

    [Alias('f')]
    [int]$Fuzzy = 0,

    [Alias('d')]
    [switch]$DebugMode,

    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

$VER = "1.1"

$script:debug = [bool]$DebugMode
$script:deadtime = $Deadtime
$script:interval = $Interval
$script:fuzzy_limit = $Fuzzy
$script:follow = 1
$script:health = 2
$script:transmitted = 0
$script:received = 0
$script:uptotal = 0
$script:downtotal = 0
$script:upsec = 0
$script:downsec = 0
$script:missingtotal = 0
$script:lastuptime = 0
$script:lastdowntime = 0
$script:lastmissingtime = 0
$script:flap = 0
$script:fuzzy_total = 0
$script:fuzzy_lost = 0
$script:fuzzy_cnt = 0
$script:expectedText = $Text
$script:targetUrl = $null
$script:normalizedUrl = $null
$script:lastHttpCode = 0
$script:lastResponseTime = 0.0
$script:successResponseTotal = 0.0
$script:successResponseCount = 0
$script:avgResponseTime = 0.0
$script:okResponseMin = [double]::MaxValue
$script:okResponseMax = 0.0
$script:missingResponseTotal = 0.0
$script:missingResponseCount = 0
$script:missingResponseMin = [double]::MaxValue
$script:missingResponseMax = 0.0
$script:statsPrinted = $false
$script:statusLineStarted = $false

$ESC = [char]27
$script:RED = "$ESC[0;31m"
$script:GREEN = "$ESC[0;32m"
$script:YELLOW = "$ESC[0;33m"
$script:ORANGE = "$ESC[0;33m"
$script:RESET = "$ESC[0m"

function Write-Usage {
    Write-Host @"
usage: httping.ps1 [-d] [-W deadtime] [-i interval] [-f fuzzy-pings] [-u] [-P port] [-t text] <URL>
       -u  use HTTP instead of the default HTTPS
       -P  port override
       -t  optional expected text to find in the HTTP response body (default: HTTP 200 only)
       -W  HTTP timeout in seconds (default: 5)
       -i  seconds between checks (default: 5)
       -f  failed checks before marking down; 0 disables (default: 0)
       -d  debug output
       -v  show version
       -h  show help

Examples:
  .\httping.ps1 https://example.com/login
  .\httping.ps1 -t "Welcome" https://example.com/login
  .\httping.ps1 -u -P 8080 -t "OK" example.com
"@
}

function Get-DisplayTime {
    param([long]$T)
    $D = [math]::Floor($T / 86400)
    $H = [math]::Floor(($T / 3600) % 24)
    $M = [math]::Floor(($T / 60) % 60)
    $S = $T % 60
    $parts = @()
    if ($D -gt 0) { $parts += "$D d" }
    if ($H -gt 0) { $parts += "$H h" }
    if ($M -gt 0) { $parts += "$M min" }
    if ($D -gt 0 -or $H -gt 0 -or $M -gt 0) {
        "$($parts -join ' ') and $S sec"
    } else {
        "$S sec"
    }
}

function Resolve-PortValue {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return $null }
    $trimmed = $str.Trim().ToLowerInvariant()
    if ($trimmed -eq 'http') { return 80 }
    if ($trimmed -eq 'https') { return 443 }
    if ($trimmed -match '^\d+$') { return [int]$trimmed }
    return $null
}

function Resolve-HttpTargetURL {
    param(
        [string]$RawUrl,
        [bool]$Unsecure,
        [string]$PortOverride
    )

    if ([string]::IsNullOrWhiteSpace($RawUrl)) {
        throw "URL is required."
    }

    $raw = $RawUrl.Trim()
    $scheme = if ($Unsecure) { 'http' } else { 'https' }
    $candidate = if ($raw -match '^[a-zA-Z]+://') { $raw } else { "${scheme}://$raw" }

    $uri = [System.Uri]$candidate
    $resolvedScheme = $scheme

    $targetHost = $uri.Host
    $path = if (-not [string]::IsNullOrEmpty($uri.AbsolutePath)) { $uri.AbsolutePath } else { '/' }
    $query = if (-not [string]::IsNullOrEmpty($uri.Query)) { $uri.Query.TrimStart('?') } else { $null }

    $resolvedPort = Resolve-PortValue -Value $PortOverride
    if ($resolvedPort -gt 0) {
        $effectivePort = $resolvedPort
    } elseif ($uri.IsDefaultPort) {
        $effectivePort = if ($resolvedScheme -eq 'https') { 443 } else { 80 }
    } elseif ($uri.Port -gt 0) {
        $effectivePort = $uri.Port
    } else {
        $effectivePort = if ($resolvedScheme -eq 'https') { 443 } else { 80 }
    }

    $builder = [System.UriBuilder]::new()
    $builder.Scheme = $resolvedScheme
    $builder.Host = $targetHost
    $builder.Port = $effectivePort
    $builder.Path = $path
    if ($query) { $builder.Query = $query }

    return $builder.Uri
}

function Test-HttpText {
    param(
        [uri]$Uri,
        [string]$ExpectedText,
        [int]$TimeoutSec = 5
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [pscustomobject]@{
        Success = $false
        TextMissing = $false
        StatusCode = 0
        ResponseTimeSeconds = 0.0
    }

    $oldCallback = $null
    if ($Uri.Scheme -eq 'https') {
        $oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    try {
        $response = Invoke-WebRequest -Uri $Uri.AbsoluteUri -Method Get -TimeoutSec $TimeoutSec -MaximumRedirection 10 -UseBasicParsing
        $statusCode = [int]$response.StatusCode
        $success = $statusCode -eq 200
        if ($success -and -not [string]::IsNullOrWhiteSpace($ExpectedText)) {
            if (-not ($response.Content -and $response.Content.Contains($ExpectedText))) {
                $result.TextMissing = $true
                $success = $false
            }
        }

        $result.StatusCode = $statusCode
        $result.Success = $success
        $result.ResponseTimeSeconds = $sw.Elapsed.TotalSeconds
        return $result
    } catch {
        $statusCode = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        $result.StatusCode = $statusCode
        $result.ResponseTimeSeconds = $sw.Elapsed.TotalSeconds
        return $result
    } finally {
        if ($Uri.Scheme -eq 'https') {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
        }
        $sw.Stop()
    }
}

function Write-PrintStatistics {
    if ($script:health -eq 1) {
        $script:upsec = [int](Get-Date -UFormat %s) - $script:lastuptime
        $script:uptotal += $script:upsec
    } elseif ($script:health -eq 0) {
        $script:downsec = [int](Get-Date -UFormat %s) - $script:lastdowntime
        $script:downtotal += $script:downsec
    } elseif ($script:health -eq 3) {
        $missingsec = [int](Get-Date -UFormat %s) - $script:lastmissingtime
        $script:missingtotal += $missingsec
    }

    Write-Host ""
    Write-Host "--- $($script:normalizedUrl) http-check statistics ---"
    Write-Host "flapped $($script:flap) times, was up for $(Get-DisplayTime $script:uptotal) and down for $(Get-DisplayTime $script:downtotal)"
    Write-Host "was missing expected text for $(Get-DisplayTime $script:missingtotal)"
    if ($script:transmitted -gt 0) {
        $ratio = 100 - (($script:received / $script:transmitted) * 100)
        Write-Host "$($script:transmitted) requests sent, $($script:received) successful checks, $([math]::Round($ratio,2))% failed"
    }
    Write-ResponseStatistics -Label 'ok' -Total $script:successResponseTotal -Count $script:successResponseCount -Minimum $script:okResponseMin -Maximum $script:okResponseMax
    Write-ResponseStatistics -Label 'missing' -Total $script:missingResponseTotal -Count $script:missingResponseCount -Minimum $script:missingResponseMin -Maximum $script:missingResponseMax
}

function Write-ResponseStatistics {
    param(
        [string]$Label,
        [double]$Total,
        [int]$Count,
        [double]$Minimum,
        [double]$Maximum
    )

    if ($Count -gt 0) {
        $minMs = [math]::Round($Minimum * 1000)
        $avgMs = [math]::Round(($Total / $Count) * 1000)
        $maxMs = [math]::Round($Maximum * 1000)
        Write-Host "$Label response time min/avg/max = ${minMs}ms/${avgMs}ms/${maxMs}ms"
    } else {
        Write-Host "$Label response time min/avg/max = n/a"
    }
}

function Write-HttpStatus {
    param(
        [string]$Message,
        [switch]$NewLine
    )

    if ($NewLine -and $script:statusLineStarted) {
        [Console]::WriteLine()
    }

    [Console]::Write("`r$ESC[K$Message")
    $script:statusLineStarted = $true
}

function Invoke-ExitCleanup {
    if ($script:statsPrinted) { return }
    $script:statsPrinted = $true
    Write-PrintStatistics
    exit 0
}

try {
    if ([Environment]::UserInteractive) {
        [Console]::TreatControlCAsInput = $false
        [Console]::CancelKeyPress.Add({
            param($eventSender, $e)
            $e.Cancel = $true
            Invoke-ExitCleanup
        })
    }
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-ExitCleanup } | Out-Null
} catch {}

if ($Help) {
    Write-Usage
    exit 0
}

if ($Version) {
    Write-Host "httping.ps1 v$VER"
    exit 0
}

if (-not $URL) {
    Write-Usage
    exit 1
}

$script:expectedText = $Text

try {
    $script:normalizedUrl = Resolve-HttpTargetURL -RawUrl $URL -Unsecure $Unsecure -PortOverride $Port
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

$script:targetUrl = $script:normalizedUrl.AbsoluteUri

if ($script:debug) {
    Write-Host "######## DEBUG ########"
    Write-Host "url = [ $script:targetUrl ]"
    Write-Host "protocol = [ $($script:normalizedUrl.Scheme) ]"
    Write-Host "port = [ $($script:normalizedUrl.Port) ]"
    Write-Host "text = [ $($script:expectedText) ]"
    Write-Host "deadtime = [ $Deadtime ]"
    Write-Host "interval = [ $Interval ]"
    Write-Host "######## DEBUG ########"
}

try {
    while ($true) {
        $script:transmitted++
        $probe = Test-HttpText -Uri $script:normalizedUrl -ExpectedText $script:expectedText -TimeoutSec $script:deadtime
        $script:lastHttpCode = [int]$probe.StatusCode
        $script:lastResponseTime = [double]$probe.ResponseTimeSeconds
        $responseTimeMs = [math]::Round($script:lastResponseTime * 1000)

        if ($probe.Success) {
            $script:received++
            $script:successResponseTotal += $script:lastResponseTime
            $script:successResponseCount++
            $script:avgResponseTime = [math]::Round(($script:successResponseTotal / $script:successResponseCount), 3)
            $script:okResponseMin = [math]::Min($script:okResponseMin, $script:lastResponseTime)
            $script:okResponseMax = [math]::Max($script:okResponseMax, $script:lastResponseTime)

            $textSuffix = if ([string]::IsNullOrWhiteSpace($script:expectedText)) { '' } else { " | response contains '$script:expectedText'" }

            if ($script:health -eq 2) {
                $script:lastuptime = [int](Get-Date -UFormat %s)
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:GREEN)ok$($script:RESET) [HTTP $($script:lastHttpCode), ${responseTimeMs}ms]$textSuffix"
                $script:health = 1
            } elseif ($script:health -eq 0) {
                $downsec = [int](Get-Date -UFormat %s) - $script:lastdowntime
                $script:downtotal += $downsec
                $script:flap++
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:GREEN)ok$($script:RESET) [down for $(Get-DisplayTime $downsec)] [HTTP $($script:lastHttpCode), ${responseTimeMs}ms]$textSuffix"
                $script:lastuptime = [int](Get-Date -UFormat %s)
                $script:health = 1
            } elseif ($script:health -eq 3) {
                $missingsec = [int](Get-Date -UFormat %s) - $script:lastmissingtime
                $script:missingtotal += $missingsec
                $script:flap++
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:GREEN)ok$($script:RESET) [missing for $(Get-DisplayTime $missingsec)] [HTTP $($script:lastHttpCode), ${responseTimeMs}ms]$textSuffix"
                $script:lastuptime = [int](Get-Date -UFormat %s)
                $script:health = 1
            } elseif ($script:health -eq 1 -and $script:follow -eq 1) {
                $upsec = [int](Get-Date -UFormat %s) - $script:lastuptime
                Write-HttpStatus "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:GREEN)ok$($script:RESET) for $(Get-DisplayTime $upsec) [HTTP $($script:lastHttpCode), ${responseTimeMs}ms]$textSuffix"
            }

            if ($script:fuzzy_limit -gt 0 -and $script:fuzzy_cnt -gt 0) {
                $script:fuzzy_total++
                $script:fuzzy_lost += $script:fuzzy_cnt
            }
            $script:fuzzy_cnt = 0
            Start-Sleep -Seconds $script:interval
            continue
        }

        if ($probe.TextMissing) {
            $script:missingResponseTotal += $script:lastResponseTime
            $script:missingResponseCount++
            $script:missingResponseMin = [math]::Min($script:missingResponseMin, $script:lastResponseTime)
            $script:missingResponseMax = [math]::Max($script:missingResponseMax, $script:lastResponseTime)
            $script:fuzzy_cnt = 0
            if ($script:health -eq 1) {
                $script:upsec = [int](Get-Date -UFormat %s) - $script:lastuptime
                $script:uptotal += $script:upsec
                $script:flap++
                $script:lastmissingtime = [int](Get-Date -UFormat %s)
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:ORANGE)missing$($script:RESET) [HTTP $($script:lastHttpCode), ${responseTimeMs}ms] | response misses '$script:expectedText'"
            } elseif ($script:health -eq 0) {
                $downsec = [int](Get-Date -UFormat %s) - $script:lastdowntime
                $script:downtotal += $downsec
                $script:flap++
                $script:lastmissingtime = [int](Get-Date -UFormat %s)
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:ORANGE)missing$($script:RESET) [down for $(Get-DisplayTime $downsec)] [HTTP $($script:lastHttpCode), ${responseTimeMs}ms] | response misses '$script:expectedText'"
            } elseif ($script:health -eq 3) {
                $missingsec = [int](Get-Date -UFormat %s) - $script:lastmissingtime
                Write-HttpStatus "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:ORANGE)missing$($script:RESET) for $(Get-DisplayTime $missingsec) [HTTP $($script:lastHttpCode), ${responseTimeMs}ms] | response misses '$script:expectedText'"
            } else {
                $script:lastmissingtime = [int](Get-Date -UFormat %s)
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:ORANGE)missing$($script:RESET) [HTTP $($script:lastHttpCode), ${responseTimeMs}ms] | response misses '$script:expectedText'"
            }
            $script:health = 3
            Start-Sleep -Seconds $script:interval
            continue
        }

        $script:fuzzy_cnt++
        if ($script:fuzzy_cnt -gt $script:fuzzy_limit) {
            if ($script:health -eq 2) {
                $script:lastdowntime = [int](Get-Date -UFormat %s)
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:RED)down$($script:RESET) [HTTP $($script:lastHttpCode)]"
                $script:health = 0
            } elseif ($script:health -eq 1) {
                $script:lastdowntime = [int](Get-Date -UFormat %s)
                $upsec = [int](Get-Date -UFormat %s) - $script:lastuptime
                $script:uptotal += $upsec
                $script:flap++
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:RED)down$($script:RESET) [ok for $(Get-DisplayTime $upsec)] [HTTP $($script:lastHttpCode)]"
                $script:health = 0
            } elseif ($script:health -eq 3) {
                $missingsec = [int](Get-Date -UFormat %s) - $script:lastmissingtime
                $script:missingtotal += $missingsec
                $script:lastdowntime = [int](Get-Date -UFormat %s)
                $script:flap++
                Write-HttpStatus -NewLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:RED)down$($script:RESET) [missing for $(Get-DisplayTime $missingsec)] [HTTP $($script:lastHttpCode)]"
                $script:health = 0
            } elseif ($script:health -eq 0 -and $script:follow -eq 1) {
                $downsec = [int](Get-Date -UFormat %s) - $script:lastdowntime
                Write-HttpStatus "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | url $script:targetUrl is $($script:RED)down$($script:RESET) for $(Get-DisplayTime $downsec) [HTTP $($script:lastHttpCode)]"
            }
        } else {
            if ($script:fuzzy_cnt -eq 1) {
                Write-Host -NoNewline " --FUZZY--"
            }
        }

        Start-Sleep -Seconds $script:interval
    }
} finally {
    Invoke-ExitCleanup
}
