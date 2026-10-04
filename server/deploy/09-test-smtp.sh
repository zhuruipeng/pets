#!/usr/bin/env bash
#
# 邮件通道自检 —— **在 Mac 上跑，不在服务器上**。
#
# ## 为什么单独写一个脚本，而不是直接上服务器试
#
# 因为 SMTP 失败有五六种原因（授权码错、域名没开通、端口/TLS 不匹配、
# 发件人未验证、授权码填成了登录密码），而它们在服务器上的表现**几乎一样**：
# 只看得到「发不出去」。在本地试一次能把「授权码/账号问题」与
# 「服务器配置问题」彻底分开 —— 少一个变量，排查快得多。
#
# ## 为什么密码不回显、不进历史
#
# 授权码等同于发信权限。写到命令行会同时进 `~/.bash_history`、
# 进 `ps` 的进程列表（同一台机器上任何用户可见）、
# 还会留在 CI 日志里。用 `read -s` 从终端静默读入，三个地方都不落。
set -euo pipefail

# ⚠️ 变量名必须与下面 export 的名字一致。
# 踩过的坑：这行原本写成 `HOST=...`，而 export 的是 SMTP_HOST ——
# 于是 Python 里 `os.environ["SMTP_HOST"]` 直接 KeyError，
# 而报错发生在连 SMTP **之前**，看起来像环境问题，其实是这行拼错了。
HOST="${SMTP_HOST:-smtp.exmail.qq.com}"
PORT="${SMTP_PORT:-465}"
USER="${SMTP_USER:-}"
FROM="${SMTP_FROM_EMAIL:-$USER}"
TO="${1:-}"

if [ -z "$USER" ] || [ -z "$TO" ]; then
    echo "用法："
    echo "  SMTP_USER=你的邮箱@weiyuantool.com bash deploy/09-test-smtp.sh 收件箱@x.com"
    echo
    echo "环境变量（都有默认值，可省略）："
    echo "  SMTP_HOST     默认 smtp.exmail.qq.com"
    echo "  SMTP_PORT     默认 465"
    echo "  SMTP_USER     必填：发信用的邮箱地址"
    echo "  SMTP_FROM_EMAIL 可选：默认与 SMTP_USER 相同"
    exit 1
fi

echo "发信账号  $USER"
echo "发件显示  $FROM"
echo "收件账号  $TO"
echo "SMTP      $HOST:$PORT (SSL)"
echo

read -r -s -p "请输入 16 位客户端授权码（不会回显、不进历史）： " SMTP_PASSWORD
echo
echo

export SMTP_PASSWORD SMTP_HOST SMTP_PORT SMTP_USER SMTP_FROM_EMAIL SMTP_TO="$TO"

/Users/ruipeng/.workbuddy/binaries/python/envs/default/bin/python - <<'PY'
import os
import smtplib
import ssl
import sys
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr

# ⚠️ 用 os.environ.get + 显式默认值，**不要** os.environ[...]。
#
# os.environ["X"] 在 X 不存在时抛 KeyError，而那个 traceback 出现在
# 「还没开始连 SMTP」的时候 —— 看起来像是网络或授权码问题，
# 实际上只是某个变量没传进来。这种错位会浪费很多排查时间。
#
# 这里的默认值与 shell 脚本里的默认值保持一致，两处任一漏了都能跑。
def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()

host = env("SMTP_HOST", "smtp.exmail.qq.com")
user = env("SMTP_USER")
password = env("SMTP_PASSWORD")
from_addr = env("SMTP_FROM_EMAIL") or user
to_addr = env("SMTP_TO")

try:
    port = int(env("SMTP_PORT", "465"))
except ValueError:
    sys.exit(f"SMTP_PORT 不是数字：{env('SMTP_PORT')!r}")

if not user or not to_addr:
    sys.exit("SMTP_USER 或 SMTP_TO 为空 —— 检查命令行参数。")
if not password:
    sys.exit("授权码为空 —— 什么都没输入。")

msg = MIMEText(
    "这是一封测试邮件。\n\n"
    "如果你收到了它，说明 SMTP 通道配置正确，"
    "宠物 App 的登录验证码能发出去。\n\n"
    "这个测试不涉及任何真实用户数据。",
    "plain",
    "utf-8",
)
msg["Subject"] = Header("测试：My Pet 验证码通道", "utf-8")
msg["From"] = formataddr((str(Header("My Pet", "utf-8")), from_addr))
msg["To"] = to_addr

print("→ 正在连接 ...")
try:
    ctx = smtplib.SMTP_SSL(host, port, timeout=25, context=ssl.create_default_context())
except Exception as e:
    print(f"✗ 连不上 {host}:{port}\n  {type(e).__name__}: {e}")
    print("\n排查：")
    print("  · 机器需要能出网到 465 端口")
    print("  · 端口是否为 465（隐式 TLS）；若服务商给的是 587，改 SMTP_PORT=587")
    print("    并注意 587 用 STARTTLS，与 SMTP_SSL 不是同一套")
    sys.exit(1)

with ctx:
    print(f"✓ 已连上 {host}:{port}")
    try:
        ctx.login(user, password)
    except smtplib.SMTPAuthenticationError:
        print("✗ 认证失败（535）\n")
        print("  最可能的原因：填的是**登录密码**，而不是 16 位客户端授权码。")
        print("  拿授权码：浏览器登录 exmail.qq.com → 设置 → 邮箱绑定")
        print("              → 客户端专用密码 → 生成新密码")
        print("  另外确认已在「设置 → 收发信设置」里勾了「开启 IMAP/SMTP 服务」。")
        sys.exit(1)
    except smtplib.SMTPServerDisconnected:
        print("✗ 服务端主动断开\n")
        print("  可能是管理员的「客户端访问权限」没给你的账号放行。")
        sys.exit(1)

    print("✓ 认证成功")
    try:
        refused = ctx.send_message(msg)
    except smtplib.SMTPRecipientsRefused as e:
        print(f"✗ 收件人被拒：{e}")
        print("  收件地址格式不对，或被企业邮箱的策略拦了。")
        sys.exit(1)
    except smtplib.SMTPSenderRefused as e:
        print(f"✗ 发件人被拒：{e}")
        print(f"  `{from_addr}` 不是企业邮箱里已验证的发件人。")
        print("  表现：服务器说发成功，但邮件进垃圾箱甚至被丢弃。")
        print("  解决：在管理后台「邮箱管理」里建好这个公共邮箱并验证。")
        sys.exit(1)
    except smtplib.SMTPException as e:
        print(f"✗ 发送失败：{e}")
        sys.exit(1)

if refused:
    print(f"✗ 被拒的收件人：{refused}")
    sys.exit(1)

print("✓ 已提交发送")
print()
print("接下来：")
print("  1. 看收件箱（**也看垃圾箱** —— SPF 在位，通常不会进，但 From 未验证会）")
print("  2. 确认收到后，把授权码填进服务器 /opt/pet-api-intl/.env 的 SMTP_PASSWORD")
print("     ⚠️ 别提交进仓库")
print("  3. 这个授权码已经出现在本次对话里，**测完请在后台重新生成一个**")
PY
