<#
.SYNOPSIS
    一键同步 fork 并安全合并令牌（修复版）
#>
$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Fork 更新工具"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Fork 仓库一键更新（令牌安全合并）" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Set-Location $PSScriptRoot

# 检查 Python
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $pythonCmd) {
    Write-Host "错误：未检测到 Python，请先安装 Python 3" -ForegroundColor Red
    Read-Host "按 Enter 键退出"
    exit 1
}
$pythonExe = $pythonCmd.Source

# 备份目录
$BackupDir = Join-Path $HOME "cfnb_token_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Write-Host "`n[1/6] 备份当前令牌文件到 $BackupDir" -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
@('config.json', 'git_sync.ps1', 'git_sync.sh', 'ip.txt') | ForEach-Object {
    if (Test-Path $_) {
        Copy-Item $_ $BackupDir -Force
        Write-Host "  已备份 $_" -ForegroundColor Green
    }
}

# 从备份的 git_sync.ps1 中提取 GitHub 信息（使用外部 Python 脚本文件，避免变量展开问题）
$gitSyncBackup = Join-Path $BackupDir "git_sync.ps1"
if (-not (Test-Path $gitSyncBackup)) {
    Write-Host "错误：未找到 git_sync.ps1，请先填写令牌" -ForegroundColor Red
    Read-Host "按 Enter 键退出"
    exit 1
}

# 生成临时 Python 脚本，传递备份文件路径作为参数
$tempPyExtract = Join-Path $env:TEMP "cfnb_extract_info.py"
@'
import re, sys
file_path = sys.argv[1]
with open(file_path, encoding='utf-8') as f:
    text = f.read()
token = re.search(r'\$github_token\s*=\s*"(.+?)"', text)
user  = re.search(r'\$github_username\s*=\s*"(.+?)"', text)
repo  = re.search(r'\$repo_name\s*=\s*"(.+?)"', text)
branch= re.search(r'\$branch\s*=\s*"(.+?)"', text)
print(token.group(1) if token else '')
print(user.group(1) if user else '')
print(repo.group(1) if repo else '')
print(branch.group(1) if branch else '')
'@ | Out-File -FilePath $tempPyExtract -Encoding UTF8

$result = & $pythonExe $tempPyExtract $gitSyncBackup
Remove-Item $tempPyExtract -Force

$lines = $result -split "`n"
$Token = $lines[0].Trim()
$Username = $lines[1].Trim()
$Repo = $lines[2].Trim()
$Branch = $lines[3].Trim()

if ([string]::IsNullOrEmpty($Token) -or $Token -eq "your_github_personal_access_token_here") {
    Write-Host "错误：git_sync.ps1 中的 GitHub Token 仍是占位符，请先填写真实令牌" -ForegroundColor Red
    Read-Host "按 Enter 键退出"
    exit 1
}

# 分支占位符自动探测
if ([string]::IsNullOrEmpty($Branch) -or $Branch -eq "your_branch") {
    Write-Host "分支名为占位符，尝试自动探测..." -ForegroundColor Yellow
    git remote set-url origin "https://${Token}@github.com/${Username}/${Repo}.git" 2>$null
    $Branch = (git remote show origin | Select-String "HEAD branch").Line -replace ".*HEAD branch: ", ""
    if ([string]::IsNullOrEmpty($Branch)) {
        Write-Host "无法自动探测，请手动在 git_sync.ps1 中设置 `$branch = ""main""" -ForegroundColor Red
        Read-Host "按 Enter 键退出"
        exit 1
    }
    Write-Host "已探测到默认分支：$Branch" -ForegroundColor Green
}

Write-Host "`n[2/6] 设置免认证远程地址" -ForegroundColor Yellow
git remote set-url origin "https://${Token}@github.com/${Username}/${Repo}.git"

Write-Host "`n[3/6] 拉取远程并强制对齐" -ForegroundColor Yellow
git fetch origin $Branch
git reset --hard "origin/$Branch"

Write-Host "`n[4/6] 注入令牌到 config.json" -ForegroundColor Yellow
$configBackup = Join-Path $BackupDir "config.json"
if (Test-Path $configBackup) {
    $tempPyMerge = Join-Path $env:TEMP "cfnb_merge_tokens.py"
    @'
import json, sys
backup_file = sys.argv[1]
current_file = 'config.json'
with open(backup_file, 'r', encoding='utf-8') as f:
    backup = json.load(f)
with open(current_file, 'r', encoding='utf-8') as f:
    current = json.load(f)
token_fields = [
    "WXPUSHER_APP_TOKEN", "WXPUSHER_UIDS",
    "CF_API_TOKEN", "CF_ZONE_ID", "CF_DNS_RECORD_NAME"
]
for key in token_fields:
    if key in backup and key in current:
        current[key] = backup[key]
with open(current_file, 'w', encoding='utf-8') as f:
    json.dump(current, f, indent=4, ensure_ascii=False)
print("config.json 令牌注入完成")
'@ | Out-File -FilePath $tempPyMerge -Encoding UTF8
    & $pythonExe $tempPyMerge $configBackup
    Remove-Item $tempPyMerge -Force
} else {
    Write-Host "未找到 config.json 备份，跳过" -ForegroundColor DarkYellow
}

Write-Host "`n[5/6] 更新 git_sync.ps1 和 git_sync.sh（含 --allow-unrelated-histories）" -ForegroundColor Yellow
$tempPySync = Join-Path $env:TEMP "cfnb_update_sync.py"
@"
import re, sys

token = sys.argv[1]
username = sys.argv[2]
repo = sys.argv[3]
branch = sys.argv[4]

def update_file(filename, pattern_map, add_allow=False):
    try:
        with open(filename, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return
    for pattern, replacement in pattern_map.items():
        text = re.sub(pattern, replacement, text)
    if add_allow and 'allow-unrelated-histories' not in text:
        text = text.replace(
            'git pull origin "$branch"',
            'git pull origin "$branch" --allow-unrelated-histories'
        ).replace(
            'git pull origin \$branch',
            'git pull origin \$branch --allow-unrelated-histories'
        )
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'{filename} 已更新')

ps_patterns = {
    r'\$github_token\s*=\s*".*?"': f'$github_token = "{token}"',
    r'\$github_username\s*=\s*".*?"': f'$github_username = "{username}"',
    r'\$repo_name\s*=\s*".*?"': f'$repo_name = "{repo}"',
    r'\$branch\s*=\s*".*?"': f'$branch = "{branch}"',
}
update_file('git_sync.ps1', ps_patterns, add_allow=True)

sh_patterns = {
    r'github_token=".*?"': f'github_token="{token}"',
    r'github_username=".*?"': f'github_username="{username}"',
    r'repo_name=".*?"': f'repo_name="{repo}"',
    r'branch=".*?"': f'branch="{branch}"',
}
update_file('git_sync.sh', sh_patterns, add_allow=True)
"@ | Out-File -FilePath $tempPySync -Encoding UTF8
& $pythonExe $tempPySync $Token $Username $Repo $Branch
Remove-Item $tempPySync -Force

Write-Host "`n[6/6] 恢复 ip.txt" -ForegroundColor Yellow
$ipBackup = Join-Path $BackupDir "ip.txt"
if (Test-Path $ipBackup) {
    Copy-Item $ipBackup "ip.txt" -Force
    Write-Host "ip.txt 已恢复" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ✅ 一键更新完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "备份保留在：$BackupDir"
Write-Host "可运行 python main.py 测试"

Read-Host "`n按 Enter 键退出"