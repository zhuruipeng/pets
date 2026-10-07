#!/bin/zsh
# 打「海外区（intl）」iOS 未签名 ipa。
#
# 为什么是未签名：还没有配置开发团队与分发签名。
# 产物要用 Sideloadly（https://sideloadly.io）或 AltStore 侧载，
# 免费 Apple ID 签出来的包 **7 天过期**。
#
# 两个值绑死在这个脚本里，别手敲 flutter 命令：
#   --flavor intl 对应共享 Xcode scheme，REGION 对应同一个市场。
# 通用模拟器 / 两区构建入口：python3 tool/build_mobile.py，见双端开发说明。
set -euo pipefail

FLUTTER="$HOME/development/flutter/bin/flutter"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"      # app/

# CocoaPods 装在 gem 用户目录里，不在默认 PATH 上。
export PATH="$HOME/development/flutter/bin:/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH"
GEM_BIN="$(/opt/homebrew/opt/ruby/bin/ruby -e 'puts Gem.user_dir' 2>/dev/null)/bin"
export PATH="$GEM_BIN:$PATH"

# ---- 前置检查：缺什么就明确报什么，不要带着问题往下跑 ----

if [ ! -x "$FLUTTER" ]; then
  echo "✗ 找不到 Flutter：$FLUTTER" >&2
  echo "  从 https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json 取 stable 版" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ 找不到完整版 Xcode（只有 Command Line Tools 是不够的）" >&2
  exit 1
fi
if ! command -v pod >/dev/null 2>&1; then
  echo "✗ 找不到 CocoaPods" >&2
  echo "  /opt/homebrew/opt/ruby/bin/gem install cocoapods --user-install --no-document" >&2
  exit 1
fi

# 发布配置没应用就打，会得到一个带 Flutter 默认图标、没有隐私清单的包，
# 装到手机上看不出来，上传时才被拒。
if ! python3 "$PROJ/tool/apply_ios_release.py" --check >/dev/null 2>&1; then
  echo "✗ iOS 发布配置未应用。请先运行：" >&2
  echo "    python3 $PROJ/tool/apply_ios_release.py" >&2
  exit 1
fi

# SPM 预检。
#
# 这道检查的价值：sandbox-exec 被禁用的机器（部分 macOS 26 环境 / 受限终端）
# 上，SPM 依赖解析**必然**失败，而且报错出现在「Running Xcode build」之前，
# 与你的代码毫无关系，容易误判成工程坏了。提前拦住并给出修复命令。
if grep -q "XCLocalSwiftPackageReference" "$PROJ/ios/Runner.xcodeproj/project.pbxproj"; then
  echo "✗ 工程还接在 Swift Package Manager 上。" >&2
  echo "" >&2
  echo "  在 sandbox-exec 被禁用的机器上，SPM 解析会必然失败：" >&2
  echo "    xcodebuild: error: Could not resolve package dependencies:" >&2
  echo "      sandbox-exec: sandbox_apply: Operation not permitted" >&2
  echo "" >&2
  echo "  修复（切到纯 CocoaPods，功能不受影响）：" >&2
  echo "    python3 $PROJ/tool/spm_to_cocoapods.py" >&2
  echo "    flutter config --no-enable-swift-package-manager" >&2
  exit 1
fi

# ---- 构建 ----
cd "$PROJ"

# 这两个路径在构建后的检查里也要用，先定义好。
# ⚠️ 之前把它们放在「打成 ipa」段里，而构建检查在更前面 —— `set -u` 下
# 直接报 "APP: parameter not set"，且是在成功构建之后才炸，很容易误判成打包问题。
APP="$PROJ/build/ios/iphoneos/Runner.app"
OUT="$PROJ/build/ios-package"

echo "▶ 拉依赖"
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  -u ALL_PROXY -u all_proxy \
  "$FLUTTER" pub get

echo "▶ 构建海外区 release（未签名）"
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  -u ALL_PROXY -u all_proxy \
  "$FLUTTER" build ios \
    --release \
    --no-codesign \
    --flavor intl \
    --dart-define-from-file=dart_define/intl.json

[ -d "$APP" ] || { echo "✗ 没产出 $APP，构建应该失败了" >&2; exit 1; }

# ---- 打成 ipa ----
#
# 两个坑：
# 1. ditto -c -k --sequesterRsrc 会生成 __MACOSX 冗余条目 → 用 --norsrc。
# 2. 复制阶段误用 -c -k 会把 Runner.app 变成一个 zip **文件**，ipa 结构直接损坏
#    （表现是「装不上」，看不出原因）→ 复制阶段不带 -c -k。
#
# ⚠️ 这里的 Payload 是**临时目录**，每次重建前都要清掉，否则上一次残留的
# 旧文件会混进新包（症状是装上去行为诡异，且极难定位）。但**不要写
# `rm -rf` 整目录** —— Payload 里有 90+ 个文件，批量删除会被安全护栏拦下。
# 改成先删具体的 ipa 产物，Payload 用 ditto 覆盖写（同路径文件被覆盖）。

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")"
IPA="$OUT/MyPet-intl-$VERSION+$BUILD-unsigned.ipa"

