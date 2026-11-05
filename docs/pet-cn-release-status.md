# Android 国内版 0.1.13+23 发布状态

## 2026-11-06 发布完成

**国内正式签名 APK 已上线，公网清单已切换为 `0.1.13+23`；`APP_MIN_BUILD=0`。功能由用户手动验收。**

| 项目 | 结果 |
| --- | --- |
| 国内下载 | https://api.pet.weiyuantool.com/download/app-cn-0.1.13-23.apk |
| 包名与版本 | `com.weiyuantool.pet_app`，`0.1.13 / 23`，无 debuggable 标记 |
| APK 大小 | 69,472,578 bytes |
| APK SHA-256 | `05467e4f7956f5506f462f61a6a5eb956771d1c8103e6440150df52d179bbd26` |
| 正式证书 SHA-256 | `08dc7885f743714eb75b1527f9db052aafd4b702b2aed19d959e4d139a4178f1` |
| 配置备份 | `/root/pet-release-backups/cn-0.1.13-23-20261105T233036Z/cn.env.before`，权限 0600；目录 0700 |
| 清单切换时间 | 2026-11-06 07:33:46–07:33:48（北京时间） |
| 线上配置 | 仅修改国内 `APP_VERSION`、`APP_BUILD`、`APP_APK_URL`、`APP_NOTES`；保留 `APP_MIN_BUILD=0` |
| 服务 | 仅重启国内 `pet-api.service`；国内、海外及 ERP 均 active，重启错误日志 0 |

## 源码与签名

- 已拉取 `origin/codex/pet-profile-p01-p11`，续接起点 `db588d4`；独立 worktree 为 `E:\dev\builds\pet-profile-cn-23`。原工作目录保持不变。
- 复用 GitHub Actions 成功运行 `42059381868` 的国内编译产物，源码 `d4056b9a3472df7b3817ea5a757b12c6bd70a4da`；与本次功能分支的 `app/` 没有差异。
- 原验证产物 SHA-256 为 `49fb2ade266f553e8118321c3f5f258933c6851d25fa99cd08375be619409c88`，证书为 `e58bb1e4ec64d39c8de891db5a787c316a401e494858c4120b70868ca36b1d9b`，不能直接上线。
- 本机先验证原产物哈希及签名，再使用原 `key.properties` 指定的 `upload-keystore.jks` 重新签名。没有生成新密钥，没有将凭据复制进新工作区或 Git。
- 正式包 APK v2/v3 签名验证通过，唯一正式签名者，16KB ZIP 对齐通过。三架构 `arm64-v8a`、`armeabi-v7a`、`x86_64` 的 `libapp.so` 均存在；排除签名元数据后，104 个 ZIP 内容文件逐文件 SHA-256 与编译产物完全一致。
- 已通过公网完整下载旧 `0.1.12+22` APK，哈希为 `af024c2e30367fabf79f8eefb2e251d21dc8eff8f0698cdf2d4bb5f1cdf1568c`；其实际证书与新正式包完全一致。
- 本机正式包为 `E:\dev\builds\pet-profile-cn-23\release-evidence\app-cn-0.1.13-23.apk`。此前 SSH 私钥未解锁的阻塞已解决，临时解锁助手已清理，密钥文件未改动。

## 上传与验证

1. 通过 `ssh caiwu-service` 确认 `/opt/pet-api/.env`、`/var/www/pet-apk/` 与 `pet-api.service`；先备份国内配置、服务定义及只读基线，再上传到备份目录的私有暂存文件。
2. 服务器核对完整 SHA-256 与大小后，以排他硬链接原子发布新文件名，不覆盖旧 APK；暂存链接随后移除。
3. 清单切换前，独立本机客户端通过 HTTPS 完整下载 69,472,578 字节，哈希及正式证书均与本机包一致。
4. 只修改国内四个版本字段，其他配置逐行保留，`.env` 仍为 0600；国内服务重启失败时有原配置原子恢复保护。本次正常成功，未触发回滚。
5. 公网 `/health` 正常；`/app/version.json` 为 `0.1.13 / 23`、`minBuild=0`、指向上述正式包。下载 HTTP 200、正确 APK 类型与长度；旧包仍 HTTP 200，服务器旧包哈希不变。
6. 13 个部署源码文件前后哈希完全相同；海外 `.env` 哈希、海外与 ERP 的主进程及启动时间、ERP 运行软链接均不变。未修改 nginx 或服务端代码，未部署海外或 iOS。
7. 重启前使用实际数据库的只读连接确认模型表列完整、既有 `users.password_hash` 存在；14 表列结构指纹在重启前后完全一致。现有启动流程会调用幂等初始化，本轮没有新增或补建表列，也没有业务数据写入、数据修复或新迁移。

备份目录包含 `release-before.json`、`schema-before.json`、`release-after.json`、`final-verification.json` 和私有重启日志；本机核验结果保存在 `release-evidence/`，APK 与本机临时文件不提交 Git。

## 待用户手动验收

在旧版 App 内检查更新并覆盖安装，确认本地数据保留；按 `pet-profile-p01-p11.md` 核对 P01–P11。此次不运行自动功能测试，不将发布核验写成真机功能验收通过。
