<div align="center">

# Orange

[![许可证](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)
[![Telegram群组](https://img.shields.io/badge/Telegram-加入群组-blue?style=flat-square&logo=telegram)](https://t.me/V2Hiidify)

**基于 FlClash v0.8.85 的多平台代理客户端，深度集成全新 XBoard 面板支持**

[English](README.md) | [简体中文](README_zh_CN.md)

</div>

---

## 📖 项目简介

Orange 是基于 [FlClash v0.8.85](https://github.com/chen08209/FlClash) 的增强版本，深度集成了 **XBoard v20250905-b144770** 面板支持。本项目采用模块化设计理念，将所有 XBoard 相关功能封装在独立的 `lib/xboard` 模块中，最大限度减少与上游 FlClash 的代码冲突，便于后续跟进上游更新。

### 🎯 核心设计理念

- **FlClash 作为 Core**：将原版 FlClash 视为核心依赖，所有定制功能均在独立模块中实现
- **最小侵入式改动**：涉及原生 UI 修改时（如订阅组件），采用复制原实现并独立维护的方式
- **SDK 化设计**：XBoard SDK 独立于 FlClash，可方便嵌入其他 Flutter 项目使用
- **更新友好**：最大限度减少 `git pull` 上游更新时的合并冲突问题

---

## ✨ 核心特性

### 🛡️ 入口域名防封锁机制
- 多域名竞速策略
- 国内中转服务器支持
- 数据混淆与加密传输
- UA 对等密钥验证

### 🚀 高可用性保障
- 域名竞速自动选择最快节点
- 多源配置自动降级
- 缓存机制提升响应速度
- 自动容灾切换

### 🔐 安全与加密
- TLS 证书验证
- 订阅数据加密
- API 响应混淆
- 私有证书支持

### 🌐 配置文件托管
- GitHub/Gitee 多源配置
- 客户端加密解密
- CDN 加速支持
- 灵活的降级策略

### 📡 扩展功能
- 在线客服系统集成
- 设备上报与远程任务
- 自动更新检查
- WebSocket 实时通信

> 📚 **详细说明**：查看 [核心特性文档](docs/features.md)

---

## 🚀 快速开始

> 📖 **配置教程**：[最小可用性配置指南](docs/quick-start.md) | [配置示例](docs/examples/minimal.md)

### 1. 构建应用

> 🛠️ **详细步骤**：[构建指南](docs/build-guide.md)

### 2. 配置应用

详细配置步骤请查看文档：

> ⚙️ **配置指南**：[快速开始](docs/quick-start.md) | [配置文档](docs/configuration.md) | [配置示例](docs/examples/minimal.md)

---

## 📚 文档导航

| 文档 | 说明 |
|------|------|
| [快速开始](docs/quick-start.md) | 5分钟最小可用性配置教程 |
| [构建指南](docs/build-guide.md) | 完整的构建和运行环境配置 |
| [配置文档](docs/configuration.md) | 完整的配置说明和示例 |
| [核心特性](docs/features.md) | 详细的功能说明和使用方法 |
| [服务端部署](docs/server-deployment.md) | XBoard 面板和 Caddy 反代配置 |
| [安全配置](docs/security.md) | 证书、加密、混淆等安全配置 |
| [文档中心](docs/README.md) | 所有文档的索引和导航 |

---

## 📸 应用截图

<div align="center">

<img src="images/homepage.jpg" width="160" alt="主页"/> <img src="images/plans.jpg" width="160" alt="套餐计划"/> <img src="images/purchase.jpg" width="160" alt="购买页面"/> <img src="images/invitepage.jpg" width="160" alt="邀请页面"/> <img src="images/notice.jpg" width="160" alt="通知公告"/>

<details>
<summary>📱 点击查看大图预览</summary>

<br/>

**主页界面**
![主页](images/homepage.jpg)

---

**套餐计划**
![套餐计划](images/plans.jpg)

---

**购买页面**
![购买](images/purchase.jpg)

---

**邀请页面**
![邀请](images/invitepage.jpg)

---

**通知公告**
![通知](images/notice.jpg)

</details>

</div>

---

## 📱 平台支持

| 平台 | 状态 | 备注 |
|-----|------|------|
| Android | ✅ 支持 | 推荐 Android 7.0+ |
| Windows | ✅ 支持 | Windows 10+ |
| macOS | ✅ 支持 | macOS 13.0+（Entoma 首个公开测试版本） |
| Linux | ✅ 支持 | 需安装依赖 |
| iOS | ⏳ 规划中 | 待适配 |

---

## ⚠️ 免责声明

1. **开源声明**：
   - 本项目基于开源协议发布
   - 核心代码来自 FlClash 和 Clash Meta
   - XBoard 模块为独立开发

2. **使用风险**：
   - 本软件仅供学习和研究使用
   - 使用前请充分评估隐私和安全风险
   - 用户需自行承担使用本软件的风险

3. **安全警告**：
   - 关闭证书验证将导致严重安全风险
   - 仅在可信的测试环境中使用
   - 生产环境必须启用 HTTPS 证书验证

4. **效果声明**：
   - 数据混淆功能的有效性未经权威验证
   - 不保证能够完全防止检测和封锁
   - 请根据实际需求谨慎使用

---

## 🤝 贡献与支持

### 上游项目

- [FlClash](https://github.com/chen08209/FlClash) - 多平台 Clash 客户端
- [Clash Meta](https://github.com/MetaCubeX/Clash.Meta) - Clash 内核

### 问题反馈

如果您在使用过程中遇到问题或有改进建议：
- 提交 [Issue](https://github.com/hakimi-x/Xboard-Mihomo/issues)
- 加入 [Telegram 群组](https://t.me/V2Hiidify)

### Star 支持

如果这个项目对您有帮助，欢迎给个 ⭐ Star！

### 💰 打赏支持

如果您觉得这个项目对您有帮助，可以请作者喝杯咖啡 ☕

| 币种 | 地址 |
|------|------|
| **TRC-USDT** | `TFPvpxb5k2mYYcvABe5BrCz7Tt6BhnZxxj` |
| **POL-USDT** | `0xFbbfD2b98fB3F7a4084275ad3139ba179bFDFa0F` |

---

<div align="center">

**© 2025 Orange. All Rights Reserved.**

</div>
