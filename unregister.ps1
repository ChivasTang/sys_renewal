# unregister.ps1
# Removes the "AutoGitCommit" scheduled task so it no longer runs,
# including at logon / after a PC reboot. Optionally cleans up the
# wrapper script and log that register.ps1 created.
#
# Run once, as the SAME user that registered the task:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\tsy\workspace\sys_renewal\unregister.ps1"
 
$taskName = "AutoGitCommit"
$toolDir  = "C:\Users\tsy\workspace\autocommit"   # wrapper + log dir created by register.ps1
 
# ---------- 1. Stop any run in progress, then delete the task ----------
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    # End a currently-running instance (harmless if it is not running)
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 
    # Deleting the task removes ALL of its triggers, including -AtLogOn,
    # so it will no longer start at logon or after a reboot.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Task '$taskName' removed."
} else {
    Write-Host "Task '$taskName' not found (already removed)."
}
 
# ---------- 2. Verify it is gone ----------
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Warning "Task '$taskName' still exists. Try running PowerShell as Administrator, then re-run this script."
} else {
    Write-Host "Verified: no scheduled task named '$taskName'."
}
 
# ---------- 3. (Optional) clean up the wrapper script + log ----------
# Comment out this block if you want to keep the log for reference.
if (Test-Path $toolDir) {
    Remove-Item $toolDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed tool directory: $toolDir"
}
 
Write-Host "Done. The auto-commit task will not run again, including after a reboot."