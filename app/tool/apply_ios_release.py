#!/usr/bin/env python3
"""应用 iOS 发布配置（幂等，重复跑会报 already applied）。

**这个脚本存在的原因**：`flutter create` 不产出下面这四样，而重新生成
`ios/` 会静默丢掉它们 —— 损失要到上传 App Store Connect 时才暴露：

  1. 权限声明文案（相机 / 相册 / 照片库写入 / 通知）
     **少了不会编译失败，只在真机上崩**：调用 image_picker 时系统直接杀进程，
     报「此 App 未请求使用相册的权限」。debug 包也崩，只是没人天天测相册。
  2. `PrivacyInfo.xcprivacy` 隐私清单
     用了 flutter_secure_storage / path_provider 就要有。缺了上传会被拒。
  3. `ITSAppUsesNonExemptEncryption = false`
     否则每次上传都停在同一个「是否使用加密」提问上。
  4. ATS 例外：只放行 `NSAllowsLocalNetworking`（回环 + 局域网），
     **不要**用 `NSAllowsArbitraryLoads` —— 那会把互联网明文一起放行。
     注意这**不等于**可以把线上 API 走 http：真 API 必须走 TLS。

用法：
    python3 tool/apply_ios_release.py            # 应用
    python3 tool/apply_ios_release.py --check    # 只校验，不改
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)                    # app/
IOS = os.path.join(APP, "ios")
RUNNER = os.path.join(IOS, "Runner")
INFO_PLIST = os.path.join(RUNNER, "Info.plist")
PBXPROJ = os.path.join(IOS, "Runner.xcodeproj", "project.pbxproj")
PRIVACY = os.path.join(RUNNER, "PrivacyInfo.xcprivacy")

# 海外区（intl）的包名与桌面名字。
#
# ⚠️ 与 Android 的 flavor 保持一一对应：intl 在那边是 com.weiyuantool.pet，
# iOS 这边就不能还是 flutter create 生成的 com.weiyuantool.petApp。
# 两个市场是**两个独立的应用**，能在同一台手机上并存对比。
INTL_BUNDLE_ID = "com.weiyuantool.pet"
# 每个 Runner 配置分别设置 cn / intl 桌面名称，修复脚本不能覆盖成固定名称。
DISPLAY_NAME_SETTING = "$(APP_DISPLAY_NAME)"

# ---- 权限声明文案 ----
#
# iOS 权限弹窗的标题就是这里的中文/英文，**不能留空**，留空系统会直接崩。
# 文案要写清楚「为什么现在要这个权限」—— App Store 审核会看这个。
PERMISSION_KEYS: list[tuple[str, str]] = [
    (
        "NSCameraUsageDescription",
        "给宠物拍头像与记录照片，照片只保存在本机。",
    ),
    (
        "NSPhotoLibraryUsageDescription",
        "从相册选照片作为宠物头像或记录附件，照片只保存在本机。",
    ),
    (
        "NSPhotoLibraryAddUsageDescription",
        "把导出的健康报告长图保存回相册。",
    ),
]

PRIVACY_MANIFEST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>NSPrivacyTracking</key>
\t<false/>
\t<key>NSPrivacyTrackingDomains</key>
\t<array/>
\t<key>NSPrivacyCollectedDataTypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>NSPrivacyCollectedDataType</key>
\t\t\t<string>NSPrivacyCollectedDataTypeUserContent</string>
\t\t\t<key>NSPrivacyCollectedDataTypeLinked</key>
\t\t\t<true/>
\t\t\t<key>NSPrivacyCollectedDataTypeTracking</key>
\t\t\t<false/>
\t\t\t<key>NSPrivacyCollectedDataTypePurposes</key>
\t\t\t<array>
\t\t\t\t<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
\t\t\t</array>
\t\t</dict>
\t</array>
\t<key>NSPrivacyAccessedAPITypes</key>
\t<array>
\t\t<!--
\t\t\tUserDefaults：flutter_secure_storage 的 iOS 端把登录令牌落在 Keychain，
\t\t\t插件内部会读 UserDefaults 里的辅助键（CA92.1 的归类）。
\t\t\t文件时间戳：attachments 表记录本机文件的修改时间（Mach-O 绝对时间）。
\t\t-->
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array>
\t\t\t\t<string>CA92.1</string>
\t\t\t</array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array>
\t\t\t\t<string>C617.1</string>
\t\t\t</array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryDiskSpace</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array>
\t\t\t\t<string>E174.1</string>
\t\t\t</array>
\t\t</dict>
\t</array>
</dict>
</plist>
"""


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


# ---------------------------------------------------------------- Info.plist
#
# 手改 XML 太脆（缩进、标签顺序），用 plistlib 读改写回。
# plistlib 会把整个文件重新格式化，diff 会变大，但语义可靠 —— 对一次性
# 发布配置来说，这个代价比正则匹配出错划算。