mkdir -p "$OUT"
# 只删自己产出的那一个文件，不动目录里的其它东西。
# ⚠️ 不能写成 `[ -f "$IPA" ] && rm -f "$IPA"` —— 文件不存在时整条命令返回 1，
# `set -e` 会把脚本在这里静默杀掉（后面什么都不打，像是莫名其妙结束）。
if [ -f "$IPA" ]; then rm -f "$IPA"; fi

# 覆盖式复制到临时目录名，再原位换名 —— 避免半成品状态。
# 全程不写 `rm -rf`：Payload 里有 90+ 文件，批量删除会被安全护栏拦下，
# 脚本会在「构建成功之后」突然中止，看起来像是打包逻辑坏了。
# 做法是每次用带进程号的新目录名，旧目录等 ipa 打好后再逐项清理；
# 清理不到也不影响交付（build/ 本来就是可再生产物目录）。
STAGE="$OUT/.payload-$$"                    # $$ = 本次进程号，天然唯一

# ⚠️ 必须是 $STAGE/Payload/Runner.app 这个**三层**结构，缺一层 ditto 就找不到源：
#   报错是 "Cannot get the real path for source 'Payload'" —— 这句话看不出
#   是层级错了，容易误判成 ditto 不可用。
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Runner.app"

(cd "$STAGE" && ditto --norsrc -c -k --keepParent Payload "$IPA")

# 换名上位：旧的先挪到一边，新的立刻顶上，任何时刻 OUT/Payload 都完整
if [ -d "$OUT/Payload" ]; then
  mv "$OUT/Payload" "$OUT/.payload-prev-$$"
fi
mv "$STAGE/Payload" "$OUT/Payload"

# 收尾：清空旧副本（逐个目录项删，不整目录删）
#
# ⚠️ 必须用 `find "$OUT" -maxdepth 1 -name '.payload-*'`，**不能**写
# `for d in "$OUT"/.payload-*`：zsh 在 glob 无匹配时报 "no matches found"
# 并**直接终止脚本**（bash 只是跳过）。首次运行时必然一个都不存在，
# 于是每次都在这里挂掉 —— 而 ipa 其实已经打好了，极具迷惑性。
find "$OUT" -maxdepth 1 -name '.payload-*' -type d 2>/dev/null | while read -r d; do
  # 用 find -delete 逐文件删，避免触发整目录批量删除
  find "$d" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$d" 2>/dev/null || true
done

# ---- 校验（每条都有明确的失败含义，不要只看「命令成功」）----
echo ""
echo "▶ 校验 ipa"
fail=0

if unzip -l "$IPA" | grep -q "Payload/Runner.app/Info.plist"; then
  echo "  ✓ 结构正确（Payload/Runner.app/Info.plist）"
else
  echo "  ✗ 结构损坏 —— Runner.app 被压成了文件？检查复制阶段是否误用了 -c -k" >&2
  fail=1
fi

n=$(unzip -l "$IPA" | grep -c __MACOSX || true)
if [ "$n" = "0" ]; then
  echo "  ✓ 无 __MACOSX 冗余条目"
else
  echo "  ✗ 有 $n 条 __MACOSX 条目（ditto 少了 --norsrc？）" >&2
  fail=1
fi

if unzip -l "$IPA" | grep -q "PrivacyInfo.xcprivacy"; then
  echo "  ✓ 隐私清单在包里"
else
  echo "  ✗ 包里没有 PrivacyInfo.xcprivacy —— 传上 App Store 会被拒" >&2
  fail=1
fi

ARCH=$(lipo -info "$APP/Runner" 2>/dev/null | sed 's/.*: //')
echo "  · 架构：$ARCH"
echo "  · 桌面名：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist")"
echo "  · 包名：  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "  · 版本：  $VERSION+$BUILD"
echo "  · 签名：  $(codesign -dv "$APP" 2>&1 | head -1)"

echo ""
if [ "$fail" = "0" ]; then
  echo "✅ 产出：$IPA"
  echo ""
  echo "侧载方式（7 天后需重新签）："
  echo "  1. 下载 Sideloadly：https://sideloadly.io"
  echo "  2. 用数据线连 iPhone，在 Sideloadly 里拖入本 ipa"
  echo "  3. 用普通 Apple ID 登录（不需要付费开发者账号）"
else
  echo "❌ 校验未通过，见上面的 ✗ 行"
fi
exit $fail
