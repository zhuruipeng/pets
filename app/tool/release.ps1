<#
.SYNOPSIS
  发一次新版：抬 build 号 → 出包 → 回读产物核对 → 打印服务端要改的环境变量。

.DESCRIPTION
  为什么把这四件事绑成一条命令：

  「抬 pubspec 的 +N」和「改服务端的 APP_BUILD」是**两处必须相等、却没有任何
  东西校验**的值。漏掉前者，用户收不到更新（App 自认为已是最新）；漏掉后者，
  用户收到更新提示、装完发现还是旧版本 —— 后者更糟，因为它看起来像更新坏了。

  这两种漏法都发生在「构建成功、一切看起来正常」之后，是靠人记性守不住的那类。
  所以这里做三件事：

    1. 抬号只在一个地方发生（pubspec.yaml）。服务端的值**从构建产物回读**后
       打印出来，不给手抄的机会 —— 手抄就有抄错的可能。
    2. 从 output-metadata.json 回读真实 versionCode 与 pubspec 核对，不一致
       立刻失败（说明有别的东西改了版本，或构建没跑成）。
    3. 把服务端那 5 个环境变量按可直接粘贴的格式打出来。

  为什么默认只抬 build、不动版本名：
  客户端比对**只用 build**（Android versionCode），版本名只是给人看的。
  每次发版把 0.1.0 也一起 +1，版本名会膨胀得很快（0.1.37 这种毫无信息量）。
  到了阶段节点想改版本名时，用 -VersionName 显式指定。

.EXAMPLE
  # 出 cn 包并把 build 抬到 +2
  .\tool\release.ps1 -Region cn -Notes "修复体重曲线在某些机型不显示"

.EXAMPLE
  # 上一轮构建失败了，复用已经抬好的号重跑（不再抬一次）
  .\tool\release.ps1 -Region cn -NoBump

.EXAMPLE
  # 到 0.2.0 这个节点，版本名和 build 一起抬
  .\tool\release.ps1 -Region intl -AppBundle -VersionName 0.2.0

.NOTES
  必须在**管理员终端**里跑：本机非提权进程执行 flutter 会撞
  CreateFile failed 231，build_apk.ps1 会先自检并拦下。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cn', 'intl')]
    [string]$Region,

    # 更新说明。会写进服务端 APP_NOTES，换行即分段。
    [string]$Notes = '',

    # APK 的 HTTPS 直链。给了就一并写进要打印的 APP_APK_URL。
    [string]$ApkUrl = '',

    # 显式指定版本名（如 0.2.0）。不给就保持原样，只抬 build。
    [string]$VersionName = '',

    # 不再抬 build，用当前 pubspec 里的号出包。
    # 上一轮构建失败后用这个，免得号一直被抬走。
    [switch]$NoBump,

    # 只算一遍「会变成什么版本」，不写 pubspec、不构建。
    # 想确认抬号逻辑对不对、或只想拿那几行环境变量时用。
    [switch]$DryRun,

    # 把结果同时写一份到这个文件。给发版记录留档、给 CI 抓取用 ——
    # Write-Host 走主机流，既不能被 `$x = & script.ps1` 接住也不能重定向，
    # 所以「需要留档的东西」一律走 Emit。
    [string]$ResultFile = '',

    [switch]$AppBundle,

    [string]$FlutterBat = 'E:\dev\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Stop'

# 让 .NET 的进程当前目录跟上 PowerShell 的 $PWD —— 这两者**不是一回事**：
# `Set-Location`（cd）只改 $PWD，而 `[System.IO.*]` 用的是 .NET 的进程目录。
# 从开始菜单起的 PowerShell，.NET 目录是 C:\WINDOWS\system32，所以本脚本里
# 任何走 [System.IO.*] 的相对路径都会落到那里（已实测踩到，见下方 $ResultFile）。
try { [System.IO.Directory]::SetCurrentDirectory((Get-Location).Path) } catch { }

$script:EmitSink = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Emit([string]$text) {
    Write-Output $text
    if ($script:EmitSink) {
        [System.IO.File]::AppendAllText(
            $script:EmitSink, $text + [Environment]::NewLine, $script:Utf8NoBom)
    }
}

