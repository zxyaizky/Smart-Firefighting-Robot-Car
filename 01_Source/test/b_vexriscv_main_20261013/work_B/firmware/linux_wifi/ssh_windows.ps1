param([switch]$Check,[switch]$Direct,[switch]$ExportConfig)
$ErrorActionPreference = 'Stop'
$wifiRoot = $PSScriptRoot
$key = Join-Path $wifiRoot 'build\client_key.openssh'
$publicKey = (Get-Content -LiteralPath (Join-Path $wifiRoot 'build\host_key.pub') -Raw).Trim()
$sshServer = '192.168.4.1'
$knownName = 'build\known_hosts_wifi'
if ($Direct) {
    $sshServer = '192.168.11.2'
    $knownName = 'build\known_hosts_wifi_direct'
}
$known = Join-Path $wifiRoot $knownName
$sshArgs = @('-p','2222','-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes',
    '-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),
    '-o','KexAlgorithms=curve25519-sha256','-o','ConnectTimeout=600',('root@'+$sshServer))
if ($ExportConfig) {
    if (-not (Test-Path -LiteralPath $key) -or -not (Test-Path -LiteralPath $known)) {
        throw 'Use the existing verified SSH key and known_hosts files.'
    }
    if ((Get-Content -LiteralPath $known -Raw).Trim() -ne ('[' + $sshServer + ']:2222 ' + $publicKey)) {
        throw 'Existing known_hosts does not match the pinned board host key.'
    }
    [pscustomobject]@{Executable=(Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'); Arguments=$sshArgs} | ConvertTo-Json -Compress
    exit 0
}
Set-Content -LiteralPath $known -Value (('[' + $sshServer + ']:2222 ' + $publicKey) + "`n") -Encoding ascii -NoNewline
& icacls $key /inheritance:r /grant:r ($env:USERDOMAIN + '\' + $env:USERNAME + ':F') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict candidate private-key permissions.' }
Write-Host 'First connect Windows Wi-Fi to Anlu-B-Linux. Keep both boards powered.'
if ($Direct) {
    Write-Host 'DIRECT mode: NEW ESP NAPT firmware required; Linux 192.168.11.2:2222 via ESP 192.168.4.1.'
} else {
    Write-Host '192.168.4.1:2222 forwards through ESP to Linux 192.168.11.2:2222.'
}
if ($Check) {
    $diagnosticDir = Join-Path $wifiRoot ('..\..\reports\linux_wifi_' + (Get-Date -Format 'yyyyMMdd'))
    New-Item -ItemType Directory -Path $diagnosticDir -Force | Out-Null
    $checkPrefix = if ($Direct) { 'check_direct_' } else { 'check_' }
    $diagnosticBase = Join-Path $diagnosticDir ($checkPrefix + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $trace = $diagnosticBase + '.ssh.log'
    Write-Host "SSH handshake log: $trace"
    & "$env:WINDIR\System32\netsh.exe" wlan show interfaces | Out-File -LiteralPath ($diagnosticBase + '.wifi_before.txt') -Encoding utf8
    if ($Direct) {
        $routeData = @(Find-NetRoute -RemoteIPAddress $sshServer)
        $routeData | Select-Object InterfaceAlias,InterfaceIndex,IPAddress,DestinationPrefix,NextHop,RouteMetric | ConvertTo-Json | Set-Content -LiteralPath ($diagnosticBase + '.route_before.json') -Encoding utf8
        if (-not ($routeData | Where-Object { $_.NextHop -eq '192.168.4.1' })) {
            throw 'No route to Linux through ESP 192.168.4.1. Connect Anlu-B-Linux and check the saved route.'
        }
    }
    $sshArgs = @('-vvv','-E',$trace) + $sshArgs
    $sshArgs += 'uname -a; free; cat /proc/net/dev; echo ANLU_WIRELESS_SSH_PASS'
    # Windows PowerShell treats native stderr as an error record; save it before throwing.
    $savedErrorAction = $ErrorActionPreference
    $started = Get-Date
    try {
        $ErrorActionPreference = 'Continue'
        $output = & "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    $finished = Get-Date
    & "$env:WINDIR\System32\netsh.exe" wlan show interfaces | Out-File -LiteralPath ($diagnosticBase + '.wifi_after.txt') -Encoding utf8
    @("START=$($started.ToString('o'))", "END=$($finished.ToString('o'))", "ELAPSED_SECONDS=$(($finished - $started).TotalSeconds)", "SSH_EXIT_CODE=$code") | Set-Content -LiteralPath ($diagnosticBase + '.status.txt') -Encoding utf8
    @("SSH_EXIT_CODE=$code") + @($output) | Set-Content -LiteralPath ($diagnosticBase + '.output.log') -Encoding utf8
    if (Test-Path -LiteralPath $trace) {
        Copy-Item -LiteralPath $trace -Destination (Join-Path $wifiRoot '..\..\reports\linux_wifi_20261021\wireless_board_ssh_debug.log')
    }
    @("SSH_EXIT_CODE=$code") + @($output) | Tee-Object -FilePath (Join-Path $wifiRoot '..\..\reports\linux_wifi_20261021\wireless_board_ssh.log')
    if ($code -ne 0 -or ($output -join "`n") -notmatch 'riscv32' -or ($output -join "`n") -notmatch 'ANLU_WIRELESS_SSH_PASS') {
        Write-Host "SSH handshake log: $trace"
        throw 'Wireless SSH acceptance did not pass; save both SSH logs and board console.'
    }
} else {
    # Keep each interactive failure separate from the acceptance-test log.
    $diagnosticDir = Join-Path $wifiRoot '..\..\reports\linux_wifi_20261024'
    New-Item -ItemType Directory -Path $diagnosticDir -Force | Out-Null
    $diagnosticBase = Join-Path $diagnosticDir ('interactive_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $trace = $diagnosticBase + '.ssh.log'
    Write-Host "SSH handshake log: $trace"
    & "$env:WINDIR\System32\netsh.exe" wlan show interfaces | Out-File -LiteralPath ($diagnosticBase + '.wifi_before.txt') -Encoding utf8
    $started = Get-Date
    & "$env:WINDIR\System32\OpenSSH\ssh.exe" '-vvv' '-E' $trace @sshArgs
    $code = $LASTEXITCODE
    $finished = Get-Date
    & "$env:WINDIR\System32\netsh.exe" wlan show interfaces | Out-File -LiteralPath ($diagnosticBase + '.wifi_after.txt') -Encoding utf8
    @("START=$($started.ToString('o'))", "END=$($finished.ToString('o'))", "ELAPSED_SECONDS=$(($finished - $started).TotalSeconds)", "SSH_EXIT_CODE=$code") | Set-Content -LiteralPath ($diagnosticBase + '.status.txt') -Encoding utf8
    Write-Host "SSH_EXIT_CODE=$code"
    Write-Host "SSH handshake log: $trace"
    exit $code
}
