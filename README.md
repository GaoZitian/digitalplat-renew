<p align="center">
  <img src="https://img.shields.io/badge/DigitalPlat-Domain%20Renewal-blue?style=for-the-badge&logo=google-cloud&logoColor=white" alt="DigitalPlat Domain Renewal">
</p>

<h1 align="center">DigitalPlat 域名自动续期检查</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Shell-脚本-5391FE?style=flat-square&logo=gnubash&logoColor=white">
  <img src="https://img.shields.io/badge/API-DigitalPlat%20v1-00ADD8?style=flat-square">
  <img src="https://img.shields.io/badge/通知-Telegram-26A5E4?style=flat-square&logo=telegram&logoColor=white">
  <img src="https://img.shields.io/badge/依赖-cloudscraper%20%7C%20jq-ff69b4?style=flat-square">
</p>

<p align="center">
  定期检查 DigitalPlat 托管的 <code>.us.kg</code> / <code>.xx.kg</code> 域名到期时间，<br>
  到期前 120 天内自动免费续期，并通过 Telegram 通知列出全部域名状态。
</p>

---

## 📋 功能

- ✅ 通过 DigitalPlat API v1 获取域名列表（cloudscraper 绕过 Cloudflare 验证）
- ✅ 兼容多种 API 响应格式（`{success,data}` / 直接数组 / `{data}` / `{domains}`）
- ✅ 检查每个域名的到期时间，自动识别永久到期
- ✅ 进入 120 天续期窗口（含已过期）的域名**自动免费续期**
- ✅ 续期后重新读取权威状态，通知里显示真实到期日
- ✅ Telegram 通知：列出**全部域名** + 到期时间 + 剩余天数 + 续期结果
- ✅ 支持 GitHub Actions 定时运行

---

## 🔄 自动续期

- **触发条件**：域名剩余 ≤ 120 天（`RENEWAL_WINDOW_DAYS`）即进入窗口，自动续期
- **已过期域名也会续期**（剩余天数为负）
- **续期请求**：`POST /domains/{domain}/renew`，body `{"renewal_type":"free","years":1}`
- **不做自动重试**：续期失败会记录并通知，等待下次运行再判断（避免双扣款）
- **DRY_RUN=1**：只检查、不实际续期（安全预览）

---

## 🚀 快速使用

### 通过 GitHub Actions 运行

1. Fork 本仓库到你的 GitHub 账号
2. 进入 **Settings → Secrets and variables → Actions**
3. 添加以下 Secrets：

| Secret | 说明 |
|--------|------|
| `DIGITALPLAT_API_KEY` | DigitalPlat API Bearer Token |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | 接收通知的 Chat ID |

4. 到 **Actions** 页面手动触发一次 `renew-digitalplat` 工作流验证配置
5. 成功后，工作流会按 Schedule 每天自动运行

**Schedule：** 每天北京时间 09:00（UTC 01:00）

---

### 本地运行

```bash
git clone https://github.com/GaoZitian/digitalplat-renew.git
cd digitalplat-renew

# 安装依赖
pip3 install cloudscraper
brew install jq  # macOS

# 设置环境变量
export DIGITALPLAT_API_KEY="***"
export TELEGRAM_BOT_TOKEN="***"
export TELEGRAM_CHAT_ID="your_chat_id"

# 运行
chmod +x renew-digitalplat-subdomains.sh
./renew-digitalplat-subdomains.sh
```

---

## ⚙️ GitHub Actions 配置

工作流文件：`.github/workflows/renew-digitalplat.yml`

```yaml
name: 免费域名续期检查
on:
  schedule:
    - cron: '0 1 * * *'   # UTC 01:00 = 北京时间 09:00
  workflow_dispatch:       # 支持手动触发
```

> 注意： Secrets 在 fork 后需要重新设置，不会从 upstream 继承。

---

## 📦 依赖

| 工具 / 包 | 用途 |
|------|------|
| `cloudscraper` (Python) | 绕过 Cloudflare challenge，获取 API 数据 |
| `jq` | JSON 解析 |
| `python3` ≥ 3.8 | 脚本运行环境 |

脚本内部通过 `cloudscraper` 调用 `digitalplat_api_helper.py` 发起请求，不再直接使用 `curl`（会被 Cloudflare 拦截）。

---

## 📂 项目结构

```
├── renew-digitalplat-subdomains.sh   # 主脚本（域名检查 + Telegram 通知）
├── digitalplat_api_helper.py         # API 请求代理（Cloudflare bypass）
└── .github/workflows/
    └── renew-digitalplat.yml         # GitHub Actions 定时任务
```

---

## 🔗 API 参考

| 端点 | 方法 | 说明 |
|------|------|------|
| `domain-api.digitalplat.org/api/v1/domains` | `GET` | 获取所有域名列表 |
| `domain-api.digitalplat.org/api/v1/domains/{domain}` | `GET` | 获取单个域名详情 |
| `domain-api.digitalplat.org/api/v1/domains/{domain}/renew` | `POST` | 续期，body `{"renewal_type":"free","years":1}` |

**认证：** `Authorization: Bearer <API_KEY>`

> 端点以官方 API 文档为准（`dashboard.digitalplat.org/dashboard/api/docs`），脚本支持通过 `DIGITALPLAT_API_BASE` 覆盖 base URL。
