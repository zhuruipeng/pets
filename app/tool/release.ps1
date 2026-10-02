<#
.SYNOPSIS
  发一次新版：抬版本号（build + patch）→ 出包 → 回读产物核对 → 打印服务端要改的环境变量。

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

  版本号怎么走：
  客户端更新比对**只用 build**（Android versionCode），版本名（x.y.z）是给人看的。
  默认每次出包 **build +1 且 patch +1**（0.1.0 → 0.1.1），让版本名也自然往前涨，
  不会再「一直是 0.1.0」。要只抬 build 不动名，加 -NoBumpName；要精确指定
  版本名（如 0.2.0 这种节点），用 -VersionName。

.EXAMPLE
  # 出 cn 包：build +1、版本名 patch +1（0.1.0 → 0.1.1）
  .\tool\release.ps1 -Region cn -Notes "修复体重曲线在某些机型不显示"

.EXAMPLE
  # 只抬 build、版本名保持 0.1.0 不动
  .\tool\release.ps1 -Region cn -NoBumpName

.EXAMPLE
  # 上一轮构建失败了，复用已经抬好的号重跑（不再抬一次）
  .\tool\release.ps1 -Region cn -NoBump

.EXAMPLE
  # 到 0.2.0 这个节点，版本名显式指定、build 一起抬
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

    # 显式指定版本名（如 0.2.0）。不给就自动抬 patch 号（0.1.0 → 0.1.1）。
    [string]$VersionName = '',

    # 不再抬 build，用当前 pubspec 里的号出包。
    # 上一轮构建失败后用这个，免得号一直被抬走。
    [switch]$NoBump,

    # 只抬 build、不自动抬版本名（patch 号）。给想严格保持 x.y.0 的人用；
    # 默认会自动 patch +1，所以「一直是 0.1.0」不会再发生。
    [switch]$NoBumpName,

    # 出包后不自动 commit + push pubspec 的版本号（默认会自动入库并核对远端 SHA）。
    # 只在「想让版本号改动跟别的改动分开单独提交」时才用。
    [switch]$NoPush,

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
# 两种 UTF-8，各有用处，别混：
# - Utf8NoBom：写 **pubspec.yaml** 用。它本来就是无 BOM 的，加 BOM 会让 Flutter 解析出问题。
# - Utf8Bom：写 **结果文件** 用。无 BOM 的 UTF-8 在 Windows 上被老工具（记事本、
#   PS 5.1 的 Get-Content）按 GBK 解读，中文直接变乱码（已实测踩到）。
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Emit([string]$text) {
    Write-Output $text
    if ($script:EmitSink) {
        [System.IO.File]::AppendAllText(
            $script:EmitSink, $text + [Environment]::NewLine, $script:Utf8Bom)
    }
}

