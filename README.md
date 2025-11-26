-----

# 📸 LiveShot - 网页实时截图与直播 API

**LiveShot** 是一个基于 **Node.js** 和 **Puppeteer** (Headless Chrome) 的轻量级服务，可以将任何 VPS 瞬间变身为强大的截图 API。

它不仅支持生成**高精度的网页静态截图**，还支持通过 **MJPEG 流**技术将网页变化以视频形式**实时直播**。非常适合用于服务器探针监控、网页状态展示或动态 README 生成。

## ✨ 功能特性

  * **⚡ 毫秒级截图**：快速获取网页快照，支持长截图 (`fullPage`)。
  * **🎥 实时直播 (Live Stream)**：通过 MJPEG 流实时观看网页动态（如秒杀页面、股市、时间变化）。
  * **📱 多端适配**：支持自定义视窗大小 (`width` / `height`)，可模拟手机或桌面视图。
  * **🛠️ 一键管理脚本**：内置全功能 Bash 管理脚本，支持自动安装依赖、自动配置 Swap 内存保护、服务守护。
  * **🛡️ 资源优化**：自动管理 Chrome 实例，空闲时释放资源，防止 VPS 崩溃。

## 🧠 工作原理

1.  **核心架构**：使用 Express.js 搭建 HTTP 服务，后端调用 Puppeteer 控制无头浏览器 (Headless Chrome)。
2.  **静态截图**：接收 URL 请求 -\> 启动浏览器页签 -\> 渲染页面 -\> 截图 -\> 返回 JPEG 流 -\> 关闭页签。
3.  **实时直播**：利用 **MJPEG (Motion JPEG)** 技术。建立 HTTP 长连接，服务器连续不断地对页面进行截图并推送到客户端。这种方式无需客户端安装任何插件，可以在标准 `<img src="...">` 标签中直接播放视频流。

## 🚀 部署指南

### 环境要求

  * **OS**: Debian / Ubuntu (推荐 Debian 11/12)
  * **RAM**: 建议 ≥ 1GB (脚本会自动检测并创建 2GB Swap 虚拟内存以防止 OOM)

### 📥 一键安装

1.  下载并运行管理脚本：

    ```bash
    # 下载脚本 (假设您已将脚本保存为 liveshot.sh)
    wget -O liveshot.sh https://raw.githubusercontent.com/您的用户名/仓库名/main/liveshot.sh

    # 或者直接在服务器新建文件粘贴代码
    nano liveshot
    # (粘贴代码后保存)

    # 赋予权限并启动
    chmod +x liveshot
    ./liveshot
    ```

2.  在菜单中选择 **`1. 安装/重装服务`**。

      * 脚本会自动安装 Node.js、中文字体 (Noto CJK)、Chrome 依赖库。
      * 安装完成后，会提示设置快捷键 **`ss`**。

### ⌨️ 管理命令

安装完成后，您可以直接在终端输入快捷键唤出管理面板：

```bash
ss
```

  * 支持：启动、停止、重启、查看实时日志、卸载等操作。

-----

## 🔌 API 使用文档

假设您的服务器 IP 为 `1.2.3.4`，端口为 `3000`。
*(建议配置 Nginx/Caddy 反向代理并开启 HTTPS，以便在 GitHub 中使用)*

### 1\. 获取静态截图 (`/screenshot`)

| 参数 | 类型 | 必填 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `url` | string | **是** | - | 目标网页地址 (需包含 http/https) |
| `width` | int | 否 | 1920 | 视窗宽度 |
| `height` | int | 否 | 1080 | 视窗高度 |
| `full` | bool | 否 | false | 是否截取完整长图 (`true`/`false`) |

**示例：**

```http
GET https://your-domain.com/screenshot?url=https://www.google.com&width=1280&height=720
```

### 2\. 获取实时直播流 (`/live`)

| 参数 | 类型 | 必填 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| `url` | string | **是** | - | 目标网页地址 |
| `width` | int | 否 | 1280 | 视窗宽度 |
| `height` | int | 否 | 720 | 视窗高度 |

**示例：**

```http
GET https://your-domain.com/live?url=https://time.is
```

-----

## 🎨 集成示例 (GitHub / HTML)

### 在 GitHub README.md 中使用

> **⚠️ 注意**：GitHub 会缓存图片 (Camo)。如果需要显示实时状态，建议使用静态截图接口，或在 URL 后添加随机时间戳（如果平台支持）。
> 另外，必须使用 **HTTPS** 域名，否则图片会被浏览器拦截。

**Markdown 格式：**

```markdown
![Server Status](https://your-domain.com/screenshot?url=https://status.your-server.com)
```

### 在 HTML / 个人博客中使用

**实时直播效果 (MJPEG)：**
这段代码会在网页上显示一个实时动态的窗口。

```html
<img src="https://your-domain.com/live?url=https://time.is" width="100%" alt="Live Stream" />
```

-----



## ❓ 常见问题

**Q: 为什么服务启动后自动停止？**
A: 绝大多数是因为内存不足。Chrome 非常吃内存。请使用 `ss` 命令进入菜单，确保脚本已自动为您创建了 Swap 虚拟内存。

**Q: 中文网页显示乱码/方块？**
A: 脚本已内置安装 `fonts-noto-cjk`。如果仍乱码，请尝试重启服务：`ss` -\> `5. 重启服务`。

**Q: GitHub README 图片不显示？**
A: 1. 确保您的 API 使用了 **HTTPS** 域名。2. 检查服务器防火墙是否放行了 3000 端口 (或反代端口)。

## 📄 License

MIT License
