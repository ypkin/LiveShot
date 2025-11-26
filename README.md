
-----

# 📸 LiveShot - 网页实时截图与直播 API

> **Turn your VPS into a secure, real-time web monitoring API.**
> 将您的 VPS 瞬间变身为强大的网页截图与直播服务器。

**LiveShot** 是一个基于 **Node.js** 和 **Puppeteer** (Headless Chrome) 的轻量级服务。它允许你通过简单的 API 调用，获取任何网页的高清截图，甚至是以 **MJPEG 视频流** 的形式实时“直播”网页的变化。

特别适合用于 **服务器探针监控 (Server Status)**、**GitHub Profile 动态展示**、**自动化报表生成** 或 **网页变动监控**。

-----

## ✨ 功能特性 (Features)

  * **⚡ 毫秒级静态截图**: 支持自定义分辨率、长截图 (`fullPage`)。
  * **🎥 实时网页直播 (Live Stream)**: 利用 MJPEG 技术，将网页动态（如时钟、K线图、进度条）转为视频流，无需插件直接在浏览器播放。
  * **🛡️ 安全鉴权机制 (Token)**: 内置 API Token 验证，防止接口被滥用。
  * **🔒 SSRF 防御**: 自动拦截对内网 IP (127.0.0.1, 192.168.x) 的请求，保护服务器安全。
  * **🛠️ 交互式管理脚本**: 提供 `ss` 快捷命令，支持一键安装、升级、重置 Token、查看实时日志。
  * **📉 资源智能优化**: 自动管理 Chrome 实例，包含 Swap 内存保护机制，防止小内存 VPS 崩溃。

-----

## 🧠 技术原理 (Architecture)

LiveShot 的核心基于 **Express.js** (Web 服务) 和 **Puppeteer** (浏览器控制)。

1.  **静态截图 (`/screenshot`)**:
      * 用户发起请求 -\> 服务器启动无头浏览器 -\> 加载目标 URL -\> 渲染页面 -\> 截图 -\> 输出 JPEG 图片流 -\> 释放资源。
2.  **实时直播 (`/live`)**:
      * 利用 **MJPEG (Motion JPEG)** 协议及 `multipart/x-mixed-replace` 响应头。
      * 服务器与客户端建立 HTTP 长连接，在后台循环对页面进行截图，并连续不断地将图片帧推送到前端。
      * 这种方式兼容性极佳，可以在任何支持 `<img>` 标签的地方（包括 GitHub README）播放“视频”。

-----

## 🚀 部署指南 (Deployment)

### 环境要求

  * **系统**: Debian / Ubuntu (推荐 Debian 10+)
  * **内存**: 建议 ≥ 1GB (脚本会自动检测并创建 2GB Swap 虚拟内存)

### 📥 一键安装

使用 root 用户在 VPS 上执行以下命令：

```bash
# 下载并运行安装脚本
wget -O liveshot.sh https://raw.githubusercontent.com/ypkin/LiveShot/refs/heads/main/liveshot.sh && chmod +x liveshot.sh && ./liveshot.sh
```

进入菜单后，选择 **`1. 安装/更新代码`** 即可自动完成环境配置。

### ⌨️ 管理菜单

安装完成后，您可以随时在终端输入快捷键 **`ss`** 唤出管理面板：

```bash
ss
```

面板支持功能：

  * 查看服务运行状态 (CPU/Uptime)
  * 查看/重置 API Token
  * 查看实时请求日志
  * 重启/停止/卸载服务

-----

## 🔌 API 文档 (Usage)

假设您的服务器 IP 为 `1.2.3.4`，端口为 `3000` (建议配置反向代理使用域名)。

> **⚠️ 注意**: 所有请求必须包含 `token` 参数，否则返回 403 Forbidden。

### 1\. 获取静态截图

**Endpoint:** `GET /screenshot`

| 参数 | 类型 | 必填 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `url` | string | **是** | - | 目标网页地址 (需包含 http/https) |
| `token` | string | **是** | - | 您的 API 密钥 |
| `width` | int | 否 | 1920 | 视窗宽度 |
| `height` | int | 否 | 1080 | 视窗高度 |
| `full` | bool | 否 | false | 是否截取完整长图 (`true`/`false`) |

**示例:**

```bash
https://your-domain.com/screenshot?url=https://www.google.com&token=YOUR_TOKEN&width=1280
```

### 2\. 获取实时直播流

**Endpoint:** `GET /live`

| 参数 | 类型 | 必填 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `url` | string | **是** | - | 目标网页地址 |
| `token` | string | **是** | - | 您的 API 密钥 |
| `width` | int | 否 | 1280 | 视窗宽度 |
| `height` | int | 否 | 720 | 视窗高度 |

**示例:**

```bash
https://your-domain.com/live?url=https://time.is&token=YOUR_TOKEN
```

-----

## 🎨 集成示例 (Integration)

### 在 GitHub README 中使用

> **注意**: GitHub 强制使用 HTTPS。如果您的 API 是 HTTP，图片将无法显示。请使用 Caddy/Nginx 配置反向代理 SSL。

**Markdown 代码:**

```markdown
![Server Status](https://your-domain.com/live?url=https://status.your-server.com&token=YOUR_TOKEN)
```

### 在 HTML / 个人网站中使用

**HTML 代码:**

```html
<div style="border: 2px solid #333; border-radius: 8px; overflow: hidden;">
    <img src="https://your-domain.com/live?url=https://time.is&token=YOUR_TOKEN" width="100%" alt="Live Stream" />
</div>
```

-----

## ⚙️ 进阶配置: HTTPS 反向代理

为了在 GitHub 上正常显示，建议使用 **Caddy** 进行反向代理并自动申请 SSL 证书。

**Caddyfile 示例:**

```caddy
shot.your-domain.com {
    reverse_proxy localhost:3000
    encode gzip
}
```

配置完成后，即可使用 `https://shot.your-domain.com/...` 进行调用。

-----

## ❓ 常见问题 (FAQ)

**Q: 为什么服务运行一段时间后自动停止？**
A: 通常是因为 VPS 内存不足。请确保您使用了脚本内置的 Swap 创建功能（脚本会自动判断）。如果问题依旧，请在 PM2 中限制内存重启阈值。

**Q: 中文网页显示乱码或方块？**
A: 脚本已自动安装 `fonts-noto-cjk` 字体包。如果仍乱码，尝试重启服务：`ss` -\> `3. 重启服务`。

**Q: Token 泄露了怎么办？**
A: 运行 `ss` 命令，选择 **`2. 修改/重置 Token`**，系统会立即生成新 Token 并重启服务，旧 Token 将失效。

-----

## 📄 License

MIT License


-----


MIT License
