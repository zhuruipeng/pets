# 我的宠物 0.1.13+23 · 档案改进验证包

包含 P01–P11 档案编辑与信息展示改进，详见 `docs/pet-profile-p01-p11.md`。

平台构建为 Android、iOS 各 cn / intl 两个区域。沿用仓库的地区配置与构建脚本，不运行自动功能测试。

- `android-validation.apk`：使用构建环境的验证签名，不能作为原正式签名 APK 的覆盖升级包。不要为安装验证包卸载含重要本地数据的现有应用。
- `ios-unsigned.ipa`：未使用 Apple 分发签名，需自行签名或侧载；不是 App Store / TestFlight 分发包。
- 每个安装包附 SHA-256 校验文件。GitHub Actions 日志与 artifact 的 SOURCE.txt 记录来源提交。

仅在四个平台/区域构建全部成功后发布 GitHub 预发布版本。本流程不更新线上自动升级清单、不部署服务端、不上传应用商店。功能由用户按 P01–P11 清单手动验收。
