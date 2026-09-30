> ⚠️ **本机有两个独立的阻塞，别只修一个：**
> 1. 命名管道 / 权限等级问题（本文上半部分）→ 用管理员终端即可绕行
> 2. **pub 缓存缺 81 个包**（本文最后一部分）→ 要重跑 `flutter pub get`

# 环境阻塞一：命名管道 / 权限等级

> 记于 2026-09-29。**结论先行：这台机器上 flutter / dart 的编译流程跑不了，
> 根因在 Windows 命名管道（kernel 层），不在本项目代码。**
>
> **✅ 绕行办法：用「管理员」身份的终端跑 flutter 就能正常构建。**
> 拦截只作用于**非提权进程**；提权进程放行。

## ⭐ 决定性对照实验（先看这个）

同一份探针脚本 `tool/probe_exact2.py`、同一个 `python.exe`、同一时刻，
只换运行身份：

| 运行身份 | `OUTBOUND + GENERIC_READ` |
|---|---|
| **管理员 PowerShell** | **OK** |
| 非提权进程（WorkBuddy 工具链） | **err=231** |

**结论：这是「按进程权限等级拒绝」的 HIPS 规则**，不是某个驱动单方面坏掉。
非提权进程读 `PIPE_ACCESS_OUTBOUND` 管道被拦，提权进程不受影响。

⚠️ **不要把这个 OK 误当成「驱动卸载成功」**：当时 `fltmc unload PDDHIPS`
明确报了 `0x801f0010`（ERROR_FLT_DO_NOT_DETACH，「此时不要从卷分离筛选器」）——
**卸载是失败的**。时间线上「卸载报错 → 测试 OK → 非提权进程测试仍 231」，
说明放行来自权限，不是来自驱动消失。**别被这一步误导。**

## 症状

任何 flutter 命令都直接崩，报同一个错：

```
CreateFile failed 231 (所有的管道范例都在使用中。)
ProcessException ... (at ../../runtime/bin/process_win.cc:742)
```

`flutter --version` / `flutter analyze` / `flutter test` / `flutter build apk` 全部如此。
因此 **APK 暂时无法在本机构建**。

## 根因（已定位到 API 调用级）

Dart VM 在 Windows 上启动子进程时，用 4 条命名管道承载 stdin / stdout / stderr /
退出码，名字格式为 `\\.\Pipe\dart_<uuid>_<n>`（见
`third_party/dart/runtime/bin/process_win.cc` 的 `GenerateNames` / `CreatePipes` /
`CreateProcessPipe`）。

关键点：**stdin 那条管道是唯一用 `PIPE_ACCESS_OUTBOUND` 建的**，客户端以
`GENERIC_READ` 连接。而在这台机器上：

- 服务端 `PIPE_ACCESS_OUTBOUND` + 客户端 `GENERIC_READ` → **ERROR_PIPE_BUSY(231)**
- 服务端 `PIPE_ACCESS_INBOUND` + 客户端 `GENERIC_WRITE` → 正常
- 服务端 `PIPE_ACCESS_DUPLEX` + 客户端 `GENERIC_READ|GENERIC_WRITE` → 正常

`CreatePipes` 里 stdin 是第一顺位，所以它一挂，后面三条根本没建，
Dart VM 直接抛 `ProcessException`，flutter 全流程瘫痪。

**该故障与 Dart 版本无关**：本机 `E:\dev\flutter`（Dart 3.13.3）与 `E:\flutter`
（Dart 3.12.2）行为完全一致。

## 已排除的可能

