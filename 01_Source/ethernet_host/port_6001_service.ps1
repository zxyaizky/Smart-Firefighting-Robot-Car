param([switch]$Restore, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$taskServiceName = 'lkTimeSync'

function Get-TaskPortState {
    $taskService = Get-CimInstance Win32_Service -Filter "Name='$taskServiceName'"
    $taskEndpoints = @(Get-NetUDPEndpoint -LocalPort 6001 -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        Service = $taskService
        Endpoints = $taskEndpoints
    }
}

if ($CheckOnly) {
    $taskState = Get-TaskPortState
    [pscustomobject]@{
        ServiceName = $taskState.Service.Name
        DisplayName = $taskState.Service.DisplayName
        State = $taskState.Service.State
        ServicePID = $taskState.Service.ProcessId
        Port6001Owners = @($taskState.Endpoints | Select-Object -ExpandProperty OwningProcess -Unique)
        ReadOnly = $true
    } | ConvertTo-Json
    exit 0
}

$taskPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $taskArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($Restore) { $taskArgs += '-Restore' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $taskArgs
    } catch {
        Write-Host 'Administrator confirmation was cancelled. No service was changed.'
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
try {
    $taskState = Get-TaskPortState
    if (-not $taskState.Service) { throw 'Service lkTimeSync was not found. No service was changed.' }
    if ($Restore) {
        Start-Service -Name $taskServiceName
        [System.Windows.Forms.MessageBox]::Show('lkTimeSync has been started again. It may occupy UDP 6001 again.', 'Service restored') | Out-Null
        exit
    }
    if ($taskState.Endpoints.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('UDP 6001 is already available. Click Start Listening in the FPGA application.', 'Port available') | Out-Null
        exit
    }
    $taskOwners = @($taskState.Endpoints | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($taskOwners.Count -ne 1 -or $taskOwners[0] -ne $taskState.Service.ProcessId) {
        throw 'UDP 6001 is owned by a different process. Nothing was stopped.'
    }
    if ($taskState.Service.PathName -notmatch '(?i)\\lktsrv\.exe(?:"|\s|$)') {
        throw 'The service executable does not match lktsrv.exe. Nothing was stopped.'
    }
    $taskAnswer = [System.Windows.Forms.MessageBox]::Show(
        "Temporarily stop service lkTimeSync (display name: NI Time Synchronization) to release UDP 6001?`n`nIts current service function will be paused. Startup settings will stay unchanged. Use the restore script afterwards.",
        'Confirm temporary service stop',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($taskAnswer -ne [System.Windows.Forms.DialogResult]::Yes) { exit }
    Stop-Service -Name $taskServiceName
    $taskWaitUntil = (Get-Date).AddSeconds(5)
    do {
        $taskRemaining = @(Get-NetUDPEndpoint -LocalPort 6001 -ErrorAction SilentlyContinue)
        if ($taskRemaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $taskWaitUntil)
    if ($taskRemaining.Count) { throw 'The service was stopped, but UDP 6001 is still occupied. Check the current port owner.' }
    [System.Windows.Forms.MessageBox]::Show('UDP 6001 is available. Close the error dialog and click Start Listening again in the FPGA application.', 'Port released') | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Port operation failed') | Out-Null
    exit 1
}
