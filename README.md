# LiveShot (v4.25) 📸

**轻量级 Puppeteer 截图与网页直播 API 服务**

专为 Linux VPS 设计的高性能网页渲染工具。通过 API 获取网页截图或实时直播流，**支持 Nginx 反代隐藏 Token**，公开链接干净无参数。

## ✨ 特性

- **截图秒开**：`/gh-shot` 默认尺寸有 60 秒内内存缓存帧直接发，不现截（3–5s → 约 0.4s）；缓存过期时读盘上 1 小时内的 `last-frame.jpg` 兜底。
- **直播常驻制片方**：启动即开目标页，没人看也不关；新观众首帧即直播帧（约 0.5s），不用等冷启动；挂了 5 秒后自动重开。
- **直播帧率 2 秒**：截图间隔 2 秒（跟页面数据推送节奏一致），地图重绘节流同步到 2 秒。
- **缓冲占位图**：直播无帧时先发一张「服务器列表正在加载」占位图（1280×1240），观众不等黑屏。
- **随机换主题**：7 套主题（冰蓝 / 绯红 / 翡翠 / 琥珀 / 暮紫 / 霓虹 / 碳黑）每次新开页随机抽、必与上次不同，首次默认冰蓝。
- **时间标签**：截图页地图下方注入时间标签，透明背景、靠左、颜色同主题、36px，北京时间带秒（`YYYY-MM-DD HH:MM:SS`），每秒更新；制片方重载后重新注入。
- **防内存泄漏**：制片方页面每 6 小时重载一次，清空 JS 堆与 DOM，客户端不断线；每 10 帧强制 GC；Chromium JS 堆上限 256M；pm2 内存超 1024M 自动重启。
- **安全鉴权**：Token 验证 + SSRF 加固（自动屏蔽内网 IP 请求）；仅监听 127.0.0.1，对外走 Nginx 反代。
- **极低占用**：单浏览器共享制，同一目标只开一个页面、所有观众共用它的帧；页面动画冻结、地图节流，空闲时几乎不耗 CPU。
- **快捷管理**：提供 `lvs` 终端指令，支持查看状态、重置 Token 和彻底卸载。

## 🚀 快速部署

一键安装脚本（支持 Debian / Ubuntu / Alpine）：

```bash
wget -O liveshot.sh https://raw.githubusercontent.com/ypkin/LiveShot/refs/heads/main/liveshot.sh && chmod +x liveshot.sh && ./liveshot.sh
```

安装 Node 22 + Puppeteer 24 + Express + Chromium，服务由 pm2 托管（进程名 `screenshot-api`），只监听 `127.0.0.1:6000`。

*安装后输入 `lvs` 呼出管理菜单。*

## 🛡️ Nginx 反代配置（推荐）

通过 Nginx 反向代理将 `Token` 和目标 URL 写死在配置中，生成**不含敏感参数**的公开链接。

**公开访问地址示例：**

- **直播流**：`https://your-domain.com/gh-live`（适合嵌入网页 / OBS）
- **静态图**：`https://your-domain.com/gh-shot`（适合 GitHub README）

**Nginx 配置示例（`server` 块内）：**

```nginx
server {
    listen 80;
    listen 443 ssl;
    server_name your-domain.com; # 修改为你的域名

    # SSL 证书配置...

    # 1. 安全直播路由（隐藏 Token）
    location = /gh-live {
        # ▼ 在此处修改目标 URL 和 Token
        set $args "url=https://example.com&token=YOUR_TOKEN";

        proxy_pass http://127.0.0.1:6000/gh-live;
        proxy_set_header Host $host;

        # 关键：关闭缓冲以支持流媒体
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }

    # 2. 安全截图路由（隐藏 Token）
    location = /gh-shot {
        # ▼ 在此处修改目标 URL、Token 和分辨率
        set $args "url=https://example.com&token=YOUR_TOKEN&width=1280&height=1240";

        proxy_pass http://127.0.0.1:6000/gh-shot;
        proxy_set_header Host $host;
    }

    # 3. 原生接口（需要手动带参数）
    location / {
        proxy_pass http://127.0.0.1:6000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### 可选：屏蔽爬虫

机器人会把无限直播流当图片死命下载，浪费流量。在 `http` 块加 UA 判断，`/gh-live` 与 `/gh-shot` 对机器人直接返回 403：

```nginx
map $http_user_agent $is_bot {
    default 0;
    ~*Googlebot|bingbot|Baiduspider|YandexBot|Applebot|ChatGPT|ClaudeBot|MetaAI 1;
}

# 在 /gh-live 与 /gh-shot 内加：
# if ($is_bot) { return 403; }
```

### 可选：屏蔽指定地区 IP

用 `geo` 模块按 IP 段返回 403，例如屏蔽中国大陆 IP：

```nginx
geo $is_cn {
    default 0;
    include /etc/nginx/cn-geo.conf; # 中国大陆 IPv4 + IPv6 段列表
}

# 在 /gh-live、/gh-shot、/ 内加：
# if ($is_cn) { return 403; }
```

## 🔗 API 文档

服务只监听 `127.0.0.1:6000`，对外请走 Nginx 反代。两个接口均需 `token` 鉴权。

| 功能 | 路径 | 参数 | 说明 |
| :--- | :--- | :--- | :--- |
| **截图** | `/gh-shot` | `url`, `token`, `width`, `height`, `full` | 默认 1280×1240；`full=true` 为整页截图；默认尺寸有缓存秒开 |
| **直播** | `/gh-live` | `url`, `token` | `multipart/x-mixed-replace` 流，2 秒一帧；无帧时先发缓冲占位图 |

示例：

```bash
# 截图
curl "http://127.0.0.1:6000/gh-shot?url=https://example.com&token=YOUR_TOKEN" -o shot.jpg

# 直播（浏览器直接打开即可）
http://127.0.0.1:6000/gh-live?url=https://example.com&token=YOUR_TOKEN
```

## 🛠️ 管理

```bash
lvs   # 呼出管理菜单：查看状态 / 重置 Token / 彻底卸载
```

- 配置文件：安装目录下的 `config.json`（存 Token）。
- 服务管理：`pm2 restart screenshot-api` / `pm2 logs screenshot-api`。
- 直播每 10 帧自动把最新帧写盘 `last-frame.jpg`，重启后也能先出静态图。

## 📋 更新日志（节选）

- **v4.25** 时间标签字号 36px
- **v4.24** 直播帧率 4 秒 → 2 秒，地图重绘节流同步到 2 秒
- **v4.22** 时间标签加上年月日（`YYYY-MM-DD HH:MM:SS`）
- **v4.21** 时间标签靠左、颜色同主题、字号 20px
- **v4.20** 地图下方加时间标签（透明背景，北京时间带秒）
- **v4.19** 制片方页面每 6 小时重载一次，防内存泄漏
- **v4.18** 制片方永久常驻，新观众首帧约 0.5 秒
- **v4.17** 直播无帧时每次都先发缓冲动画
- **v4.16** `/gh-shot` 缓存过期时读盘上 `last-frame.jpg` 兜底
- **v4.15** `/gh-shot` 默认尺寸 60 秒内缓存帧直接发
- **v4.13** 直播每 10 帧写盘 `last-frame.jpg`
- **v4.12** 直播首帧前先发缓冲占位图
- **v4.8** 跨会话帧缓存 + 空闲关浏览器 30s → 120s
- **v4.7** 每 10 帧 GC；JS 堆 512M → 256M
- **v4.6** 接口改名 `/screenshot` → `/gh-shot`，`/live` → `/gh-live`；Token 改 Cookie；仅监听 127.0.0.1