| 假设 | 验证方式 | 结果 |
|---|---|---|
| 句柄/管道对象泄漏 | 枚举 `\\.\pipe\`（369 个，正常量级） | 排除 |
| 重启能修 | 查 `LastBootUpTime`：09:04:46 重启，09:12 复现 | **排除** |
| 沙箱拦截 | 加 `dangerouslyDisableSandbox` 重跑 | 排除 |
| 有进程抢连管道 | 把 `nMaxInstances` 从 1 放大到 255，仍 231 | **排除** |
| 默认 DACL 被改坏 | 显式挂 SDDL `D:(A;;GA;;;WD)`，仍 231 | **排除** |
| Dart 版本回归 | 3.12.2 / 3.13.3 行为一致 | 排除 |
| Codex 沙箱服务 | 停掉 `CodexSandboxService.OpenAI.Codex` 复测 | 排除 |
| 近期系统更新 | 最新更新是 2025-11 / 2025-10 | 排除 |
| 核心隔离 HVCI | `SecurityServicesRunning = 0` | 排除 |

## 最大嫌疑人：两个国产文件系统过滤驱动

命名管道（named pipe）本身就是**文件系统对象**，由 `npfs.sys` 承载，
所以**文件系统 minifilter 能拦它的 open 操作**。把全机 minifilter 按注册表列出来
（不需要管理员），**23 个里非微软的只有两个**：

| Altitude | 驱动名 | 归属 | 层 |
|---|---|---|---|
| **380116** | **`PDDHIPS`** | **Pinduoduo Corp（拼多多）** | FSFilter HIPS —— **主动拦截型** |
| 265109 | `AliPaladin` | AliBaba Group（阿里保护） | FSFilter Activity Monitor —— 观察型 |
| 其余 21 个 | — | Microsoft | — |

**`PDDHIPS` 嫌疑最大**：HIPS（主机入侵防御）层的驱动是专门做拦截/审核的，
比 Activity Monitor 更有能力改变操作返回状态。

两个来源都是**电商客户端静默安装**的：
- 阿里保护 ← 千牛 / 淘宝卖家客户端
- PDDHIPS ← 拼多多商家版客户端

### 归因更正

- **`ahsProtector` 不是安恒。** 签名是 **北京深思数盾科技股份有限公司**
  （做加密锁 / Virbox 那家），产品名「**反黑引擎**」。它是 `Type=1` 的
  **普通内核驱动，不挂文件系统**，拦不到命名管道 → **嫌疑已排除**。
- 阿里保护 = **阿里巴巴（中国）网络技术有限公司**的 `AlibabaProtect`
  （服务显示名 "Alibaba PC Safe Service"），目录里带 `AliInlineHookCheck.dll`。

### 关于「测试模式」

`TESTSIGNING` 确实开着，但**不是本故障的原因**：

- 它只放宽内核驱动的签名校验，不碰命名管道；当前 158 个运行中的驱动**签名全部有效**
- 它是为 **`SimpleSvm`**（`E:\xl\Bin\Win64\hyperkd.sys`，跑《纪元117》用的
  内核级 hypervisor）开的 —— 那驱动没签名，必须开测试模式才能加载
- 该服务当前 **Stopped**，`HypervisorPresent = False` → 没在跑，与本次无关

> ⚠️ 但要记住：hypervisor 是最高特权层，最容易破坏系统 API。
> **要开它跑游戏之前，先把包出了。** 别在它运行着的状态下构建。

### 实测记录

`AlibabaProtect`、`AHS Service`、`ahs_protector` **都停不掉**——
当前 PowerShell 没有管理员权限，且这些服务有自保护（报「无法打开计算机上的 XXX 服务」）。

### 关键：`Stop-Service` 停不掉过滤驱动，要用 `fltmc unload`

实测：以管理员身份跑 `Stop-Service PDDHIPS -Force` 仍然失败，报
「**无法停止**计算机上的 PDDHIPS 服务」（注意是"无法停止"，不是"无法打开"——
说明权限够、服务能打开，是驱动主动拒绝了 `SERVICE_CONTROL_STOP`）。

这是**文件系统过滤驱动的正常行为**：挂在文件系统栈上的 filter 不能通过普通
"停止服务"卸下来，官方卸载途径是 `fltmc unload`。**报"无法停止"这件事本身，
反过来也印证了它们确实是 minifilter。**

两个驱动的注册表现值（**恢复时要用**）：

| 驱动 | 文件 | Start 原值 | Group |
|---|---|---|---|
| `PDDHIPS` | `C:\WINDOWS\system32\drivers\PHIPS.sys` | **3**（手动） | FSFilter Activity Monitor |
| `AliPaladin` | `C:\WINDOWS\system32\drivers\AliPaladinEx64.sys` | **2**（自动） | FSFilter Activity Monitor |

> 两者 Group 相同，**不能靠 Altitude 区分谁是元凶，必须逐个卸下来验。**

## 怎么修

按优先级：

1. **✅ 立刻可用：用管理员终端构建。** 开一个**管理员** PowerShell / CMD，
   在里面跑（`PS C:\WINDOWS\system32>` 这种提示符就是管理员窗口）：

   ```powershell
   cd "C:\Users\Administrator\WorkBuddy\2026-09-28-20-54-43\pet-app\app"
   flutter build apk --release 2>&1 | Tee-Object "$env:TEMP\apk_build.txt"
   ```

   产物在 `build\app\outputs\flutter-apk\app-release.apk`。
   **这是当前唯一能立刻出包的路子**，不用动任何驱动。

2. **想根治（让非提权进程也能跑）**：找出那条「按权限等级拦」的 HIPS 规则。
   嫌疑人还是那两个电商客户端带的内核驱动 —— 但注意 `fltmc unload` 实测**被拒**
   （`0x801f0010`），`Stop-Service` 也**被拒**，所以只能：

   ```powershell
   # 管理员。改 Start 值禁用 + 重启（这才是能生效的办法）
   New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\PDDHIPS' `
     -Name Start -Value 4 -PropertyType DWord -Force
   New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\AliPaladin' `
     -Name Start -Value 4 -PropertyType DWord -Force
   # 重启后验证。恢复时改回原值：PDDHIPS=3，AliPaladin=2
   ```

   **或者直接卸载那两个电商客户端**（阿里保护随千牛/淘宝来，PDDHIPS 随拼多多商家版来）。

3. 急用的话，在另一台干净的 Windows 上出包。

### 验证脚本（5 秒，只看第 1 行）

```bash
C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe \
  pet-app/app/tool/probe_exact2.py