def apply_info_plist(check_only: bool) -> list[str]:
    import plistlib

    with open(INFO_PLIST, "rb") as f:
        plist = plistlib.load(f)

    pending: list[str] = []

    # 1. 桌面显示名 + 包名
    if plist.get("CFBundleDisplayName") != DISPLAY_NAME_SETTING:
        plist["CFBundleDisplayName"] = DISPLAY_NAME_SETTING
        pending.append(f"CFBundleDisplayName = {DISPLAY_NAME_SETTING}")

    # 2. 权限声明
    for key, desc in PERMISSION_KEYS:
        if plist.get(key) != desc:
            plist[key] = desc
            pending.append(key)

    # 3. 加密出口合规：只用了 TLS + Keychain，不涉及非豁免加密
    if plist.get("ITSAppUsesNonExemptEncryption") is not False:
        plist["ITSAppUsesNonExemptEncryption"] = False
        pending.append("ITSAppUsesNonExemptEncryption = false")

    # 4. ATS：只放行局域网明文（自建服务端调试用），**不放行互联网明文**
    ats = plist.setdefault("NSAppTransportSecurity", {})
    if not isinstance(ats, dict):
        ats = {}
        plist["NSAppTransportSecurity"] = ats
    if ats.get("NSAllowsArbitraryLoads"):
        del ats["NSAllowsArbitraryLoads"]
        pending.append("删掉 NSAllowsArbitraryLoads（危险：会放行互联网明文）")
    if ats.get("NSAllowsLocalNetworking") is not True:
        ats["NSAllowsLocalNetworking"] = True
        pending.append("NSAllowsLocalNetworking = true")

    # 5. 本地网络弹窗文案（iOS 14+）。与上面的 ATS 是**两件不同的事**：
    #    ATS 管能不能发包，这条管用户看不看得到弹窗，漏了会直接杀进程。
    local_desc = "用于连接你自己的服务器同步宠物数据，可随时在设置中关闭。"
    if plist.get("NSLocalNetworkUsageDescription") != local_desc:
        plist["NSLocalNetworkUsageDescription"] = local_desc
        pending.append("NSLocalNetworkUsageDescription")

    if not pending:
        return []
    if not check_only:
        with open(INFO_PLIST, "wb") as f:
            plistlib.dump(plist, f)
    return pending


# ------------------------------------------------- project.pbxproj（包名 + 资源）
#
# ⚠️ pbxproj 里没有 upsert：`Add` 遇到已存在的键失败、`Set` 遇到缺失的键失败。
# 必须先读再决定，这也是为什么不能用简单的文本替换。


def apply_pbxproj(check_only: bool) -> list[str]:
    src = _read(PBXPROJ)
    pending: list[str] = []

    # Runner target 的包名：把 flutter create 默认的 com.weiyuantool.petApp
    # 换成海外区 id。RunnerTests 的 id 是 Runner 的子串，一并换。
    if f"PRODUCT_BUNDLE_IDENTIFIER = {INTL_BUNDLE_ID};" not in src:
        src = src.replace(
            "PRODUCT_BUNDLE_IDENTIFIER = com.weiyuantool.petApp;",
            f"PRODUCT_BUNDLE_IDENTIFIER = {INTL_BUNDLE_ID};",
        )
        src = src.replace(
            f"PRODUCT_BUNDLE_IDENTIFIER = com.weiyuantool.petApp.RunnerTests;",
            f"PRODUCT_BUNDLE_IDENTIFIER = {INTL_BUNDLE_ID}.RunnerTests;",
        )
        pending.append(f"PRODUCT_BUNDLE_IDENTIFIER = {INTL_BUNDLE_ID}")

    # PrivacyInfo.xcprivacy 必须出现在 Runner target 的 Resources build phase 里。
    # **只把文件拷进 ios/Runner/ 是没用的** —— 失败长得像成功：文件根本不在
    # App 包里，要到上传时 App Store Connect 才发现缺隐私清单。
    if "PrivacyInfo.xcprivacy" not in src:
        src = _add_pbx_file(
            src,
            file_name="PrivacyInfo.xcprivacy",
            file_ref=("97A000012E9A001100AA0001", "PrivacyInfo.xcprivacy"),
            build_file=("97A000022E9A001100AA0001", "PrivacyInfo.xcprivacy in Resources"),
        )
        pending.append("PrivacyInfo.xcprivacy 加入 Resources build phase")

    if not pending:
        return []
    if not check_only:
        # 改完立刻验语法：pbxproj 是 Xcode 的构建输入，写坏了要等到 build 阶段
        # 才报，而那时的报错常常指向完全无关的文件（本次就报成「PrivacyInfo
        # 文件不存在」，实际是 pbxproj 语法已坏）。plutil 是系统自带的，
        # 无依赖，且解析的就是 Xcode 那套格式。
        if not _pbxproj_lint_ok():
            print(
                "✗ 改完的 project.pbxproj 通不过 plutil 语法检查，**未写入**。\n"
                "  多半是 pbxproj 被手工改过、格式与本脚本的假设不符。\n"
                "  请先 git checkout ios/Runner.xcodeproj/project.pbxproj 再重跑。",
                file=sys.stderr,
            )
            raise SystemExit(1)
        _write(PBXPROJ, src)
    return pending


