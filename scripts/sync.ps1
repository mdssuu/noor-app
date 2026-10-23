# GitHub par kiye gaye edits ko yahan laane ke liye:
#   .\scripts\sync.ps1
#
# Ye script origin/master se latest commit kheench kar local branch me
# bina kisi conflict ke jod deti hai.

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

git fetch origin

$behind = (git rev-list --count "HEAD..origin/master")
$ahead  = (git rev-list --count "origin/master..HEAD")

if ($behind -eq "0") {
    Write-Host "Already up to date with origin/master." -ForegroundColor Green
} else {
    Write-Host "Pulling $behind commit(s) from origin/master..." -ForegroundColor Yellow
    git pull --rebase origin master
}

if ($ahead -gt 0 -and $behind -eq "0") {
    Write-Host "`nYou are $ahead commit(s) ahead of GitHub - run 'git push' to publish them." -ForegroundColor Cyan
}

Write-Host "`nRecent history:" -ForegroundColor Cyan
git log --oneline -5
