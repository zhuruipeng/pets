# Android 国内版服务器更新准备

## 当前结果

- GitHub Actions 已实际构建 `0.1.13+23` 国内 APK，工作流运行 `42059381868`。
- 产物为验证签名，大小 69,465,507 bytes，包含 arm64-v8a、armeabi-v7a、x86_64 的 `libapp.so`。
- APK SHA-256：`49fb2ade266f553e8118321c3f5f258933c6851d25fa99cd08375be619409c88`。
- 新包签名证书 SHA-256：`e58bb1e4ec64d39c8de891db5a787c316a401e494858c4120b70868ca36b1d9b`。
- 既有正式证书 SHA-256：`08dc7885f743714eb75b1527f9db052aafd4b702b2aed19d959e4d139a4178f1`。

**签名不同，当前验证包不能发布为旧版 App 的覆盖升级包。线上更新清单尚未修改。**

公网更新清单已读取，当前仍为 `0.1.12+22`，APK 地址为 `https://api.pet.weiyuantool.com/download/app-cn-0.1.12-22.apk`，`minBuild=0`。已实际下载该线上 APK，其 SHA-256 为 `af024c2e30367fabf79f8eefb2e251d21dc8eff8f0698cdf2d4bb5f1cdf1568c`，并从 APK v2 签名块提取证书，确认与上面的正式证书指纹相符。

## 发布所缺的实际条件

1. 原 Windows 开发机的 `app/android/upload-keystore.jks` 和 `app/android/key.properties`。项目发布记录说明它们没有进入 Git；当前构建环境也没有这两个文件。不得生成另一把密钥替代它们。
2. 服务器 SSH 连接。部署文档使用 `caiwu-service` / `prod` 别名，当前执行环境没有对应 SSH 配置、密钥或可用连接。

签名与服务器凭据仅接入受信任执行环境，不提交至仓库。

## 接入上述条件后的执行顺序

1. 用原密钥为国内 release APK 签名（可对已编译的 release 验证 APK 重新签名，不必改变业务代码），确认正式证书指纹一致。
2. 回读包名 `com.weiyuantool.pet_app`、版本 `0.1.13` / versionCode `23`；重新验证签名、安装包完整性并计算最终 APK 哈希。重新签名后的文件哈希会变化，不能使用上面的验证包哈希。
3. 上传至服务器暂存文件；核对哈希后原子改名为 `/var/www/pet-apk/app-cn-0.1.13-23.apk`，先验证 HTTPS 下载内容与本地文件完全一致。
4. 备份 `/opt/pet-api/.env`，仅更新国内服务的 `APP_VERSION=0.1.13`、`APP_BUILD=23`、`APP_APK_URL=https://api.pet.weiyuantool.com/download/app-cn-0.1.13-23.apk` 和本轮档案改进说明；保持 `APP_MIN_BUILD=0`。不修改海外清单。
5. 重启国内 `pet-api` 服务，回读 `/health` 与 `/app/version.json`，确认清单指向经核验的正式签名 APK。记录备份位置、最终哈希和版本。旧文件保持可用。
6. 用户在旧版 App 内手动“检查更新”，验收覆盖安装及本地数据保留。
