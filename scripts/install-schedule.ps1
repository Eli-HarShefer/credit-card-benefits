# Registers the weekly refresh as a Windows scheduled task.
# Run once:  powershell -ExecutionPolicy Bypass -File scripts\install-schedule.ps1
#
# Cloud routines cannot do this job - they run in Anthropic's cloud with no access
# to this machine, and both the harvest scripts and the data files are local.
#
# ASCII-only source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$task = 'CreditCardBenefits-WeeklyRefresh'
$script = Join-Path $PSScriptRoot 'refresh-all.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 9:00am

$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -RunOnlyIfNetworkAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger `
  -Settings $settings -Force `
  -Description 'Re-harvests be-plus + max benefit catalogues and rebuilds dashboard.html' | Out-Null

$info = Get-ScheduledTask -TaskName $task | Get-ScheduledTaskInfo
Write-Host "registered: $task"
Write-Host "next run:   $($info.NextRunTime)"
Write-Host ''
Write-Host 'run it now with:   Start-ScheduledTask -TaskName ' $task
Write-Host 'remove it with:    Unregister-ScheduledTask -TaskName' $task '-Confirm:$false'
