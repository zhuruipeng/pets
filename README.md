# 我的宠物 · Pet App

双市场（中国大陆 + 海外）宠物健康管理 App。当前阶段：**M1 + M2.1 UI 收口 + M3.1~M3.3（记录页 / 记录详情 / 照片附件）完成，四页 UI 可跑**。

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

## 构建两个包

```bash
cd app

# 中国大陆包
flutter build appbundle --flavor cn   --dart-define=REGION=cn

# 海外包
flutter build appbundle --flavor intl --dart-define=REGION=intl
```

> ⚠️ flavor 定义（`android/app/build.gradle` 的 productFlavors、图标、包名区分）
> 属于 M7 的工作，当前 `flutter run --flavor` 前需先补这块配置；
> 不带 flavor 直接 `flutter run` 会用默认 `intl` 区域跑起来。

---

## 六条架构约定（违反其一都会让双市场变复杂）

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
- [x] M1 数据层落地（建库迁移 + 五个仓储 + 82 个测试全绿）
- [x] 四页 UI（今日 / 记录 / 档案 / 我的，均非占位）
- [x] M2.1 UI 产品化收口（首页压缩 + Upcoming、档案空字段隐藏、我的页诊断改 debug-only）
- [x] M3.1 记录页（时间线层级 / 类型筛选 / 日期分组 / 空态与入口）
- [x] M3.2 记录详情页（数值 / 差值 / 补录标记 / 改时间 / 删除）
- [x] M3.3 照片附件（`image_picker` + 本地拷贝入库 + 软删除）
- [ ] M2.2 宠物档案编辑与头像（当前为 `_editSoon` 占位）
- [ ] M3.4 健康页（体重趋势 / 预防保健 / 病史汇总）
- [ ] M4 提醒手动新建与通知直达
- [ ] M5 轨迹地图与走失协查卡片
- [ ] M6 共养与云同步
- [ ] M7 双市场 flavor 配置与上架

