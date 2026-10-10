"""同步与账号的**纯逻辑层**。

为什么要单独一层：LWW 比较、可见性过滤、验证码有效性、角色权限这几件事
是协议里最容易写错、且出错了最难在集成环境里复现的部分（要造两台设备、
造时钟偏移、造并发写）。把它们抽成不碰数据库、不碰 FastAPI 的纯函数，
就能用最朴素的单元测试把每条规则钉死；路由层只负责「取数据 → 调这些函数
→ 写数据」，没有条件分支可言。

本模块**只依赖标准库**，导入它不需要 SQLAlchemy / FastAPI，
因此测试可以在没有数据库、没有网络的环境下跑。
"""

from __future__ import annotations

import hashlib
import re
import secrets
import time
from collections.abc import Iterable, Mapping

# 验证码连续输错多少次作废。5 次是「手滑够用、暴力破解不够用」的分界：
# 6 位码 100 万种，允许 5 次尝试时猜中概率约 5e-6。
CODE_MAX_TRIES = 5

# E.164 里不该出现的分隔符。用户从通讯录粘过来的号码常带空格/横杠/括号。
_PHONE_SEPARATORS = re.compile(r"[\s\-()]")

# 角色 → 允许的动作。权限矩阵只有这一份，接口层不许再写一遍 if role == ...，
# 否则改矩阵时一定漏掉某条分支（漏掉的那条就是越权漏洞）。
_ROLE_ACTIONS: dict[str, frozenset[str]] = {
    "owner": frozenset({"read", "write_data", "edit_profile", "invite", "delete_pet"}),
    "editor": frozenset({"read", "write_data", "edit_profile"}),
    "viewer": frozenset({"read"}),
}


def now_ms() -> int:
    """当前毫秒时间戳。全项目时间口径统一用这个，避免秒/毫秒混用。"""
    return int(time.time() * 1000)


def is_newer(incoming_updated_at: int, current_updated_at: int | None) -> bool:
    """LWW 判定：来件是否应该覆盖现值。

    用**严格大于**：平局时判旧件出局，也就是「平局服务端胜」。
    反过来（>=）会让客户端时钟相同的一次编辑反复互相覆盖，形成来回写。

    current 为 None 表示服务端还没有这行（首次同步），任何来件都是新的。
    """
    if current_updated_at is None:
        return True
    return incoming_updated_at > current_updated_at


def visible_to(
    changes: Iterable[Mapping],
    member_pet_ids: set[str],
    user_id: str,
) -> list[Mapping]:
    """从变更日志里筛出这个人有权看到的条目。

    为什么放在服务端做：客户端不可信 —— 只要客户端能改请求参数，
    「只看我的宠物」就是一句可以被绕过的承诺。分发键是 pet_id，
    所以判定条件就是「pet_id 在我参与的宠物集合里」，外加
    「这行 users 记录就是我自己」（users 行没有 pet_id）。

    member_pet_ids 只应包含 **active** 成员关系：pending 的邀请
    不算授权，否则「邀请」等于直接开读权限。
    """
    visible: list[Mapping] = []
    for change in changes:
        pet_id = change.get("pet_id")
        if pet_id is not None and pet_id in member_pet_ids:
            visible.append(change)
        elif pet_id is None and change.get("user_id") == user_id:
            visible.append(change)
        elif (change.get("table") == "members" and change.get("op") == "delete"
              and (change.get("payload") or {}).get("user_id") == user_id):
            # Removing access must itself reach the removed device. This grants
            # no access to other members or to the pet's business data.
            visible.append(change)
    return visible


def normalize_target(channel: str, target: str) -> str:
    """把登录/邀请的收件方归一化，保证同一实物只会有一条用户记录。

    手机号统一成 E.164（中国号默认补 +86）：用户在不同设备上可能一个填
    13800138000、一个填 +8613800138000，不归一化就会注册出两个账号，
    而这两个账号各自的宠物永远同步不到一起。

    邮箱统一小写：邮箱域名大小写不敏感，且大多数服务商把本地部分也当
    大小写不敏感，混存会让他们登录时「号码明明对却查不到人」。
    """
    raw = (target or "").strip()
    if channel == "email":
        return raw.lower()

    # 带国家码的号码原样保留：这里没有区号表，猜错区号比不猜更危险。
    compact = _PHONE_SEPARATORS.sub("", raw)
    if compact.startswith("+"):
        return compact
    if compact.isdigit():
        return "+86" + compact
    # 既不是 + 开头也不是纯数字（例如含字母），不做猜测，原样返回交给上层拒绝。
    return raw


def generate_code() -> str:
    """生成 6 位数字验证码。

    用 secrets 而不是 random：random 是可预测的 Mersenne Twister，
    攻击者拿到几个码就能推出后续的码，验证码的整个安全模型就没了。
    用 randbelow 而不是 randint(0, 999999) 后补零，是为了让 000000~999999
    每个值的概率完全相等（randint 上界处理容易引入偏差）。
    """
    return f"{secrets.randbelow(1_000_000):06d}"


def is_code_valid(row_dict: Mapping, now_ms: int, code: str) -> tuple[bool, str]:
    """判断一条验证码记录能否用于本次校验，并给出失败原因。

    返回 (是否有效, 原因)，原因取值：consumed / expired / too_many_tries /
    mismatch / ok。把原因返回给调用方而不是只返回 False，是为了让接口层
    能决定「哪些失败要累加 tries、哪些要直接拒」——
    已消费的码再输错不该继续累加计数。
    """
    if row_dict.get("consumed_at") is not None:
        return False, "consumed"

    expires_at = row_dict.get("expires_at")
    # 恰好等于 expires_at 仍算有效：边界归用户，不要让「正好卡点」变成失败。
    if expires_at is not None and now_ms > expires_at:
        return False, "expired"

    if int(row_dict.get("tries") or 0) >= CODE_MAX_TRIES:
        return False, "too_many_tries"

    if not code or row_dict.get("code") != code:
        return False, "mismatch"

    return True, "ok"


def role_can(role: str, action: str) -> bool:
    """角色权限矩阵。

    action 取值：read / write_data / edit_profile / invite / delete_pet。
    未知角色或未知动作一律拒绝（默认拒绝，而不是默认放行）：
    以后新增角色时忘了登记，得到的是「用不了」而不是「全放行」。
    """
    return action in _ROLE_ACTIONS.get(role, frozenset())


def hash_token(raw: str) -> str:
    """令牌入库前的哈希。

    不加盐、不做慢哈希（bcrypt 之类）是刻意的：令牌本身是 256 位随机串，
    不存在「猜得出、要抗字典」的问题，慢哈希只会让每个请求都多耗 CPU。
    盐会破坏「按 token 主键等值查询」的能力 —— 这里要的就是能直接查。
    """
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def new_token() -> str:
    """签发一个新的不透明登录令牌（明文只回客户端一次）。"""
    return secrets.token_urlsafe(32)
