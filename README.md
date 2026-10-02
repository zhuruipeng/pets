# 我的宠物 · Pet App

双市场（中国大陆 + 海外）宠物健康管理 App。当前阶段：**功能开发收口，等待软著证书与商店审核**。

线上版本：`0.1.5+7`（cn 区）· 本地已出包待部署：`0.1.7+9`

> 产品结构见 `../我的宠物App-MVP产品结构.html`，市场与合规调研见 `../宠物App可行性调研报告.html`。

---

## 快速验证

```bash
cd app
flutter pub get
flutter analyze     # No issues found
flutter test        # All tests passed (186)
```

两个区域分别跑：

```bash
flutter run --flavor cn   --dart-define=REGION=cn
flutter run --flavor intl --dart-define=REGION=intl
```

切到第四个 Tab（我的），确认 `region:` / `vendor:` / `rules:` / 地图开关四项随 flavor 切换。
**这是双市场架构的第一道验收。**

### ⚠️ 本机 flutter 必须在管理员终端里跑

非提权进程跑 flutter 全命令会撞 `CreateFile failed 231`
（本机 HIPS 按进程完整性级别拦命名管道），原因与绕过见
`docs/环境阻塞-flutter管道问题.md`。**Agent 发起的 UAC 弹窗老板看不见**，
所以 flutter 命令一律由老板自己在 `Win` → `powershell` → `Ctrl+Shift+Enter` 里跑。

绕得开的两条路：

| 场景 | 办法 |
|---|---|
| 想跑 `flutter analyze` | `tool/analyze_offline.py` —— 用 Python 直连 analysis server 的 LSP，把真 analyze 离线跑出来 |
| 想验 schema / 领域逻辑 | `tool/dump_schema.dart` + `tool/schema_smoke.py`（生产 DDL 真跑 sqlite3）；`tool/verify_*.dart`（纯 Dart 断言，不依赖 flutter_tester） |

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
│   │   │   ├── db/               Schema 与建库迁移（当前 v6）
│   │   │   ├── models.dart       全部实体与 wire 往返
│   │   │   ├── repositories/     八个仓储，只管存取不管业务
│   │   │   └── sync/             同步引擎（LWW + 墓碑）
│   │   ├── domain/               业务规则（免疫计划 / 费用统计 / 报告，均按区域分集）
│   │   ├── services/             能力抽象（地理编码、通知）
│   │   ├── ui/                   17 个文件：四个页面 + 详情页 + 弹层 + 通用组件
│   │   ├── providers.dart        状态层与动作层
│   │   └── main.dart             入口
│   ├── tool/                     出包脚本 + 离线验证脚本（见下）
│   └── test/                     8 个测试文件，186 个用例
├── server/                       FastAPI 后端（中国区 / 海外区 同源部署）
└── docs/                         开发任务、发布手册与决策记录
    └── store/                    上架与软著材料
