# Android 国内版 0.1.13+23 发布状态

## 2026-11-06 本机续接结果

**原正式签名 APK 已准备并核验；尚未上传、尚未更新线上清单。当前阻塞为本机 SSH 私钥未解锁。**

- 已拉取 `origin/codex/pet-profile-p01-p11`，续接起点 `db588d4`；独立 worktree 为 `E:\dev\builds\pet-profile-cn-23`。原工作目录保持不变。
- 复用 GitHub Actions 成功运行 `42059381868` 的国内编译产物，源码 `d4056b9a3472df7b3817ea5a757b12c6bd70a4da`；与续接分支 HEAD 的 `app/` 没有差异。
- 先校验下载产物 SHA-256 `49fb2ade266f553e8118321c3f5f258933c6851d25fa99cd08375be619409c88` 和原验证签名，再使用本机原 `key.properties` 指定的 `upload-keystore.jks` 重新签名。没有新建密钥，没有将签名凭据复制进新工作区或 Git。
- 正式包：`E:\dev\builds\pet-profile-cn-23\release-evidence\app-cn-0.1.13-23.apk`，69,472,578 bytes。
- 正式包 SHA-256：`05467e4f7956f5506f462f61a6a5eb956771d1c8103e6440150df52d179bbd26`。
- 正式证书 SHA-256：`08dc7885f743714eb75b1527f9db052aafd4b702b2aed19d959e4d139a4178f1`。
- APK v2/v3 签名验证通过、唯一正式签名者；16KB ZIP 对齐通过。实际回读包名 `com.weiyuantool.pet_app`、versionName `0.1.13`、versionCode `23`，无 debuggable 标记。
- 三架构 `arm64-v8a`、`armeabi-v7a`、`x86_64` 的 `libapp.so` 均存在；排除签名元数据后，104 个 ZIP 内容文件逐文件 SHA-256 与已编译原产物完全一致。
- 已通过公网完整下载当前线上 `0.1.12+22` APK，SHA-256 为 `af024c2e30367fabf79f8eefb2e251d21dc8eff8f0698cdf2d4bb5f1cdf1568c`；实际签名验证通过，证书与本次正式包完全一致。
- 公网国内清单仍为 `0.1.12 / 22`，URL 为 `https://api.pet.weiyuantool.com/download/app-cn-0.1.12-22.apk`，`minBuild=0`。没有改动线上配置、APK、服务或数据库。
- `ssh -o BatchMode=yes caiwu-service` 可连接正确主机且服务器接受已配置的公钥，但本机私钥为口令加密的 `aes256-ctr`，`ssh-agent` 未运行，不能完成认证。需用户在本机解锁/加载私钥；不得在聊天中传递私钥或口令。
- 本机验证详情与签名输出保存在该 worktree 的 `release-evidence/`，不提交 APK 或凭据。功能由用户手动验收，本轮未运行自动功能测试。

## SSH 恢复后的剩余操作

1. 只读确认 `/opt/pet-api/.env`、`pet-api.service` 和 `/var/www/pet-apk/` 的真实位置及现有版本；备份国内 `.env`，保留原 APK。仅修改国内版本配置，不改服务端代码或海外清单。
2. 上传上述**已重新正式签名**的 APK 至暂存文件；核对最终 SHA-256 后原子改名为 `/var/www/pet-apk/app-cn-0.1.13-23.apk`。先通过 HTTPS 完整下载并复核哈希与正式证书。
3. 将国内 `APP_VERSION` 更新为 `0.1.13`，`APP_BUILD` 更新为 `23`，`APP_APK_URL` 指向 `https://api.pet.weiyuantool.com/download/app-cn-0.1.13-23.apk`，填写档案改进说明；保持 `APP_MIN_BUILD=0`。
4. 仅重启国内 `pet-api`，回读 `/health`、`/app/version.json` 并核验日志、下载内容及周边服务。记录备份路径与结果。
5. 用户在旧版 App 内手动检查更新、覆盖安装及本地数据保留，按 P01–P11 验收。未完成前不得声称已通过真机功能验收。

## 上一执行环境的验证包记录

GitHub 发布的原验证 APK 使用证书 `e58bb1e4ec64d39c8de891db5a787c316a401e494858c4120b70868ca36b1d9b`，与正式证书不同。该原文件仍不能直接上线；本机正式重签后的文件与其哈希不同。此前未找到正式密钥、也没有 SSH 配置的阻塞属于上一执行环境；本机已解决正式签名，SSH 解锁仍待完成。
