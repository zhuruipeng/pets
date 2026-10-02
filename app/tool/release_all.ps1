<#
.SYNOPSIS
  一条命令出包：git pull → flutter test → release.ps1。

.DESCRIPTION
  为什么存在：给老板的多行粘贴命令里，出包那行总在最后，
  粘贴顺序一乱或者分行执行，它就被丢掉（2026-10-01 / 10-02 两次实测，
  老板跑完测试发现"打包命令不在里边"）。所以把整条链路收进一个脚本，
  对外只暴露一条命令。

  测试不过就停，绝不带病出包。

.EXAMPLE
  .\tool\release_all.ps1                # cn 区，测试过了自动抬号出包
  .\tool\release_all.ps1 -Region intl
  .\tool\release_all.ps1 -NoBump        # 复用已经抬过的版本号（重跑时用）

.NOTES
  必须在管理员终端跑（本机非提权跑 flutter 撞管道 231）。
#>
param(
    [ValidateSet('cn', 'intl')]
    [string]$Region = 'cn',

    # 上一轮构建失败后版本号已抬过时，用它复用那个号
    [switch]$NoBump
)

$app = Split-Path -Parent $PSScriptRoot
Set-Location $app

Write-Host ''
Write-Host '== 1/3  git pull ==' -ForegroundColor Cyan
git pull
if ($LASTEXITCODE -ne 0) {
    Write-Host 'git pull 失败（多半是本地有未提交改动或冲突），把上面的输出贴给小未。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '== 2/3  flutter test ==' -ForegroundColor Cyan
flutter test
if ($LASTEXITCODE -ne 0) {
    Write-Host 'flutter test 没过，已停止出包。把上面的失败段落贴给小未。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '== 3/3  出包 ==' -ForegroundColor Cyan
if ($NoBump) {
    & "$PSScriptRoot\release.ps1" -Region $Region -NoBump
} else {
    & "$PSScriptRoot\release.ps1" -Region $Region
}