if ($ResultFile -ne '') {
    # 相对路径先按 PowerShell 的当前位置补成绝对路径。
    # [System.IO.File] 用的是 .NET 的进程当前目录，而 Set-Location 只改 $PWD，
    # 两者可以是完全不同的地方 —— 于是 `-ResultFile .\build\x.txt` 会被解析成
    # C:\WINDOWS\system32\build\x.txt，报「未能找到路径…的一部分」。
    #
    # 顺序不能省：必须先 Join-Path 到 $PWD（这一步用的是 PowerShell 的目录），
    # 之后才轮到 GetFullPath 归一化；反过来只调 GetFullPath 会走 .NET 目录，重现同一个错。
    if (-not [System.IO.Path]::IsPathRooted($ResultFile)) {
        $ResultFile = Join-Path (Get-Location).Path $ResultFile
    }
    $ResultFile = [System.IO.Path]::GetFullPath($ResultFile)
    $script:EmitSink = $ResultFile
    $dir = Split-Path -Parent $ResultFile
    if ($dir -ne '' -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($ResultFile, '', $script:Utf8NoBom)
    Write-Host "    [i] 结果同时写入: $ResultFile" -ForegroundColor DarkGray
}

$appDir = Split-Path -Parent $PSScriptRoot      # tool/ 的上一级 = app/
$pubspec = Join-Path $appDir 'pubspec.yaml'

if (-not (Test-Path $pubspec)) {
    Write-Host "[×] 找不到 $pubspec" -ForegroundColor Red
    exit 1
}

# ---- 1. 读当前版本 ----
# 必须显式指定 UTF-8：pubspec.yaml 是**无 BOM** 的 UTF-8 文件，PowerShell 5.1
# 对无 BOM 文件默认按 ANSI(GBK) 解 —— 而我们的 pubspec 里有中文 description，
# 那样读进来就是乱码，再写回去等于把注释毁掉。
# （同类的坑：本目录的 .ps1 脚本自己必须带 UTF-8 BOM，否则解析阶段就会因为
# 中文注释与引号错位而报「字符串缺少终止符」。）
#
# 顺带把换行风格也记下来：`WriteAllLines` 会强制用平台的 Environment.NewLine
# （这里是 CRLF），而这个文件是 LF —— 用它写回去会让 git 看到「整个文件都改了」
# 的假 diff，review 时全是噪音。
$rawText = [System.IO.File]::ReadAllText($pubspec, $script:Utf8NoBom)
$eol = if ($rawText.Contains("`r`n")) { "`r`n" } else { "`n" }
$hadTrailingEol = $rawText.EndsWith("`n")
$lines = New-Object System.Collections.Generic.List[string]
$lines.AddRange($rawText -split "`r?`n")
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    $lines.RemoveAt($lines.Count - 1)
}
$idx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*version:\s*(.+?)\s*$') { $idx = $i; break }
}
if ($idx -lt 0) {
    Write-Host '[×] pubspec.yaml 里没有 version 行' -ForegroundColor Red
    exit 1
}

$raw = $Matches[1]
if ($raw -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') {
    # 没有 +N 的话 Flutter 默认 build 号为 0，自动更新永远认不出新版。
    # 与其让它悄悄跑成 0，不如在这里拦下。
    Write-Host "[×] version 格式不对: '$raw'" -ForegroundColor Red
    Write-Host '    需要 <major>.<minor>.<patch>+<build>，例如 0.1.0+1' -ForegroundColor DarkGray
    exit 1
}

$name = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$build = [int]$Matches[4]

if ($NoBump) {
    $newBuild = $build
} else {
    $newBuild = $build + 1
}
if ($VersionName -ne '') {
    if ($VersionName -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host "[×] -VersionName 需要 x.y.z 形式，收到 '$VersionName'" -ForegroundColor Red
        exit 1
    }
    $newName = $VersionName
} else {
    $newName = $name
}

$newRaw = "$newName+$newBuild"
Write-Host ''
Write-Host "==> 版本: $raw  ->  $newRaw" -ForegroundColor Cyan

if ($newBuild -eq $build -and $newName -eq $name) {
    Write-Host '    未发生变化（-NoBump 且未指定新版本名）' -ForegroundColor DarkGray
}

if (-not $NoBump -or $newName -ne $name) {
    if ($DryRun) {
        Write-Host '    [DryRun] 不写回 pubspec' -ForegroundColor DarkGray
    } else {
        $lines[$idx] = ($lines[$idx] -replace '^(version:\s*).*$', "`${1}$newRaw")
        $outText = [string]::Join($eol, $lines)
        if ($hadTrailingEol) { $outText += $eol }
        [System.IO.File]::WriteAllText($pubspec, $outText, $script:Utf8NoBom)
        Write-Host "    已写入 $pubspec" -ForegroundColor DarkGray
    }
}

