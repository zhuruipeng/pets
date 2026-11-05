# 我的宠物 0.1.13+23 · 档案改进验证包

包含 P01–P11 档案编辑与信息展示改进，详见 `docs/pet-profile-p01-p11.md`。

GitHub Actions 运行 `42059381868` 已完成 Android cn / intl、iOS cn / intl 四项实际平台构建，四项均成功。构建源码提交为 `d4056b9a3472df7b3817ea5a757b12c6bd70a4da`。依赖解析沿用锁文件中的 `https://pub.flutter-io.cn`，没有升级依赖版本。

平台构建为 Android、iOS 各 cn / intl 两个区域。沿用仓库的地区配置与构建脚本，不运行自动功能测试。

- `android-validation.apk`：使用构建环境的验证签名，不能作为原正式签名 APK 的覆盖升级包。不要为安装验证包卸载含重要本地数据的现有应用。
- `ios-unsigned.ipa`：未使用 Apple 分发签名，需自行签名或侧载；不是 App Store / TestFlight 分发包。
- 每个安装包附 SHA-256 校验文件。GitHub Actions 日志与 artifact 的 SOURCE.txt 记录来源提交。

仅在四个平台/区域构建全部成功后发布 GitHub 预发布版本。本流程不更新线上自动升级清单、不部署服务端、不上传应用商店。功能由用户按 P01–P11 清单手动验收。

2026-11-06 本机已使用原正式密钥重新签名国内 Android 包，并与实际线上 APK 的证书核对一致；当前仍因 SSH 私钥未解锁而未上传、未修改更新清单。正式包哈希与剩余步骤见 `pet-cn-release-status.md`。GitHub 原验证签名包不能直接指向正式更新清单。
