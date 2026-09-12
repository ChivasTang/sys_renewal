$repoPath   = "C:\Users\tsy\workspace\sys_renewal"
Set-Location -Path $repoPath
git add .
git commit -m "$(Get-Date -Format 'yyyyMMddHHmmss')"
git push