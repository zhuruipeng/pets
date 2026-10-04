#!/usr/bin/env python3
"""把 iOS 工程从 Swift Package Manager 切成纯 CocoaPods（幂等）。

## 为什么需要这个

`flutter config --enable-swift-package-manager`（默认开）会让 Flutter 往
`project.pbxproj` 里注入一个 `XCLocalSwiftPackageReference`，指向
`Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage`。
**这个工程把那套接线提交进了版本库**（`git show HEAD:.../project.pbxproj`
里能查到 XCLocalSwiftPackageReference），所以每次 `flutter build ios` 都会
去解析 SPM 依赖。

而解析动作要调 `sandbox-exec`。在 sandbox-exec 被禁用的机器上（部分 macOS
26 环境 / 容器 / 受限终端），这一步必然失败：

    xcodebuild: error: Could not resolve package dependencies:
      sandbox-exec: sandbox_apply: Operation not permitted

**这不是工程的问题，是本机环境的问题** —— 提权（sudo / 免沙箱）也照样
失败，因为 `sandbox-exec` 这个二进制在当前系统上已经被禁用了。

## 做法

SPM 与 CocoaPods 在 Flutter 里是**混合模式**：SPM 管支持 SPM 的插件，
CocoaPods 管不支持的。关掉 SPM 后所有插件都走 CocoaPods，
`ios/Podfile` 已经是完整的（flutter_install_all_ios_pods），功能不受影响。

要改的地方只有 pbxproj 里的 4 处接线，删干净即可：

  1. PBXBuildFile 里的 `... in Frameworks` 条目
  2. PBXFileReference 里的 package wrapper 引用
  3. Frameworks build phase 里的 files 列表项
  4. Runner group 里的 children 列表项
  5. packageProductDependencies + XCLocalSwiftPackageReference + XCSwiftPackageProductDependency 三段

改完还要 `pod install` 补上 Pods 接线（`flutter build ios` 会自动做）。

用法：
    python3 tool/spm_to_cocoapods.py            # 切换
    python3 tool/spm_to_cocoapods.py --check    # 只看状态
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)                              # app/
PBXPROJ = os.path.join(APP, "ios", "Runner.xcodeproj", "project.pbxproj")

MARKER = "FlutterGeneratedPluginSwiftPackage"
LOCAL_PKG_ID = "781AD8BC2B33823900A9FFBB"      # XCLocalSwiftPackageReference
PRODUCT_DEP_ID = "78A3181F2AECB46A00862997"     # XCSwiftPackageProductDependency
BUILD_FILE_ID = "78A318202AECB46A00862997"      # PBXBuildFile
FILE_REF_ID = "78E0A7A72DC9AD7400C4905E"        # PBXFileReference


def drop_line_containing(src: str, needle: str) -> tuple[str, bool]:
    """删掉所有含 [needle] 的整行。"""
    out, changed = [], False
    for line in src.splitlines(keepends=True):
        if needle in line:
            changed = True
            continue
        out.append(line)
    return "".join(out), changed


def drop_section(src: str, begin: str, end: str) -> tuple[str, bool]:
    """删掉 [begin] … [end] 整段（含标记行）。"""
    pattern = re.compile(
        re.escape(begin) + r".*?" + re.escape(end) + r"[^\n]*\n",
        re.DOTALL,
    )
    new, n = pattern.subn("", src, count=1)
    return new, n > 0


def main() -> int:
    check_only = "--check" in sys.argv

    if not os.path.exists(PBXPROJ):
        print(f"找不到 pbxproj：{PBXPROJ}", file=sys.stderr)
        return 1

    with open(PBXPROJ, "r", encoding="utf-8") as f:
        src = f.read()

    has_spm = MARKER in src
    if not has_spm:
        print("工程已经是纯 CocoaPods 模式（没有 Swift Package Manager 接线），无需改动。")
        print("确认一下：flutter config --no-enable-swift-package-manager")
        return 0

    if check_only:
        print("检测到工程仍接在 Swift Package Manager 上。")
        print("在这类 sandbox-exec 被禁用的机器上，flutter build ios 会必然失败：")
        print("    xcodebuild: error: Could not resolve package dependencies:")
        print("      sandbox-exec: sandbox_apply: Operation not permitted")
        print("")
        print("请先运行：python3 tool/spm_to_cocoapods.py")
        return 1

    # 1~4. 逐行删除含标识的条目
    changed_any = False
    for needle in (
        f"{BUILD_FILE_ID} /* {MARKER} in Frameworks */ = {{isa = PBXBuildFile",
        f"{FILE_REF_ID} /* {MARKER} */ = {{isa = PBXFileReference",
        f"{BUILD_FILE_ID} /* {MARKER} in Frameworks */,",
        f"{FILE_REF_ID} /* {MARKER} */,",
        f"{LOCAL_PKG_ID} /* XCLocalSwiftPackageReference",
        f"\t\t\t\t{PRODUCT_DEP_ID} /* {MARKER} */,",
    ):
        src, changed = drop_line_containing(src, needle)
        changed_any = changed_any or changed

    # 5. 整段删除三个 SPM section
    for begin, end in (
        ("/* Begin XCLocalSwiftPackageReference section */",
         "/* End XCLocalSwiftPackageReference section */"),
        ("/* Begin XCSwiftPackageProductDependency section */",
         "/* End XCSwiftPackageProductDependency section */"),
    ):
        src, changed = drop_section(src, begin, end)
        changed_any = changed_any or changed

    # packageProductDependencies 数组体可能已空，删掉整个键更干净
    src, _ = re.subn(
        r"\n\t\t\t\tpackageProductDependencies = \(\n(?:\t{5}[^\n]*\n)*\t{4}\);",
        "",
        src,
    )

    if MARKER in src or "XCLocalSwiftPackageReference" in src:
        print("✗ 还有残留，改动没生效，请检查 pbxproj 格式是否被手工改过", file=sys.stderr)
        return 1

    with open(PBXPROJ, "w", encoding="utf-8") as f:
        f.write(src)

    print("已切到纯 CocoaPods 模式。" if changed_any else "本来就没有 SPM 接线。")
    print("")
    print("后续：flutter build ios 会自动跑 pod install 补上 Pods 接线。")
    print("⚠️ 这三个文件属于本地接线，**不要提交**（随 pod install 重写）：")
    print("     ios/Runner.xcodeproj/project.pbxproj")
    print("     ios/Runner.xcworkspace/contents.xcworkspacedata")
    print("     ios/Podfile.lock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
