$taskName   = "AutoGitCommit"
$scriptPath = "C:\Users\tsy\workspace\sys_renewal\commit.ps1"
$workDir    = "C:\Users\tsy\workspace\sys_renewal"
$user       = "$env:USERDOMAIN\$env:USERNAME"

# 动作：隐藏窗口运行脚本
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
    -WorkingDirectory $workDir

# 触发器：登录时启动，然后每 5 分钟重复，无限期
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition

# 设置：错过就补跑、上一次没结束不重复启动、单次最多 4 分钟、电池模式也运行
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 以当前用户身份运行（能用到你的 git 配置和凭据）
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# 如果同名任务已存在先删掉，再注册
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description "登录后每 5 分钟执行 commit.ps1"

# 注册后立刻启动一次，不用等下次登录
Start-ScheduledTask -TaskName $taskName