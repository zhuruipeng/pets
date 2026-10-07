#!/usr/bin/env python3
"""在 Xcode 的 Flutter 构建阶段拦截 native market / Dart REGION 错配。"""
from __future__ import annotations

import base64
import os
import sys


def check_region(environment: dict[str, str]) -> None:
    market = environment.get("APP_MARKET", "")
    if market not in ("cn", "intl"):
        raise ValueError("APP_MARKET must be cn or intl")
    defines: dict[str, str] = {}
    for encoded in environment.get("DART_DEFINES", "").split(","):
        if not encoded:
            continue
        try:
            value = base64.b64decode(encoded, validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("Invalid base64 DART_DEFINES") from error
        key, separator, value = value.partition("=")
        if separator:
            defines[key] = value
    # 不带 REGION 的旧 Runner 构建采用 Dart 默认的 intl。
    region = defines.get("REGION", "intl")
    if region != market:
        raise ValueError(
            f"iOS market {market} does not match Dart REGION={region}. "
            f"Use --flavor {market} --dart-define-from-file=dart_define/{market}.json"
        )


if __name__ == "__main__":
    try:
        check_region(dict(os.environ))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
