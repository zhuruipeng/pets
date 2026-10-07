#!/usr/bin/env python3
"""同一入口构建两个平台；flavor 与地区参数绑定，不修改版本或发布。"""
from __future__ import annotations

import argparse
import json
import platform
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]


def build_arguments(target: str, region: str, output: str) -> list[str]:
    allowed = {"android": {"apk", "aab"}, "ios": {"simulator", "unsigned", "ipa"}}
    if output not in allowed[target]:
        raise ValueError(f"{target} does not support output {output}")
    arguments = ["build"]
    if target == "android":
        arguments += ["appbundle" if output == "aab" else "apk", "--release"]
    elif output == "simulator":
        arguments += ["ios", "--simulator", "--debug"]
    elif output == "unsigned":
        arguments += ["ios", "--release", "--no-codesign"]
    else:
        arguments += ["ipa", "--release"]
    return arguments + ["--flavor", region, f"--dart-define-from-file=dart_define/{region}.json"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--region", required=True, choices=("cn", "intl"))
    parser.add_argument("--format", choices=("apk", "aab", "simulator", "unsigned", "ipa"))
    parser.add_argument("--flutter", help="Flutter executable path; default: PATH")
    parser.add_argument("--dry-run", action="store_true", help="Validate configuration and print command only")
    args = parser.parse_args()
    output = args.format or ("apk" if args.platform == "android" else "simulator")
    try:
        arguments = build_arguments(args.platform, args.region, output)
        region_file = APP / "dart_define" / f"{args.region}.json"
        if json.loads(region_file.read_text(encoding="utf-8"))["REGION"] != args.region:
            raise ValueError(f"REGION mismatch in {region_file}")
        from check_platform_config import validate_configuration
        validate_configuration(APP)
    except (ValueError, KeyError, OSError) as error:
        parser.error(str(error))

    flutter = args.flutter or shutil.which("flutter")
    if not flutter:
        fallback = Path.home() / "development/flutter/bin/flutter"
        flutter = str(fallback) if fallback.is_file() else "flutter"
    command = [flutter, *arguments]
    print(shlex.join(command), flush=True)
    if args.dry_run:
        return 0
    if args.platform == "ios":
        if platform.system() != "Darwin":
            parser.error("iOS builds require macOS and full Xcode; use --dry-run on Windows")
        for tool in ("xcodebuild", "pod"):
            if not shutil.which(tool):
                parser.error(f"Missing {tool}: install Xcode / CocoaPods and add it to PATH")
        subprocess.run(["plutil", "-lint", str(APP / "ios/Runner.xcodeproj/project.pbxproj")], check=True)
        subprocess.run([sys.executable, str(APP / "tool/apply_ios_release.py"), "--check"], check=True)
    if not Path(flutter).is_file() and not shutil.which(flutter):
        parser.error("Flutter not found; add it to PATH or pass --flutter /path/to/flutter")
    result = subprocess.run(command, cwd=APP)
    if result.returncode:
        return result.returncode
    paths = {
        "apk": f"build/app/outputs/flutter-apk/app-{args.region}-release.apk",
        "aab": f"build/app/outputs/bundle/{args.region}Release/",
        "simulator": "build/ios/iphonesimulator/Runner.app",
        "unsigned": "build/ios/iphoneos/Runner.app (unsigned)",
        "ipa": "build/ios/ipa/",
    }
    print(f"Output: {paths[output]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
