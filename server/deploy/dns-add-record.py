#!/usr/bin/env python3
"""给 weiyuantool.com 加一条 DNS 记录（DNSPod）。

## 两种凭据都能用，脚本自己认

DNSPod 提供两套鉴权，**它们不能混用**（官方文档《密钥管理》写明）：

| 凭据 | 调用哪个 API | 格式 | 存放文件 |
|---|---|---|---|
| DNSPod Token | DNSPod API 2.0（传统） | `ID,` + 32 位随机串 | ~/.workbuddy/dnspod_token.txt |
| 腾讯云 API 密钥 | DNSPod API 3.0（推荐） | `AKID...` SecretId + SecretKey | ~/.workbuddy/tencent_secret.txt |

**踩过的坑**：第一次拿到的是一串 `1390453926,AKID4Kcq...`，看着像 "ID,Token"
两段式，但第二段以 `AKID` 开头 —— 那是**腾讯云 API 密钥的 SecretId**，不是
DNSPod Token。传统 API 直接回 `10003 传入的 Token 不存在`，而错误信息不会
告诉你「你拿错类型了」。判断依据很简单：DNSPod Token 的第二段是纯随机串，
永远不带 AKID 前缀。

本脚本按文件存在与否自动选路子，也可以用 --mode 强制指定。

## 为什么不直接写一句 curl

Token 是账号级凭据（DNSPod Token 仅主账号可用；腾讯云密钥更是能管整个账号），
写进 shell 历史或粘贴到聊天窗口都会留下副本。所以凭据只从**文件**读。

另外本脚本只做两件事：**列出**已有记录、**新增**一条。
不提供删除/修改 —— 那些操作一旦敲错，影响的是官网与 ERP 的解析，
而它们此刻正在跑。

## 用法

    # A. 用腾讯云 API 密钥（推荐）：文件写两行
    #      C:\\Users\\Administrator\\.workbuddy\\tencent_secret.txt
    #      第 1 行 SecretId（AKID 开头），第 2 行 SecretKey
    # B. 用 DNSPod Token：文件写一行
    #      C:\\Users\\Administrator\\.workbuddy\\dnspod_token.txt
    #      内容 "ID,Token"

    # 先空跑（只查不写）
    python dns-add-record.py --sub api.pet --value 124.223.174.129 --dry-run
    # 确认输出无误后去掉 --dry-run

    # 用完请到控制台把该密钥删除或重置。
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DOMAIN = "weiyuantool.com"
TOKEN_FILE = "~/.workbuddy/dnspod_token.txt"
SECRET_FILE = "~/.workbuddy/tencent_secret.txt"

MODE_AUTO = "auto"
MODE_TOKEN = "token"      # DNSPod Token -> API 2.0 (dnsapi.cn)
MODE_TENCENT = "tencent"  # 腾讯云 API 密钥 -> API 3.0 (dnspod.tencentcloudapi.com)


# --------------------------------------------------------------------------- #
# 凭据读取
# --------------------------------------------------------------------------- #


def _read_clean(path: str) -> list[str]:
    """读文件的非空行，去掉首尾空白与包裹的引号（从网页复制时常带上）。"""
    p = pathlib.Path(path).expanduser()
    if not p.is_file():
        return []
    lines = []
    for raw in p.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        for ch in ('"', "'"):
            if len(s) > 1 and s.startswith(ch) and s.endswith(ch):
                s = s[1:-1].strip()
        lines.append(s)
    return lines


def detect_mode(requested: str) -> str:
    if requested != MODE_AUTO:
        return requested
    if _read_clean(SECRET_FILE):
        return MODE_TENCENT
    if _read_clean(TOKEN_FILE):
        return MODE_TOKEN
    sys.exit(
        "[X] 没找到任何凭据文件。需要其中一个：\n"
        f"    A) 腾讯云 API 密钥 -> {SECRET_FILE}\n"
        "       第 1 行 SecretId（AKID 开头），第 2 行 SecretKey\n"
        f"    B) DNSPod Token    -> {TOKEN_FILE}\n"
        '       一行 "ID,Token"（Token 是 32 位随机串，不带 AKID 前缀）\n'
        "    生成入口都是：DNSPod 账号中心控制台 -> 密钥管理"
    )


# --------------------------------------------------------------------------- #
# 路子 A：DNSPod Token -> 传统 API（form-urlencoded）
# --------------------------------------------------------------------------- #


def legacy_call(action: str, login_token: str, **params) -> dict:
    data = {
        "login_token": login_token,
        "format": "json",
        "lang": "cn",
        "error_on_empty": "no",
    }
    data.update({k: str(v) for k, v in params.items()})
    body = urllib.parse.urlencode(data, encoding="utf-8").encode("utf-8")
    request = urllib.request.Request(
        f"https://dnsapi.cn/{action}",
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return _send(request, f"传统 API {action}")


def legacy_list(token: str, sub: str) -> list[dict]:
    payload = legacy_call("Record.List", token, domain=DOMAIN, sub_domain=sub)
    status = payload.get("status", {})
    code = str(status.get("code"))
    if code == "1":
        records = payload.get("records") or []
        return records if isinstance(records, list) else []
    # code=10 是「该子域名下没有记录」，属于正常空状态，不是错误。
    if code == "10":
        return []
    sys.exit(f"[X] 查询失败：{code} {status.get('message')}")


# --------------------------------------------------------------------------- #
# 路子 B：腾讯云 API 密钥 -> API 3.0（TC3-HMAC-SHA256 签名）
# --------------------------------------------------------------------------- #

TC_HOST = "dnspod.tencentcloudapi.com"
TC_SERVICE = "dnspod"
TC_VERSION = "2021-03-23"


def _hmac_sha256(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def tc_call(action: str, secret_id: str, secret_key: str, payload: dict) -> dict:
    """按腾讯云 API 3.0 规范签名并发送。

    这套签名（TC3-HMAC-SHA256）有四个地方一错就只回一个含糊的
    AuthFailure，无法从报错反推，所以按官方 API Explorer 生成的顺序来：
    canonical request -> string to sign -> 逐级派生签名密钥 -> Authorization。
    """
    timestamp = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(timestamp))
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)

    # 规范请求：注意 canonical_headers 自身以 \n 结尾，拼接时还要再补一个 \n
    # （即头部与 signed_headers 之间有一个空行）。
    canonical_headers = (
        "content-type:application/json; charset=utf-8\n"
        f"host:{TC_HOST}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    hashed_payload = hashlib.sha256(body.encode("utf-8")).hexdigest()
    canonical_request = "\n".join(
        ["POST", "/", "", canonical_headers, signed_headers, hashed_payload]
    )

    credential_scope = f"{date}/{TC_SERVICE}/tc3_request"
    string_to_sign = "\n".join(
        [
            "TC3-HMAC-SHA256",
            str(timestamp),
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    secret_date = _hmac_sha256(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = _hmac_sha256(secret_date, TC_SERVICE)
    secret_signing = _hmac_sha256(secret_service, "tc3_request")
    signature = hmac.new(
        secret_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        f"TC3-HMAC-SHA256 Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    request = urllib.request.Request(
        f"https://{TC_HOST}",
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": authorization,
            "Content-Type": "application/json; charset=utf-8",
            "Host": TC_HOST,
            "X-TC-Action": action,
            "X-TC-Timestamp": str(timestamp),
            "X-TC-Version": TC_VERSION,
        },
    )
    payload_out = _send(request, f"API 3.0 {action}")

    resp = payload_out.get("Response", {})
    error = resp.get("Error")
    if error:
        code = error.get("Code", "")
        message = error.get("Message", "")
        hint = ""
        if code in ("AuthFailure.SecretIdNotFound", "AuthFailure"):
            hint = (
                "\n    提示：SecretId / SecretKey 必须来自**同一组**密钥，"
                "且不能把旧版 DNSPod 的数字 ID 填进 SecretId。"
            )
        elif code == "UnauthorizedOperation":
            hint = "\n    提示：这个密钥没有 DNSPod 的权限，换一个或补 CAM 授权。"
        sys.exit(f"[X] {action} 失败：{code} {message}{hint}")
    return resp


def tc_list(secret_id: str, secret_key: str, sub: str) -> list[dict]:
    resp = tc_call(
        "DescribeRecordList",
        secret_id,
        secret_key,
        {"Domain": DOMAIN, "Subdomain": sub},
    )
    records = resp.get("RecordList") or []
    return records if isinstance(records, list) else []


def _send(request: urllib.request.Request, what: str) -> dict:
    try:
        with urllib.request.urlopen(request, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:400].decode("utf-8", errors="replace")
        sys.exit(f"[X] HTTP {exc.code} 调用{what} 失败：{detail}")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        sys.exit(f"[X] 网络不可达（{what}）：{exc}")


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #


def normalize(records: list[dict]) -> list[dict]:
    """把两套 API 的记录字段统一成 name/type/line/value/ttl/id。"""
    out = []
    for r in records:
        out.append(
            {
                "id": r.get("id") or r.get("RecordId"),
                "name": r.get("name") or r.get("Name"),
                "type": r.get("type") or r.get("Type"),
                "line": r.get("line") or r.get("Line"),
                "value": r.get("value") or r.get("Value"),
                "ttl": r.get("ttl") or r.get("TTL"),
            }
        )
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="给 weiyuantool.com 加一条 DNS 记录")
    parser.add_argument("--sub", required=True, help="主机记录，如 api.pet")
    parser.add_argument("--value", required=True, help="记录值，如 124.223.174.129")
    parser.add_argument("--type", default="A", help="记录类型，默认 A")
    parser.add_argument("--line", default="默认", help="记录线路，默认「默认」")
    parser.add_argument("--ttl", type=int, default=600, help="TTL，默认 600")
    parser.add_argument("--note", default="宠物 App API", help="备注")
    parser.add_argument(
        "--mode", choices=[MODE_AUTO, MODE_TOKEN, MODE_TENCENT], default=MODE_AUTO
    )
    parser.add_argument("--dry-run", action="store_true", help="只查询，不写入")
    args = parser.parse_args()

    mode = detect_mode(args.mode)
    print(f"[i] 域名    : {DOMAIN}")
    print(f"[i] 主机记录: {args.sub}")
    print(f"[i] 类型/值 : {args.type} {args.value}")
    print(f"[i] 鉴权    : {mode}")

    if mode == MODE_TENCENT:
        lines = _read_clean(SECRET_FILE)
        if len(lines) < 2:
            sys.exit(f"[X] {SECRET_FILE} 需要两行：SecretId 与 SecretKey")
        secret_id, secret_key = lines[0], lines[1]
        print(f"[i] SecretId: {secret_id[:8]}…{secret_id[-4:]}（SecretKey 不打印）")
        list_fn = lambda: tc_list(secret_id, secret_key, args.sub)  # noqa: E731
    else:
        lines = _read_clean(TOKEN_FILE)
        if not lines:
            sys.exit(f"[X] {TOKEN_FILE} 为空或不存在")
        login_token = lines[0]
        if "," not in login_token:
            sys.exit(f'[X] {TOKEN_FILE} 内容不是 "ID,Token" 两段式')
        token_part = login_token.split(",", 1)[1]
        if token_part.startswith("AKID"):
            sys.exit(
                "[X] 这个 Token 的第二段以 AKID 开头 —— 那是**腾讯云 API 密钥的\n"
                "    SecretId**，不是 DNSPod Token，传统 API 一定拒（10003）。\n"
                "    两条路任选：\n"
                f"      A) 把 SecretId 与配对的 SecretKey 分两行写进 {SECRET_FILE}\n"
                "      B) 去 DNSPod 账号中心 -> 密钥管理 -> 创建 **Token**\n"
                "         （注意不是「创建密钥」，那给的是腾讯云 API 密钥）\n"
                f'         得到 "ID,Token" 写进 {TOKEN_FILE}'
            )
        print(f"[i] Token ID: {login_token.split(',', 1)[0]}（Token 值不打印）")
        list_fn = lambda: legacy_list(login_token, args.sub)  # noqa: E731

    print()
    print("--- 1) 查现有记录 ---")
    existing = normalize(list_fn())
    if not existing:
        print("    （无记录）")
    else:
        print(f"    已有 {len(existing)} 条：")
        for r in existing:
            print(
                f"      id={str(r['id']):>12}  {str(r['type']):<6} "
                f"{str(r['line']):<6} {str(r['value']):<40} ttl={r['ttl']}"
            )
        wanted = args.value.strip()
        same = [r for r in existing if str(r["value"]).strip() == wanted]
        if same:
            print()
            print(f"[=] 目标记录已存在（id={same[0]['id']}），无需重复添加。")
            return 0
        print()
        print("[!] 该主机记录下已有**其他值**的记录。")
        print("    继续添加会与它形成多值轮询，这是不是你想要的？")
        print("    若不是，请先到控制台确认；本脚本不做修改/删除。")

    print()
    if args.dry_run:
        print("[dry-run] 不会写入。去掉 --dry-run 才真正创建。")
        return 0

    print("--- 2) 创建记录 ---")
    if mode == MODE_TENCENT:
        resp = tc_call(
            "CreateRecord",
            secret_id,
            secret_key,
            {
                "Domain": DOMAIN,
                "SubDomain": args.sub,
                "RecordType": args.type,
                "RecordLine": args.line,
                "Value": args.value,
                "TTL": args.ttl,
                "Remark": args.note,
            },
        )
        record_id = resp.get("RecordId")
    else:
        payload = legacy_call(
            "Record.Create",
            login_token,
            domain=DOMAIN,
            sub_domain=args.sub,
            record_type=args.type,
            record_line=args.line,
            value=args.value,
            ttl=args.ttl,
            remark=args.note,
        )
        status = payload.get("status", {})
        if str(status.get("code")) != "1":
            print(f"[X] 创建失败：{status.get('code')} {status.get('message')}")
            return 1
        record_id = (payload.get("record") or {}).get("id")

    print(f"[+] 已创建，记录 id={record_id}")
    print()
    print("[i] DNSPod 有约 30 秒的索引延迟，稍后才有解析。")
    print("[i] 如不再需要该密钥，请到控制台删除或重置它。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
