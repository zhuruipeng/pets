# 我的宠物 · Pet App

双市场（中国大陆 + 海外）宠物健康管理 App。当前阶段：**M1 + M2（档案编辑 / 头像 / 个性特点）+ M3（记录页 / 记录详情 / 照片附件 / 健康页 / 回忆相册）+ 应用内自动更新**。

> 产品结构见 `../我的宠物App-MVP产品结构.html`，市场与合规调研见 `../宠物App可行性调研报告.html`。

---

## 快速验证

```bash
cd app
flutter pub get
flutter analyze     # No issues found
flutter test        # All tests passed (82)
```

两个区域分别跑：

```bash
flutter run --flavor cn   --dart-define=REGION=cn
flutter run --flavor intl --dart-define=REGION=intl
```

切到第四个 Tab（我的），确认 `region:` / `vendor:` / `rules:` / 地图开关四项随 flavor 切换。
**这是双市场架构的第一道验收。**

> 若 `flutter test` 报 `Flutter failed to delete file ... sqlite3.dll`，
> 是残留 `flutter_tester` 进程占着文件：`Get-Process flutter_tester | Stop-Process -Force` 后重跑。

---

## 目录结构

```
pet-app/
├── app/                          Flutter 客户端（cn / intl 双 flavor）
│   ├── lib/
│   │   ├── core/                 区域配置、单位换算、文案表（双市场核心）
│   │   ├── data/
│   │   │   ├── db/               Schema 与建库迁移
│   │   │   └── repositories/     五个仓储，只管存取不管业务
│   │   ├── domain/               业务规则（免疫计划，按区域分集）
│   │   ├── services/             能力抽象（地理编码、通知）
│   │   ├── ui/                   四个页面 + 弹层 + 通用组件
│   │   ├── providers.dart        状态层与动作层
│   │   └── main.dart             入口
│   └── test/                     82 个测试
├── server/                       FastAPI 后端（中国区 / 海外区 同源部署）
└── docs/                         开发任务与决策记录

```

---

## 双市场分包

两个 flavor 是**两个独立的应用**：包名不同
（cn = `com.weiyuantool.pet_app` / intl = `com.weiyuantool.pet`），
能同时装在一台手机上对比行为，测试时不用卸载重装。

**cn 的包名不能改** —— 已经装在用户手机上的就是这个 id，改了等于换应用，
老用户收不到更新。

---

## 出安卓包与发新版

**必须通过脚本出包**，别手敲 flutter 命令：

```powershell
# 中国区 APK（在管理员终端里跑）
.\app\tool\build_apk.ps1 -Region cn

# 海外区 AAB（上 Google Play）
.\app\tool\build_apk.ps1 -Region intl -AppBundle
```

脚本把 `--flavor` 和 `--dart-define=REGION` 绑死 —— 这两个值谁都不校验谁，
漏掉后者会打出一个「Android 侧是中文区包、Dart 侧按海外区跑」的错包，
能装上能启动，只有联网时才露馅。

> ⚠️ 定义了 flavor 之后 **`flutter build apk` 必须带 `--flavor`**，
> 不带会直接报「You must specify a --flavor option」。
> 同理，本机 flutter 全命令必须在**管理员终端**里跑（非提权进程会撞
> `CreateFile failed 231`），原因见 `docs/环境阻塞-flutter管道问题.md`。

发新版（含应用内自动更新）的完整步骤、签名要求与踩坑清单，见
**`docs/自动更新-发布流程.md`** —— 那篇是按「发一次新版要做哪几步」写的操作手册，
比这里抄一遍靠谱。

---

## 七条架构约定（违反其一都会让双市场变复杂）



### 1. 区域判断只在 `core/region.dart` 出现

业务代码一律读 `AppRegion.current`，不允许出现散落的 `Platform.isAndroid` 式判断。
新增区域差异时，在 `region.dart` 加一个 getter，不要加到业务层。

⚠️ `Platform.isAndroid`（平台差异）与 `AppRegion.isCn`（市场差异）**正交**，混用会变成一团没法维护的条件判断。

### 2. 数据不出境，分区独立部署

```
中国用户数据 → 腾讯云（中国境内）   海外用户数据 → 海外节点
```

两区共用同一套服务端代码，靠环境变量 `REGION` 区分。
**不做跨区迁移，不做跨区账号。** 这样 PIPL 的出境评估、GDPR 的 SCCs 与 TIA 全部不需要做。

### 3. 记录统一走 `records` 表

用 `type` 区分体重 / 疫苗 / 用药 / 病历，类型特有字段放 `payload`（JSON）。
加新记录类型不建表、不迁移。

### 4. `recorded_at` 与 `created_at` 必须分开