```

### `app/tool/` 里的脚本分两类

| 脚本 | 干什么 |
|---|---|
| `release_all.ps1` | **出包唯一入口**：`git pull → flutter test → release.ps1` |
| `release.ps1` | 抬版本号 + `flutter build` + 打印部署指引 |
| `build_apk.ps1` | 只构建不抬号（调试用） |
| `analyze_offline.py` | 非提权环境下把 `flutter analyze` 离线跑出来 |
| `dump_schema.dart` / `schema_smoke.py` | 打印生产 DDL 并在 sqlite3 里真跑一遍 |
| `verify_*.dart` | 纯 Dart 领域逻辑断言（费用统计、报告、洗澡排期、健康台账…） |
| `make_copyright_pdf.py` / `make_copyright_manual.py` | 生成软著程序鉴别材料 / 操作说明书 |
| `make_icons.py` | 从源图重新合成全套应用图标 |

> ⚠️ **含中文的 `.ps1` 必须带 UTF-8 BOM**。PS 5.1 对无 BOM 文件按 GBK 解码，
> 会把中文注释啃掉连带破坏 param 块语法，报「','后面缺少表达式」。
> 改完 `.ps1` 用 `Parser::ParseFile` 验一遍再提交。

---

## 双市场分包

两个 flavor 是**两个独立的应用**：包名不同
（cn = `com.weiyuantool.pet_app` / intl = `com.weiyuantool.pet`），
能同时装在一台手机上对比行为，测试时不用卸载重装。

**cn 的包名不能改** —— 已经装在用户手机上的就是这个 id，改了等于换应用，
老用户收不到更新。

---

## 出安卓包与发新版

**一条命令搞定**（在管理员终端里跑）：

```powershell
cd app
.\tool\release_all.ps1                # cn 区：pull → test → 抬号出包
.\tool\release_all.ps1 -Region intl   # 海外区
.\tool\release_all.ps1 -NoBump        # 版本号已抬过时复用（构建失败重跑用）
```

**测试不过就停，绝不带病出包。** 不要手敲 flutter 命令，也不要把
pull / test / build 拆成多行贴给老板 —— 出包那行总在最后，
粘贴顺序一乱就被丢掉（2026-10-01 / 10-02 两次实测）。

脚本把 `--flavor` 和 `--dart-define=REGION` 绑死 —— 这两个值谁都不校验谁，
漏掉后者会打出一个「Android 侧是中文区包、Dart 侧按海外区跑」的错包，
能装上能启动，只有联网时才露馅。

> ⚠️ 定义了 flavor 之后 **`flutter build apk` 必须带 `--flavor`**，
> 不带会直接报「You must specify a --flavor option」。

### 加 Android 插件前先看 `android/app/build.gradle`

两个实测踩过的坑：

- **AGP 9 不套 `kotlin-android` 插件的依赖，Kotlin 源码被静默跳过** ——
  编译产物只剩 `R.class`，到运行期才报 `GeneratedPluginRegistrant` 找不到实现类。
- **插件写死 `compileSdk 34` 会被 `checkReleaseAarMetadata` 拒** ——
  `file_picker` 全 8.x 都写死 34，逐版本降级都没用。

所以文件选择最终用的是官方 `file_selector`（`compileSdk = flutter.compileSdkVersion`）。
**别换回 file_picker。**

### 构建失败先看 daemon 日志

Gradle 的真实报错在 `E:/dev/gradle/daemon/<gradle版本>/daemon-<pid>.out.log` 里，
终端输出常常只有一句概括。

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

用 `type` 区分体重 / 疫苗 / 驱虫 / 用药 / 病历 / 洗澡 / 喂食 / 饮水 / 如厕 / 睡眠 / 备注，
类型特有字段放 `payload`（JSON）。加新记录类型不建表、不迁移。

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
仓储有八个、写方法三十多个，手动「记一笔」漏一处就是某类数据永远不同步、
且只在那条路径上复现。契约见 **`docs/同步协议.md`**。

触发器支持 `kSyncSkipWhen` 额外条件 —— 文档原件标了 `local_only`，
同步引擎就该跳过它（见约定 8）。

### 8. 用户上传的原件只存本机

记录详情页能挂 PDF / 图片原件，但**只拷进应用私有目录、标 `local_only=1`、不入同步**。
理由：这些是病历、化验单、合同一类的东西，用户没授权出本机。
`schema.dart` 的 `kSyncSkipWhen` 负责在触发器层拦住，仓储层再挡一道。

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

## 上架与软著材料

全在 `docs/store/`：

| 文件 | 用途 |
|---|---|
| `上架文案与提交清单.md` | 双市场文案、关键词、提交步骤 |
| `隐私政策.md` / `用户协议.md` | 法律文本（App 内可打开，网页版已上线） |
| `软著-程序鉴别材料-源代码-V0.1.5.pdf` | 60 页，前 30 页 + 后 30 页，每页 50 行 |
| `软著-文档鉴别材料-操作说明书-V0.1.5.pdf` | 8 页十章，配 8 张真机截图 |
| `screenshots/01~08*.jpg` | 真机截图（商店截图与软著说明书共用） |
| `feature-graphic-1024x500.png` / `icon-512.png` | 商店宣传图与应用图标 |

生成软著 PDF 用 `tool/make_copyright_pdf.py` / `tool/make_copyright_manual.py`
（依赖 fpdf2 + simhei.ttf；pip 装不上就 `-i https://mirrors.aliyun.com/pypi/simple/`）。
改完源码要重新生成时记得同步页数 —— 版权局要求前 30 页 + 后 30 页共 60 页整。

App 备案四件套（包名、证书 MD5/SHA-256、域名）见 `docs/store/上架文案与提交清单.md`。

---

## 当前进度

### 已完成

- [x] 数据模型设计 · 区域抽象层 · 单位换算 · 免疫规则分区域集
- [x] M1 数据层落地（建库迁移 + 仓储 + 测试全绿）
- [x] 四页 UI（今日 / 记录 / 档案 / 我的，均非占位）
- [x] M2.1 UI 产品化收口（首页压缩 + Upcoming、档案空字段隐藏、我的页诊断改 debug-only）
- [x] M2.2 宠物档案编辑 + 头像上传
- [x] M2.3 个性特点多选（schema v3，存 code 不存文案）
- [x] M3.1 记录页 · M3.2 记录详情页 · M3.3 照片附件 · M3.4 健康页 · M3.5 回忆相册
- [x] M4 手动新建提醒（周期 / 一次性 / 自定义间隔）+ 通知点击直达操作卡
- [x] M5 联系方式 · 走失协查卡片 · 遛狗详情 + 轨迹图（海外渲染底图、中国区只画轨迹）
- [x] M6 同步协议 + 客户端同步底座（outbox 触发器）+ 服务端账号与同步接口 + 登录页 + 共养界面
- [x] M7 双市场分包 · 应用图标 · 商店素材与法律文本 · 正式发布签名 · App 内可打开法律页
- [x] 导出彩色 PDF 报告（疫苗 / 体重曲线 / 健康台账）
- [x] 洗澡美容排期（周期推算 + 下次到期提醒）
- [x] 每日日志（饮水毫升 / 睡眠小时 / 喂食 / 如厕）
- [x] 费用追踪（schema v5：8 分类、月度趋势、分类占比、合计）
- [x] 文档原件附件（schema v6：`file_name` / `mime` / `size_bytes` / `local_only`）
- [x] 应用内自动更新（服务端版本清单 + 下载 + 系统安装器）
- [x] M2 体验优化批次：档案 Header 收紧留白、页签文字防跳动、记一笔体重可精确输入、详情页内容优先

### 待办

- [ ] 部署 `0.1.7+9` 到生产（scp → sha1 → `.env` 抬 `APP_VERSION`/`APP_BUILD` → 重启 `pet-api` → 验 `version.json`）
- [ ] M2.5 真机验收（390×844 / 412×915 两档屏，重点验体重点击输入、详情页只一行时间、页签文字不晃）
- [ ] 软著登记提交（等实名认证通过，三件套已备齐）
- [ ] App 备案
- [ ] 商店截图按各平台尺寸裁切 + 渠道文案提交
