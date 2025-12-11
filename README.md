

# LiveShot (v4.1) 📸

**轻量级 Puppeteer 截图与网页直播 API 服务**

专为 Linux VPS 设计的高性能网页渲染工具。支持通过 API 获取网页截图或实时 MJPEG 直播流，**支持 Nginx 反代隐藏 Token**。

## 🚀 快速部署

一键安装脚本（支持 Debian/Ubuntu）：

```bash
wget -O liveshot.sh https://raw.githubusercontent.com/ypkin/LiveShot/refs/heads/main/liveshot.sh && chmod +x liveshot.sh && ./liveshot.sh
```

*安装后输入 `lvs` 呼出管理菜单。*

## 🛡️ Nginx 安全隐蔽配置 (推荐)

通过 Nginx 反向代理将 `Token` 和 `目标URL` 写死在配置中，生成**不含敏感参数**的公开链接。

**公开访问地址示例：**

  * **直播流**: `https://your-domain.com/gh-live` (适合嵌入网页/OBS)
  * **静态图**: `https://your-domain.com/gh-shot` (适合 GitHub README)

**Nginx 配置示例 (`server` 块内)：**

```nginx
server {
    listen 80;
    listen 443 ssl;
    server_name your-domain.com; # 修改为你的域名
    
    # SSL 证书配置...
    
    # 1. 安全直播路由 (隐藏 Token)
    location = /gh-live {
        # ▼ 在此处修改目标 URL 和 Token
        set $args "url=https://time.is&token=YOUR_TOKEN";
        
        proxy_pass http://127.0.0.1:6000/live; # 假设后端在本地 6000 端口
        proxy_set_header Host $host;
        
        # 关键：关闭缓冲以支持流媒体
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }

    # 2. 安全截图路由 (隐藏 Token)
    location = /gh-shot {
        # ▼ 在此处修改目标 URL、Token 和分辨率
        set $args "url=https://google.com&token=YOUR_TOKEN&width=1280&height=720";
        
        proxy_pass http://127.0.0.1:6000/screenshot;
        proxy_set_header Host $host;
    }

    # 3. 原生接口 (需要手动带参数)
    location / {
        proxy_pass http://127.0.0.1:6000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 🔗 原生 API 文档

如果不使用 Nginx 隐藏，可直接通过端口访问：

| 功能 | 路径 | 参数 | 示例 |
| :--- | :--- | :--- | :--- |
| **截图** | `/screenshot` | `url`, `token`, `full` | `http://ip:6000/screenshot?url=...&token=...` |
| **直播** | `/live` | `url`, `token` | `http://ip:6000/live?url=...&token=...` |

## ✨ 特性

  * **极低占用**: 零轮询开销，PM2 智能内存守护。
  * **安全鉴权**: Token 验证 + 自动屏蔽内网 IP 请求。
  * **快捷管理**: 提供 `lvs` 终端指令，支持重置 Token 和 彻底卸载。