if ($DryRun) {
    $dryUrl = if ($ApkUrl -ne '') { $ApkUrl } else { 'https://<把 APK 传到这里>.apk' }
    $dryNotes = if ($Notes -ne '') { $Notes } else { '<这次改了什么>' }
    Emit ''
    Emit '================ [DryRun] 服务端环境变量会是这样 ================'
    Emit "版本变化: $raw -> $newRaw"
    Emit "APP_VERSION=$newName"
    Emit "APP_BUILD=$newBuild"
    Emit "APP_APK_URL=$dryUrl"
    Emit "APP_NOTES=$dryNotes"
    Emit 'APP_MIN_BUILD=0'
    Emit '================================================================'
    exit 0
}

# ---- 2. 出包 ----
$buildArgs = @{ Region = $Region }
if ($AppBundle) { $buildArgs['AppBundle'] = $true }

Write-Host ''
& (Join-Path $PSScriptRoot 'build_apk.ps1') @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "[×] 构建失败（退出码 $LASTEXITCODE）。" -ForegroundColor Red
    Write-Host "    pubspec 已经抬到 $newRaw —— 重跑时加 -NoBump 复用这个号，" -ForegroundColor DarkGray
    Write-Host '    否则号会一路往上跳（无害，只是浪费）。' -ForegroundColor DarkGray
    exit $LASTEXITCODE
}

# ---- 3. 回读产物的 versionCode，与 pubspec 核对 ----
# output-metadata.json 是 AGP 在打包时写的，是「这个包到底是多少号」的第一手证据。
if ($AppBundle) {
    $metaPath = Join-Path $appDir "build\app\outputs\bundle\${Region}Release\output-metadata.json"
    $artifact = Join-Path $appDir "build\app\outputs\bundle\${Region}Release"
} else {
    $metaPath = Join-Path $appDir "build\app\outputs\apk\$Region\release\output-metadata.json"
    $artifact = Join-Path $appDir "build\app\outputs\flutter-apk"
}

Write-Host ''
if (Test-Path $metaPath) {
    $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $el = $meta.elements[0]
    $outCode = [int]$el.versionCode
    $outName = [string]$el.versionName

    Write-Host "==> 产物核对: versionName=$outName  versionCode=$outCode" -ForegroundColor Cyan
    if ($outCode -ne $newBuild) {
        # 出现这种情况说明有别的东西改了版本（或构建没真正跑成）。
        # 这时候绝不能继续往下走：一旦服务端按 pubspec 的值配置，
        # 就会出现「提示有新版但装不上 / 装了还是旧版」的静默故障。
        Write-Host "[×] 产物里的 versionCode ($outCode) 与 pubspec ($newBuild) 不一致！" -ForegroundColor Red
        Write-Host '    别继续发布。检查有没有别的脚本/命令改了版本，或构建是否真的产出了新包。' -ForegroundColor DarkGray
        exit 1
    }
    Write-Host '    [√] 一致' -ForegroundColor Green
} else {
    Write-Host "[!] 没找到 $metaPath，跳过核对（不阻断）" -ForegroundColor Yellow
}

# ---- 4. 打印服务端要改的环境变量 ----
$url = if ($ApkUrl -ne '') { $ApkUrl } else { 'https://<把 APK 传到这里>.apk' }
$notes = if ($Notes -ne '') { $Notes } else { '<这次改了什么，会显示在更新弹框里>' }

Write-Host ''
Write-Host '================ 服务端环境变量（照着抄，改完重启服务）================' -ForegroundColor Green
Write-Host ''
Write-Host "APP_VERSION=$newName"
Write-Host "APP_BUILD=$newBuild"
Write-Host "APP_APK_URL=$url"
Write-Host "APP_NOTES=$notes"
Write-Host 'APP_MIN_BUILD=0'
if ($Region -eq 'intl') {
    Write-Host 'APP_IOS_STORE_URL=<App Store 链接>'
}
Write-Host ''
Write-Host "  [!] APP_BUILD 必须是 $newBuild —— 客户端就是拿它比大小。" -ForegroundColor Yellow
Write-Host '     服务端留旧值 = 提示有新版但装完还是旧的；留大值 = 所有人都被提示更新。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  验证（应看到 build 为上面那个数）：' -ForegroundColor DarkGray
if ($Region -eq 'cn') {
    Write-Host '    curl -s https://api.pet.weiyuantool.com/app/version.json' -ForegroundColor DarkGray
} else {
    Write-Host '    curl -s https://api.pet.example.com/app/version.json' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host "  产物目录: $artifact" -ForegroundColor DarkGray
Write-Host '========================================================================' -ForegroundColor Green
