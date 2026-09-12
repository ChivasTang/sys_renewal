# register.ps1
# Registers a Windows scheduled task that runs commit.ps1 every 5 minutes.
# Usage (run once, in PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\tsy\workspace\sys_renewal\register.ps1"

$taskName   = "AutoGitCommit"
$workDir    = "C:\Users\tsy\workspace\sys_renewal"
$scriptPath = "$workDir\commit.ps1"
$toolDir    = "C:\Users\tsy\workspace\autocommit"   # wrapper script + log live outside the repo
$wrapper    = "$toolDir\run_commit.ps1"
$logFile    = "$toolDir\commit.log"
$user       = "$env:USERDOMAIN\$env:USERNAME"

New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

# ---------- 1. Generate the wrapper script (logging + call commit.ps1) ----------
@"
`$ErrorActionPreference = 'Continue'
# Decode git output as UTF-8 to avoid garbled non-ASCII text
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$log = '$logFile'

# Clear the log when it grows past 2MB
if ((Test-Path `$log) -and (Get-Item `$log).Length -gt 2MB) { Clear-Content `$log }

"===== `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') START =====" | Out-File `$log -Append -Encoding utf8
Set-Location '$workDir'
& '$scriptPath' 2>&1 | ForEach-Object { "`$_" } | Out-File `$log -Append -Encoding utf8
"===== END, exit code `$LASTEXITCODE =====``n" | Out-File `$log -Append -Encoding utf8
"@ | Set-Content -Path $wrapper -Encoding UTF8

# ---------- 2. Action: run the wrapper with a hidden window ----------
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`"" `
    -WorkingDirectory $workDir

# ---------- 3. Triggers ----------
$repeat = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition

# Trigger A: at logon, then every 5 minutes (covers reboot)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$logonTrigger.Repetition = $repeat

# Trigger B: 1 minute from now, then every 5 minutes (works right after registering)
$nowTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

# ---------- 4. Settings ----------
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# ---------- 5. Run as the current user (uses your PATH and git credentials) ----------
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# ---------- 6. Remove old task (if any) and register ----------
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $nowTrigger) `
    -Settings $settings -Principal $principal `
    -Description "Runs commit.ps1 every 5 minutes. Log: $logFile" | Out-Null

# ---------- 7. Show result ----------
Write-Host "Task '$taskName' registered."
Get-ScheduledTaskInfo -TaskName $taskName | Select-Object LastRunTime, NextRunTime | Format-Table -AutoSize
Write-Host "Log file: $logFile"
Write-Host "View log: Get-Content `"$logFile`" -Encoding UTF8 -Tail 30"
