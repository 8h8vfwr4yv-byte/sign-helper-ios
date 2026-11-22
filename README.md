# IPA 签名助手（SignHelper）

管理 IPA 文件库、解析签名与到期时间的 iOS 助手。本身以未签名 IPA 形式交付，用 AltStore / SideStore 安装。

## 先说清楚（重要）

“用个人 Apple ID 登录给 IPA 签名”背后是一整套与苹果服务器的认证与签名流程：SRP 登录、anisette 设备信任数据、注册设备、申请免费证书（7 天）、生成描述文件、对 Mach-O 重新签名。目前完整实现这套流程的是 **AltStore（电脑端 AltServer 执行签名）** 和 **SideStore（本机签名）**。

本助手：
- **不做 Apple ID 登录框**——它连不上苹果的签名服务，放个密码框只会让你白白交出密码，既签不了名也不安全
- **不直接签名**——签名动作是预留入口，会明确提示并给出两条可行路线
- 负责签名之外同样重要的部分：**IPA 库管理 + 签名/到期解析 + 续签提醒**（免费证书 7 天到期是侧载最常见的翻车点）
- 本助手自身首次安装同样需要先被签一次（所有侧载工具共同的鸡生蛋问题）

## 功能

**IPA 库**
- 导入 IPA（可多选），文件存入 App 沙盒
- 解析并展示：应用图标、名称、Bundle ID、版本、最低系统、大小
- 按描述文件剩余天数排序，快到期/已过期的排在最前并标红

**签名信息解析**
- 是否已签名（`_CodeSignature` 是否存在）
- 解析 `embedded.mobileprovision`：团队名称、Team ID、创建时间、到期时间、剩余天数

**详情**
- 分享/导出 IPA（给 AltStore、SideStore、iloader 等工具续签用）
- “签名/续签”入口（预留，含说明）

**签名页**
- 为什么没有登录框的完整说明
- 路线一 AltStore（电脑配合）：步骤、官网、本机是否已装检测
- 路线二 SideStore（本机续签）：步骤、官网、本机检测
- 免费证书规则提示：7 天有效期、最多 3 个自签 App

## 实现要点

- `Sources/ZipReader.swift` — 极简 ZIP 中央目录解析 + deflate 解压（系统 Compression 框架），IPA 与描述文件解析
- `Sources/App.swift` — 库存储、三标签页（IPA 库 / 签名 / 说明）
- GitHub Actions 使用 Xcode 27.2 / iOS 27.2 SDK（`xcode-27` runner）+ XcodeGen 构建未签名 IPA，最低系统 iOS 17.0
