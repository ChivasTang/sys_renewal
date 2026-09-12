$taskName   = "AutoGitCommit"
$workDir    = "C:\Users\tsy\workspace\sys_renewal"
$scriptPath = "$workDir\commit.ps1"
$toolDir    = "C:\Users\tsy\workspace\autocommit"   # 放日志和包装脚本，在仓库外
$wrapper    = "$toolDir\run_commit.ps1"
$logFile    = "$toolDir\commit.log"
$user       = "$env:USERDOMAIN\$env:USERNAME"

New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

# 1. 生成包装脚本：写日志 + 调用 commit.ps1
@"
`$ErrorActionPreference = 'Continue'
`$log = '$logFile'

# 日志超过 2MB 自动清空，避免无限增长
if ((Test-Path `$log) -and (Get-Item `$log).Length -gt 2MB) { Clear-Content `$log }

"===== `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 开始 =====" | Out-File `$log -Append -Encoding utf8
Set-Location '$workDir'
& '$scriptPath' 2>&1 | ForEach-Object { "`$_" } | Out-File `$log -Append -Encoding utf8
"===== 结束，退出码 `$LASTEXITCODE =====`n" | Out-File `$log -Append -Encoding utf8
"@ | Set-Content -Path $wrapper -Encoding UTF8

# 2. 动作：隐藏窗口运行包装脚本
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`"" `
    -WorkingDirectory $workDir

# 3. 触发器：登录时启动，然后每 5 分钟重复，无限期
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition

# 4. 设置：错过就补跑、上一次没结束不重复启动、单次最多 4 分钟、电池模式也运行
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 5. 以当前用户身份运行
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# 6. 删除旧任务并注册
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description "登录后每 5 分钟执行 commit.ps1，日志在 $logFile"

# 7. 立即跑一次
Start-ScheduledTask -TaskName $taskName