# 只落盘、不上屏。
#
# 为什么需要它：**正常流程的输出全走 Write-Host**（彩色、给人看），而 Write-Host
# 既不进管道也不被重定向 —— 于是只靠 Emit 的话，`-ResultFile` 在真实构建后
# 只会得到一个**空文件**（已实测：老板跑完发回来的就是空的，这一版修掉）。
# 需要留档的几项在结尾单独过一遍 Record，终端显示保持不变。
function Record([string]$text) {
    if ($script:EmitSink) {
        [System.IO.File]::AppendAllText(
            $script:EmitSink, $text + [Environment]::NewLine, $script:Utf8Bom)
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
    # 截断重建：文件从 0 字节起步，之后每次 Append 都沿用同一个编码。
    # 这里用带 BOM 的 —— 结果文件是给人（和别的工具）读的，无 BOM 的中文
    # 在 Windows 上会被按 GBK 解读成乱码。
    [System.IO.File]::WriteAllText($ResultFile, '', $script:Utf8Bom)
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
} elseif ($NoBump -or $NoBumpName) {
    # 复用当前版本名（-NoBump 复用号、-NoBumpName 只抬 build 不抬名）。
    $newName = $name
} else {
    # 默认自动抬 patch：0.1.0 → 0.1.1。解决「每次出包版本名一直 0.1.0」。
    $newName = "$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)"
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

# ---- 3.5 产物指纹 ----
# 发版要留档：拿到 SHA1 才能核对「用户下到的确实是这个包」。
#
# 顺带写清一个容易误判的现象：**若这次改动对产物没有实际影响**（例如只改了
# 等价写法、或只动了 test/ 与 tool/），Gradle 会因「打包输入内容未变」判
# up-to-date 而复用已有 APK —— 此时 `apk/**/release/` 里那份的时间戳不更新，
# 只有 flutter 拷到 `flutter-apk/` 的那份时间戳变新，**SHA1 与上一版一模一样**。
# 那不是构建失败，恰恰是「等价改动」的字节级证据（本仓库 03a09ea 那轮实测如此）。
$artifactName = if ($AppBundle) { "app-$Region-release.aab" } else { "app-$Region-release.apk" }
$artifactPath = Join-Path $artifact $artifactName
$artifactSize = 0
$artifactTime = ''
$artifactSha1 = ''

Write-Host ''
if (Test-Path $artifactPath) {
    $fi = Get-Item $artifactPath
    $artifactSize = $fi.Length
    $artifactTime = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    $artifactSha1 = (Get-FileHash $artifactPath -Algorithm SHA1).Hash.ToLower()

    Write-Host "==> 产物指纹: $artifactName" -ForegroundColor Cyan
    Write-Host ("    {0:N1} MB（{1} 字节）  {2}" -f ($artifactSize / 1MB), $artifactSize, $artifactTime)
    Write-Host "    SHA1: $artifactSha1"
} else {
    Write-Host "[!] 没找到产物 $artifactPath（跳过指纹）" -ForegroundColor Yellow
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

# ---- 5. 落盘（-ResultFile）----
# 上面那些都是 Write-Host，不会进文件；真正需要留档的只有下面这几项。
Record ''
Record '================ 发版记录 ================'
Record ('时间      : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Record "区域      : $Region"
Record "版本      : $raw -> $newRaw"
Record "产物      : $artifactPath"
if ($artifactSha1 -ne '') {
    Record "大小      : $artifactSize 字节（$artifactTime）"
    Record "SHA1      : $artifactSha1"
}
Record "APP_VERSION=$newName"
Record "APP_BUILD=$newBuild"
Record "APP_APK_URL=$url"
Record "APP_NOTES=$notes"
Record 'APP_MIN_BUILD=0'
Record '=========================================='

# ---- 6. 版本号入库（提交 + 推送）----
# 为什么放在最后：抬号写 pubspec 是这个脚本做的事，但**提交与推送不做**，
# 于是 GitHub 上的版本号会一直停在出包前 —— 2026-10-02 实测踩到：
# APK 已经是 0.1.7+9，pubspec 改了却没 commit，README 与远端全对不上实际产物。
# 老板的硬约定是「开发完成 = 已推 GitHub」，那这一步就没有理由不自动做。
if ($NoPush) {
    Write-Host ''
    Write-Host '== 版本号未入库 ==' -ForegroundColor Yellow
    Write-Host "   pubspec 已是 $newRaw，但没有 commit（-NoPush）。" -ForegroundColor Yellow
    Write-Host '   记得手动：git add app/pubspec.yaml && git commit -m "chore(release): 版本号抬到 <新号>" && git push' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '== 版本号入库 ==' -ForegroundColor Cyan

    $repoRoot = Split-Path -Parent $appDir
    Push-Location $repoRoot
    try {
        $msg = "chore(release): 版本号抬到 $newRaw`n`nrelease.ps1 抬号后自动入库，保证 GitHub 上的版本号与已出包的 APK 一致。`n`n产物：$artifactPath"
        & git add -- 'app/pubspec.yaml'
        & git commit -m $msg -- 'app/pubspec.yaml'
        if ($LASTEXITCODE -ne 0) {
            Write-Host '   commit 失败（可能没有实际改动），跳过推送。' -ForegroundColor Yellow
        } else {
            & git push origin HEAD:refs/heads/main
            # SSH 走最后一步时可能不回显就被 SIGTERM，看着像失败其实已落地，
            # 所以一律用 ls-remote 回读远端真值来判断成败（别信 push 的回显）。
            $remote = (& git ls-remote origin refs/heads/main)
            $localSha = (& git rev-parse HEAD)
            if ($remote -match "^([0-9a-f]{40})" -and $Matches[1] -eq $localSha) {
                Write-Host "   已推送并核对：$($localSha.Substring(0,7))" -ForegroundColor Green
                Record "入库      : $localSha（已推送 origin/main）"
            } else {
                Write-Host '   ⚠️ 推送未确认落地！远端 SHA 与本地不一致。' -ForegroundColor Red
                Write-Host "      本地 $localSha" -ForegroundColor Red
                Write-Host "      远端 $($remote -replace '\s+refs/heads/main','')" -ForegroundColor Red
                Write-Host '      手动重试：git push origin HEAD:refs/heads/main' -ForegroundColor Red
                Record '入库      : [!] 推送未确认落地，需手动重试'
            }
        }

        # 顺手报一下工作区还有没有别的东西没入库 —— 收尾自检第①问。
        $dirty = & git status --short
        if ($dirty) {
            Write-Host ''
            Write-Host '   工作区还有未入库的改动：' -ForegroundColor Yellow
            $dirty | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        }
    } finally {
        Pop-Location
    }
}