def _pbxproj_lint_ok() -> bool:
    """用 plutil 验 pbxproj 语法。系统自带，无需额外依赖。"""
    import subprocess

    proc = subprocess.run(
        ["plutil", "-lint", PBXPROJ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(proc.stdout + proc.stderr, file=sys.stderr)
        return False
    return True


def _add_pbx_file(
    src: str,
    *,
    file_name: str,
    file_ref: tuple[str, str],
    build_file: tuple[str, str],
) -> str:
    """往 pbxproj 里补一个资源文件（引用 + Resources 阶段条目）。"""
    ref_id, ref_name = file_ref
    bf_id, bf_desc = build_file

    # PBXBuildFile section
    src = src.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{bf_id} /* {bf_desc} */ = {{isa = PBXBuildFile; fileRef = {ref_id} "
        f"/* {ref_name} */; }};\n/* End PBXBuildFile section */",
        1,
    )
    # PBXFileReference section
    src = src.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {ref_name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.xml; path = {ref_name}; sourceTree = \"<group>\"; }};\n"
        "/* End PBXFileReference section */",
        1,
    )
    # Runner group（把引用挂进去，文件才会出现在项目树里）
    #
    # ⚠️ group id 必须是 **97C146F0**（不是 97C146EE —— 那是 RunnerTests 的
    # build configuration 段落的 id，只是长得像）。挂错 group 的话
    # `path = PrivacyInfo.xcprivacy` 会相对于错误的父目录解析，
    # 症状是编译期报「文件不存在」—— 而文件明明躺在 ios/Runner/ 下。
    # 这个错误只在真正构建时才暴露，pbxproj 语法检查是过的。
    #
    # 只能往**已存在的 children 里加一行**：不能连 isa/children 一起重写，
    # 那样会多出一份 isa = PBXGroup 与 children = (，pbxproj 直接语法错误。
    old_children = (
        "\t\t97C146F01CF9000F007C117D /* Runner */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
    )
    if old_children not in src:
        print(
            "警告：没找到 Runner group（97C146F0）的 children 块，\n"
            "      PrivacyInfo 引用未挂进项目树。若 project.pbxproj 被手工改过，\n"
            "      请把 PrivacyInfo.xcprivacy 手动加进 Runner 组。",
            file=sys.stderr,
        )
    else:
        src = src.replace(
            old_children,
            old_children + f"\t\t\t\t{ref_id} /* {ref_name} */,\n",
            1,
        )
    # Resources build phase
    src = src.replace(
        "\t\t\t\t97C146FE1CF9000F007C117D /* Assets.xcassets in Resources */,",
        "\t\t\t\t97C146FE1CF9000F007C117D /* Assets.xcassets in Resources */,\n"
        f"\t\t\t\t{bf_id} /* {bf_desc} */,",
        1,
    )
    return src


# ---------------------------------------------------------------- 隐私清单

def apply_privacy_manifest(check_only: bool) -> list[str]:
    if os.path.exists(PRIVACY) and _read(PRIVACY) == PRIVACY_MANIFEST:
        return []
    if not check_only:
        _write(PRIVACY, PRIVACY_MANIFEST)
    return ["写入 PrivacyInfo.xcprivacy"]


# ---------------------------------------------------------------- 入口

def main() -> int:
    check_only = "--check" in sys.argv

    if not os.path.isdir(IOS):
        print(f"找不到 iOS 工程：{IOS}", file=sys.stderr)
        return 1

    steps = {
        "Info.plist（显示名 / 权限 / 加密出口 / ATS）": apply_info_plist,
        "project.pbxproj（包名 / 隐私清单入包）": apply_pbxproj,
        "PrivacyInfo.xcprivacy": apply_privacy_manifest,
    }

    any_change = False
    for label, fn in steps.items():
        pending = fn(check_only)
        if pending:
            any_change = True
            prefix = "需要应用" if check_only else "已应用"
            print(f"{label}：")
            for item in pending:
                print(f"  - {item}")
        else:
            print(f"{label}：already applied")

    if check_only:
        # ⚠️ 这句话必须跟着 any_change 走。原先是无条件打印，于是配置全部
        # applied 时也照样显示「有未应用的配置」—— 而返回码是 0（正常）。
        # 人看输出判断、脚本看返回码，两者矛盾，出包脚本里的人肉确认环节
        # 就会被误导成「配置没生效」。
        if any_change:
            print("\n有未应用的配置，请先运行：python3 tool/apply_ios_release.py")
            return 1
        print("\n配置已全部生效。")
        return 0

    print("\n完成。图标由 tool/make_icons.py 生成（改图标后重跑它）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