用户今天补录上个月的疫苗，两个时间完全不同。混用会导致时间线和同步全错。
仓储层为此**不提供「默认 now」的重载**，逼调用方显式传 `recordedAt`。

### 5. 全部软删除

同步冲突时硬删除会丢数据。所有业务表带 `deleted_at`。

### 6. 高频写入必须批量

轨迹点每秒一个，一次遛狗 1800 个。`WalkRepository.appendPoints` 按 500 条分批走事务。
精度 >50m 的点视为漂移直接丢弃。

### 7. 待同步的变更由数据库自动记录，不靠仓储手写

每张同步表挂 `AFTER INSERT/UPDATE` 触发器写 `sync_outbox`（见 `schema.dart`）。
仓储有六个、写方法二十多个，手动「记一笔」漏一处就是某类数据永远不同步、
且只在那条路径上复现。契约见 **`docs/同步协议.md`**。

---

## MVP 边界（不做清单）

| 不做 | 原因 |
|---|---|
| 社区 / UGC | 需《安全评估报告》 |
| 商城 / 交易 | 需 ICP 证 + EDI 证 |
| 在线问诊 | 需《动物诊疗许可证》 |
| AI 生成内容 | 需算法备案（2–3 个月） |
| 自研大模型 | 需大模型备案（6–8 个月） |
| 自研 GPS 硬件 | 需 SRRC + CTA 认证与供应链 |
| 国内地图底图渲染 | 涉测绘资质 |

**推送、登录、支付**三个最大的双市场分叉点，MVP 因功能克制而全部绕开。

---

## 当前进度

- [x] 数据模型设计（九张表）
- [x] 区域抽象层
- [x] 单位换算
- [x] 免疫规则分区域集
- [x] M1 数据层落地（建库迁移 + 五个仓储 + 测试全绿）
- [x] 四页 UI（今日 / 记录 / 档案 / 我的，均非占位）
- [x] M2.1 UI 产品化收口（首页压缩 + Upcoming、档案空字段隐藏、我的页诊断改 debug-only）
- [x] M2.2 宠物档案编辑（姓名/品种/性别/生日/绝育/芯片号/毛色/体重基线/过敏/备注）
- [x] M2.2 头像上传（拍照或相册 → 拷入应用目录 → 展示与移除）
- [x] M2.3 个性特点多选（schema v3，存 code 不存文案）
- [x] M3.1 记录页（时间线层级 / 类型筛选 / 日期分组 / 空态与入口）
- [x] M3.2 记录详情页（数值 / 差值 / 补录标记 / 改时间 / 删除）
- [x] M3.3 照片附件（`image_picker` + 本地拷贝入库 + 软删除）
- [x] M3.4 健康页（预防保健 / 体重趋势 / 过敏 / 病史）
- [x] M3.5 档案页「记录」「回忆」两个页签（条目时间线、照片墙）
- [x] 应用内自动更新（服务端版本清单 + 下载 + 系统安装器，见 `docs/自动更新-发布流程.md`）
- [x] M4 手动新建提醒（周期 / 一次性 / 自定义间隔）+ 通知点击直达操作卡
- [x] M5 联系方式（手机 / 微信 / 邮箱 / 其它）+ 「我的」页可编辑
- [x] M5 走失协查卡片（截图成图 → 转发；含照片、特征、走失时间地点、联系方式）
- [x] M5 遛狗详情 + 轨迹图（海外渲染底图、中国区只画轨迹；见 `core/region.dart`）
- [x] M6 同步协议（`docs/同步协议.md`：push/pull、LWW、墓碑、可见性过滤）
- [x] M6 客户端同步底座（schema v4：outbox 触发器自动捕获变更 + 同步引擎）
- [x] M6 服务端账号与同步接口（验证码登录、`/sync/push|pull`、成员邀请）
- [x] M6 登录页（手机/邮箱验证码）与共养界面（邀请、接受、移除、角色）
- [x] M6 同步状态卡片 + 后台同步调度（回前台必同步、前台每 60 秒「有改动才同步」）
- [x] M7 双市场分包（cn / intl 两个 flavor，独立包名与桌面名称，`tool/build_apk.ps1` 出包）
- [x] M7 应用图标（含自适应图标与主题图标，`tool/make_icons.py` 从源图重新合成）
- [x] M7 商店素材与法律文本（`docs/store/`：文案、宣传图、隐私政策、用户协议）
- [x] M7 正式发布签名（`android/upload-keystore.jks` + `key.properties`，均不进版本库）
- [x] M7 App 内可打开隐私政策与用户协议（上架硬要求）
- [ ] M7-上架剩余：截图拍摄、软著登记、ICP 备案号、隐私政策网页版发布

