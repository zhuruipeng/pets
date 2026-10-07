#!/usr/bin/env python3
"""跨平台静态校验 Xcode / Pods / Dart 地区配置；不代替 Mac 实际构建。"""
from __future__ import annotations

import base64
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_project(source: str) -> dict:
    """解析 Xcode OpenStep plist，保留所有 target / configuration 关联。"""
    tokens = []
    pattern = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+')
    position = 0
    for match in pattern.finditer(source):
        if match.start() != position:
            raise ValueError(f"Invalid project token at {position}")
        position = match.end()
        token = match.group()
        if not token.isspace() and not token.startswith(("//", "/*")):
            tokens.append(token)
    index = 0

    def take(expected=None):
        nonlocal index
        if index >= len(tokens):
            raise ValueError("Unexpected end of project")
        token = tokens[index]
        index += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected}, got {token}")
        return token

    def value():
        token = take()
        if token == "{":
            result = {}
            while index < len(tokens) and tokens[index] != "}":
                key = take().strip('"')
                take("=")
                if key in result:
                    raise ValueError(f"Duplicate project key {key}")
                result[key] = value()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while index < len(tokens) and tokens[index] != ")":
                result.append(value())
                if tokens[index] != ")":
                    take(",")
            take(")")
            return result
        return json.loads(token) if token.startswith('"') else token

    result = value()
    if index != len(tokens) or not isinstance(result, dict):
        raise ValueError("Invalid project root")
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_configuration(app: Path) -> None:
    ios = app / "ios"
    source = (ios / "Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    manifest = (app / "pubspec.yaml").read_text(encoding="utf-8")
    require(re.search(r"(?m)^    enable-swift-package-manager: false\s*$", manifest),
            "Keep Swift Package Manager disabled in project config for CocoaPods builds")
    require("XCLocalSwiftPackageReference" not in source, "Unexpected Swift Package Manager integration")
    project = parse_project(source)
    objects = project["objects"]
    for ident, item in objects.items():
        for key in ("baseConfigurationReference", "buildConfigurationList", "fileRef"):
            if key in item:
                require(item[key] in objects, f"Unresolved {key} reference in {ident}")
        for key in ("children", "buildConfigurations", "buildPhases", "files"):
            for reference in item.get(key, []):
                require(reference in objects, f"Unresolved {key} reference in {ident}")
    require(project["rootObject"] in objects, "Missing root project")
    root = objects[project["rootObject"]]
    targets = {objects[ident]["name"]: objects[ident] for ident in root["targets"]}
    owners = {"Project": root, "Runner": targets["Runner"], "RunnerTests": targets["RunnerTests"]}
    config_maps = {}
    for owner, target in owners.items():
        config_list = objects[target["buildConfigurationList"]]["buildConfigurations"]
        config_maps[owner] = {objects[ident]["name"]: objects[ident] for ident in config_list}
        require(len(config_maps[owner]) == len(config_list), f"Duplicate {owner} configurations")
    podfile = (ios / "Podfile").read_text(encoding="utf-8")
    for region in ("cn", "intl"):
        require(json.loads((app / "dart_define" / f"{region}.json").read_text())["REGION"] == region,
                f"Dart define mismatch: {region}")
        scheme = ET.parse(ios / f"Runner.xcodeproj/xcshareddata/xcschemes/{region}.xcscheme").getroot()
        for action, mode in (("LaunchAction", "Debug"), ("TestAction", "Debug"),
                             ("AnalyzeAction", "Debug"), ("ProfileAction", "Profile"), ("ArchiveAction", "Release")):
            require(scheme.find(action).get("buildConfiguration") == f"{mode}-{region}",
                    f"Wrong {region} {action} configuration")
        for mode in ("Debug", "Release", "Profile"):
            name = f"{mode}-{region}"
            for owner, configurations in config_maps.items():
                require(name in configurations, f"Missing {owner} {name}")
            runner = config_maps["Runner"][name]
            bundle = "com.weiyuantool.pet.cn" if region == "cn" else "com.weiyuantool.pet"
            require(runner["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] == bundle, f"Wrong bundle for {name}")
            require(runner["buildSettings"]["APP_DISPLAY_NAME"] == ("我的宠物" if region == "cn" else "My Pet"),
                    f"Wrong display name for {name}")
            file_ref = objects[runner["baseConfigurationReference"]]
            require(file_ref["path"] == f"{name}.xcconfig", f"Wrong base configuration for {name}")
            groups = [item for item in objects.values() if item.get("isa") == "PBXGroup"]
            require(any(item.get("name") == "Flutter" and runner["baseConfigurationReference"] in item.get("children", [])
                        for item in groups), f"Configuration outside Flutter group: {name}")
            settings = (ios / "Flutter" / file_ref["path"]).read_text(encoding="utf-8")
            encoded = base64.b64encode(f"REGION={region}".encode()).decode()
            require(f"APP_MARKET = {region}" in settings and f"DART_DEFINES = $(inherited),{encoded}" in settings,
                    f"Missing market / Dart region in {name}")
            require(f"Pods-Runner.{name.lower()}.xcconfig" in settings and '#include "Generated.xcconfig"' in settings,
                    f"Missing Pods / Flutter settings for {name}")
            expected = "debug" if mode == "Debug" else "release"
            require(re.search(rf"'{name}'\s*=>\s*:{expected}\b", podfile), f"Wrong Podfile mapping for {name}")
            test_config = config_maps["RunnerTests"][name]
            require(objects[test_config["baseConfigurationReference"]]["path"].endswith(f"Pods-RunnerTests.{name.lower()}.xcconfig"),
                    f"Wrong test Pods configuration for {name}")
    with (ios / "Runner/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    require(info["CFBundleDisplayName"] == "$(APP_DISPLAY_NAME)", "Display name must use build setting")
    require(info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)", "Bundle ID must use build setting")
    require('check_ios_region.py' in source, "Missing iOS region guard build phase")
    # 各市场共用原来的图标与隐私清单；资源必须实际挂在 Runner 上。
    phases = [objects[ident] for ident in targets["Runner"]["buildPhases"]]
    resources = next(phase for phase in phases if phase["isa"] == "PBXResourcesBuildPhase")
    paths = [objects[objects[ident]["fileRef"]].get("path") for ident in resources["files"]]
    require("PrivacyInfo.xcprivacy" in paths and "Assets.xcassets" in paths, "Missing privacy / icon resource")


if __name__ == "__main__":
    validate_configuration(Path(__file__).resolve().parents[1])
    print("Platform configuration OK (static validation; run Xcode builds on Mac).")
