<#
.SYNOPSIS
  按区域出包（cn / intl），自动带上正确的 REGION 编译期常量。

.DESCRIPTION
  为什么不让人手敲 flutter build：

      flutter build apk --release --flavor cn --dart-define=REGION=cn

  这条命令里 flavor 和 REGION 是**两个独立参数，谁都不校验谁**。
  漏掉后面那半截，构建照样成功，但打出来的是一个
  「Android 侧是中文区包、Dart 侧按海外区跑」的错包：
  接口指向海外节点、地图渲染开关也跟着错。这类包能装上、能启动，
  只有联网时才露馅，极难查。所以把它封成脚本，两个值绑死。

  另外本机 flutter 全命令必须在**管理员终端**里跑（非提权进程会撞
  CreateFile failed 231），脚本里会先检查这一点并直接拦下。

.EXAMPLE
  # 中国区 APK
  .\tool\build_apk.ps1 -Region cn

  # 海外区 AAB（上 Google Play 用）
  .\tool\build_apk.ps1 -Region intl -AppBundle
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cn', 'intl')]
    [string]$Region,

    # 出 AAB 而不是 APK。上架 Google Play 必须是 AAB。
    [switch]$AppBundle,

    # 按 CPU 架构拆包（体积小约 1/3）。注意：自动更新只能指向一个下载地址，
    # 拆包后要发三个 URL，MVP 阶段别用。
    [switch]$SplitPerAbi,

    [string]$FlutterBat = 'E:\dev\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Stop'

# ---- 1. 权限自检：非提权进程跑 flutter 必失败，先拦下来 ----
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '[×] 当前不是管理员终端。' -ForegroundColor Red
    Write-Host '    本机 flutter 在非提权进程下会报 CreateFile failed 231。' -ForegroundColor DarkGray
    Write-Host '    请重开：Win → powershell → Ctrl+Shift+Enter，然后重跑本脚本。' -ForegroundColor DarkGray
    exit 1
}

if (-not (Test-Path $FlutterBat)) {
    Write-Host "[×] 找不到 flutter: $FlutterBat" -ForegroundColor Red
    exit 1
}

# ---- 2. 定位项目 ----
$appDir = Split-Path -Parent $PSScriptRoot      # tool/ 的上一级 = app/
$defineFile = Join-Path $appDir "dart_define\$Region.json"

if (-not (Test-Path $defineFile)) {
    Write-Host "[×] 缺少 $defineFile" -ForegroundColor Red
    exit 1
}

Set-Location $appDir
# 同步 .NET 的进程当前目录（Set-Location 只管 $PWD，两者可以不同）——
# flutter 子进程就是靠这个目录去找 pubspec.yaml 的。理由同 release.ps1 里的注释。
[System.IO.Directory]::SetCurrentDirectory($appDir)
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'

# ---- 3. 出包 ----
$target = if ($AppBundle) { 'appbundle' } else { 'apk' }
$flutterArgs = @('build', $target, '--release', '--flavor', $Region,
                 "--dart-define-from-file=dart_define/$Region.json")
if ($SplitPerAbi -and -not $AppBundle) { $flutterArgs += '--split-per-abi' }

Write-Host "==> flutter $($flutterArgs -join ' ')" -ForegroundColor Cyan
& $FlutterBat @flutterArgs
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "[×] 构建失败，退出码 $code" -ForegroundColor Red
    exit $code
}

# ---- 4. 报出产物路径（省得去 build/ 里翻）----
$outDir = if ($AppBundle) {
    "$appDir\build\app\outputs\bundle\${Region}Release"
} else {
    "$appDir\build\app\outputs\flutter-apk"
}
Write-Host "[√] 构建完成，产物在: $outDir" -ForegroundColor Green
Get-ChildItem $outDir -File | Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object {
        '{0,-40} {1,10:N1} MB  {2}' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime
    }

if (-not $AppBundle) {
    Write-Host ''
    Write-Host '提示：发新版（应用内更新）的完整步骤见 docs/自动更新-发布流程.md' -ForegroundColor DarkGray
    Write-Host '      别忘了抬 pubspec.yaml 的 version（+N），并把 APK 传到 HTTPS 直链。' -ForegroundColor DarkGray
}
