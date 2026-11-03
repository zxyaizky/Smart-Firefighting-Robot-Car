# User explicitly requested stopping this confirmed UDP 6001 owner.
$ErrorActionPreference = 'Stop'
$taskResultPath = Join-Path $PSScriptRoot 'service_stop_result.json'
try {
    $taskService = Get-CimInstance Win32_Service -Filter "Name='lkTimeSync'"
    if (-not $taskService) { throw 'lkTimeSync service was not found.' }
    $taskEndpoints = @(Get-NetUDPEndpoint -LocalPort 6001 -ErrorAction SilentlyContinue)
    $taskOwners = @($taskEndpoints | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($taskEndpoints.Count -and ($taskOwners.Count -ne 1 -or $taskOwners[0] -ne $taskService.ProcessId)) {
        throw 'UDP 6001 owner changed. No other service was stopped.'
    }
    Stop-Service -Name 'lkTimeSync' -ErrorAction Stop
    $taskStatus = (Get-Service -Name 'lkTimeSync').Status.ToString()
    $taskAfter = @(Get-NetUDPEndpoint -LocalPort 6001 -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Success = ($taskStatus -eq 'Stopped' -and $taskAfter.Count -eq 0)
        Service = 'lkTimeSync'
        Status = $taskStatus
        Port6001Free = ($taskAfter.Count -eq 0)
        Timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $taskResultPath -Encoding UTF8
} catch {
    [pscustomobject]@{ Success=$false; Error=$_.Exception.Message; Timestamp=(Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $taskResultPath -Encoding UTF8
    exit 1
}