```

`1 OUTBOUND + GENERIC_READ` 那行变 `OK` = 修好了；仍 `err=231` = 还有别的驱动在拦。

## 复现脚本（已留在 `pet-app/app/tool/`）

| 文件 | 作用 |
|---|---|
| `probe_spawn.dart` | 单测 Dart 的三种子进程创建模式，证明只有带管道的模式挂 |
| `probe_hold.dart` | 失败后停住 30 秒，方便外部枚举期间存在的管道名 |
| `probe_pipe.py` | 用 ctypes 复刻建管道流程，确认与管道名前缀无关 |
| `probe_exact.py` | **逐参数照抄 Dart 源码**，二分出触发点（A 条复现） |
| `probe_exact2.py` | 判别「被抢连」还是「访问被拒」——**这是最快的验证脚本** |
| `probe_exact3.py` | 用显式 SDDL 排除安全描述符问题 |

这些脚本只读、无副作用，可以直接交付给运维或安全产品厂商做定位依据。

---

# 环境阻塞二：pub 缓存缺 81 个包

## 症状

`flutter test` 四个测试文件全部「加载失败」，错误却指向 **Flutter SDK 自己的文件**：

```
/E:/dev/flutter/packages/flutter/lib/src/painting/star_border.dart:536:27:
Error: The getter 'Matrix4' isn't defined for the type '_StarGenerator'.
  squashMatrix.multiply(Matrix4.diagonal3Values(scale.dx, scale.dy, 1));
```

`flutter build apk` 同样挂在编译阶段。

## 这不是 SDK 坏了

- `star_border.dart` 第 13 行明明有
  `import 'package:vector_math/vector_math_64.dart' show Matrix4;`
- SDK 工作区**干净**（`git status --short` 无输出），文件未被本地改过

**真正的含义是：这个 import 解析失败，`Matrix4` 根本不在作用域里。**

Dart 编译器在名字找不到时，会把它当成「在所属类上找一个叫 `Matrix4` 的 getter」
去报错，于是错误信息指向了毫不相干的 `_StarGenerator`。**这是极易误判的一类报错。**

## 定位方法：逐包验存在性

`.dart_tool/package_config.json` 里每个包都有 `rootUri`。
拿它逐个 `isdir` 验一遍就行（10 行脚本，见下），**一步定位**：

结果（本机实测）：

| 项 | 数值 |
|---|---|
| `package_config.json` 引用包数 | 114 |
| **指向但实际不存在的包** | **81**（含 `vector_math-2.4.0`、`flutter_riverpod`、`fl_chart`、`sqflite`… 全部项目依赖） |
| 缓存里实际只剩 | Flutter **工具自身**的依赖（`analyzer` / `dds` / `dart_style` / `coverage`…） |
| `%LOCALAPPDATA%\Pub\Cache\hosted` 目录时间 | **刚被重建过** |

```python
# 逐包验存在性
import json, os
cfg = json.load(open('.dart_tool/package_config.json', encoding='utf-8'))
miss = [
    (p['name'], p['rootUri'].replace('file:///', ''))
    for p in cfg['packages']
    if p['rootUri'].startswith('file:///')
    and not os.path.isdir(p['rootUri'].replace('file:///', ''))
]
print('引用', len(cfg['packages']), '个，缺失', len(miss))
for n, pa in miss:
    print('  ', n, '->', pa)
```

**推断**：pub 缓存被清过一次（很可能是为释放 C 盘空间，见记忆里 C 盘膨胀大户清单），
之后只有 Flutter 工具的依赖被重新拉回来，项目的 81 个依赖从没下下来。

## 修法

```powershell
Set-Location "C:\Users\Administrator\WorkBuddy\2026-09-28-20-54-43\pet-app\app"
# 本机 DNS 有问题（1.1.1.1 被劫持），走官方国内镜像更稳
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
flutter pub get
```

若镜像报错，去掉 `$env:PUB_HOSTED_URL` 那行用默认源再试一次。

## 通用教训

**Flutter 自身源码报「某符号未定义」时，先怀疑依赖解析，别怀疑 SDK。**
排查顺序：
1. 打开报错的那个 SDK 文件，看它 **import 了什么**
2. 那不是普通 import，是 **package: 导入** → 去验 `.dart_tool/package_config.json`
   里指向的路径**是否真的存在**
3. 缺包 → `flutter pub get`

千万别顺着错误信息去查 `_StarGenerator`——那是编译器的误导。

