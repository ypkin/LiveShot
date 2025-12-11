#!/bin/bash

# =========================================================
# LiveShot v4.1 - 极致轻量版 (Low CPU & RAM)
# 功能：Puppeteer 截图/直播 | 特性：自定义Token、防劫持、零轮询开销
# =========================================================

# --- 配置区域 ---
APP_NAME="screenshot-api"
PROJECT_DIR="/opt/screenshot-api"
SCRIPT_PATH=$(readlink -f "$0")
SHORTCUT_NAME="lvs"  # 快捷键改为 lvs，严禁使用 ss
CONFIG_FILE="$PROJECT_DIR/config.json"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 核心：自动修复系统劫持 (Fix High CPU) ---
# 检测是否存在恶意的 ss 软链接，如果有，立即删除
if [ -L "/usr/local/bin/ss" ]; then
    LINK_TARGET=$(readlink /usr/local/bin/ss)
    if [[ "$LINK_TARGET" == *"$APP_NAME"* ]] || [[ "$LINK_TARGET" == *"$SCRIPT_PATH"* ]] || [[ "$LINK_TARGET" == *"liveshot"* ]]; then
        rm -f /usr/local/bin/ss
        echo -e "${GREEN}[安全修复] 已删除恶意的 ss 命令劫持，系统网络命令已恢复正常。${NC}"
    fi
fi

# 检查 Root
check_root() {
    [ "$EUID" -ne 0 ] && echo -e "${RED}错误: 请使用 root 权限运行。${NC}" && exit 1
}

# 创建快捷键
create_shortcut() {
    rm -f "/usr/local/bin/$SHORTCUT_NAME"
    ln -sf "$SCRIPT_PATH" "/usr/local/bin/$SHORTCUT_NAME"
    chmod +x "/usr/local/bin/$SHORTCUT_NAME"
}

# 格式化时间 (Bash 纯算，不调用 Node)
format_uptime() {
    local T=$1
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    [[ $D > 0 ]] && printf '%d天 ' $D
    [[ $H > 0 ]] && printf '%d小时 ' $H
    [[ $M > 0 ]] && printf '%d分 ' $M
    printf '%d秒' $S
}

# 获取状态 (极速版：使用 grep/awk，CPU 占用近乎 0)
get_status_info() {
    STATUS_COLOR="${RED}Stopped${NC}"
    UPTIME_TEXT="0s"
    LAST_LOG="无记录"
    
    # 读取 Token
    if [ -f "$CONFIG_FILE" ]; then
        CURRENT_TOKEN=$(grep -oP '(?<="token": ")[^"]*' "$CONFIG_FILE")
    else
        CURRENT_TOKEN="未安装"
    fi

    # 检查 PM2 状态
    if command -v pm2 &> /dev/null; then
        # 检查进程是否在列表
        if pm2 jlist 2>/dev/null | grep -q "\"name\":\"$APP_NAME\""; then
            # 获取状态
            local pm2_out=$(pm2 jlist)
            local raw_status=$(echo "$pm2_out" | grep -oP "\"name\":\"$APP_NAME\".*?\"status\":\"\K[^\"]+")
            local uptime_ts=$(echo "$pm2_out" | grep -oP "\"name\":\"$APP_NAME\".*?\"pm_uptime\":\K[0-9]+")

            if [ "$raw_status" == "online" ]; then
                STATUS_COLOR="${GREEN}Running${NC}"
                # 计算运行时间
                local now=$(date +%s%3N 2>/dev/null)
                # 兼容不支持 %3N 的 date 版本
                if [[ "$now" == *N ]]; then now=$(($(date +%s)*1000)); fi
                local diff=$(( (now - uptime_ts) / 1000 ))
                UPTIME_TEXT=$(format_uptime $diff)
            else
                STATUS_COLOR="${RED}$raw_status${NC}"
            fi

            # 获取最后一条日志
            local log=$(pm2 logs "$APP_NAME" --lines 5 --nostream --raw 2>/dev/null | grep -E "\[Shot\]|\[Live\]" | tail -n 1)
            [ ! -z "$log" ] && LAST_LOG=$(echo "$log" | cut -c 1-50)
        fi
    fi
}

# 1. 安装服务 (依赖最小化)
install_service() {
    echo -e "${BLUE}>>> 开始部署 LiveShot (轻量版)...${NC}"
    
    # 安装基础依赖 (不安装推荐包，减少体积)
    apt-get update -y
    apt-get install -y --no-install-recommends curl wget gnupg2 ca-certificates lsb-release

    # 检查并设置 Swap (防止内存不足崩溃)
    PHY_MEM=$(free -m | grep Mem | awk '{print $2}')
    if [ "$PHY_MEM" -lt 1500 ] && [ ! -f /swapfile ]; then
        echo -e "${YELLOW}内存较小，创建 1G Swap 交换分区...${NC}"
        fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # 安装 Node.js (如果不存在)
    if ! command -v node &> /dev/null; then
        echo -e "${YELLOW}安装 Node.js 20...${NC}"
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # 安装 Chrome 运行库 (Puppeteer 必需，无法精简)
    echo -e "${YELLOW}安装 Chromium 依赖库...${NC}"
    apt-get install -y --no-install-recommends \
    fonts-noto-cjk fonts-noto-color-emoji \
    libasound2 libatk-bridge2.0-0 libatk1.0-0 libc6 libcairo2 libcups2 \
    libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libgcc1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
    libstdc++6 libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
    libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 \
    libxss1 libxtst6 xdg-utils

    # 准备项目目录
    mkdir -p "$PROJECT_DIR" && cd "$PROJECT_DIR"
    [ ! -f "package.json" ] && npm init -y >/dev/null

    # 配置国内源加速
    npm config set registry https://registry.npmmirror.com
    export PUPPETEER_DOWNLOAD_HOST=https://npmmirror.com/mirrors
    
    echo -e "${YELLOW}安装核心组件...${NC}"
    # --no-audit --no-fund 加快安装，减少日志
    npm install express@4.18.2 puppeteer@21.5.0 --no-audit --no-fund

    # 生成 Token
    if [ -f "$CONFIG_FILE" ]; then
        TOKEN=$(grep -oP '(?<="token": ")[^"]*' "$CONFIG_FILE")
    else
        TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
        echo "{\"token\": \"$TOKEN\"}" > "$CONFIG_FILE"
    fi

    # 写入优化后的 Node 代码
    cat << 'EOF' > index.js
const express = require('express');
const puppeteer = require('puppeteer');
const fs = require('fs');
const app = express();
const port = 6000;
const config = JSON.parse(fs.readFileSync('./config.json', 'utf8'));

let browser;
// 浏览器懒加载与保活
async function getBrowser() {
    if (browser && browser.isConnected()) return browser;
    browser = await puppeteer.launch({
        headless: 'new',
        args: [
            '--no-sandbox', '--disable-setuid-sandbox', 
            '--disable-dev-shm-usage', '--disable-gpu', 
            '--no-first-run', '--disable-extensions'
        ]
    });
    return browser;
}

const auth = (req, res, next) => {
    if (req.query.token !== config.token) return res.status(403).send('Invalid Token');
    const url = req.query.url || '';
    if (url.match(/localhost|127\.0\.0\.1|192\.168\.|::1/)) return res.status(403).send('Block Private IP');
    next();
};

app.get('/screenshot', auth, async (req, res) => {
    const { url, width, height, full } = req.query;
    console.log(`[Shot] ${url}`);
    let page = null;
    try {
        const b = await getBrowser();
        page = await b.newPage();
        await page.setViewport({ width: parseInt(width)||1920, height: parseInt(height)||1080 });
        await page.goto(url.startsWith('http')?url:`http://${url}`, { waitUntil: 'networkidle2', timeout: 25000 });
        const img = await page.screenshot({ type: 'jpeg', quality: 85, fullPage: full==='true' });
        res.set('Content-Type', 'image/jpeg');
        res.send(img);
    } catch (e) { res.status(500).send(e.message); } 
    finally { if (page) await page.close(); }
});

app.get('/live', auth, async (req, res) => {
    const { url } = req.query;
    console.log(`[Live] ${url}`);
    let page = null, isClosed = false;
    res.writeHead(200, { 'Content-Type': 'multipart/x-mixed-replace; boundary=frame' });
    try {
        const b = await getBrowser();
        page = await b.newPage();
        await page.setViewport({ width: 1280, height: 720 });
        await page.goto(url.startsWith('http')?url:`http://${url}`, { waitUntil: 'domcontentloaded', timeout: 15000 });
        req.on('close', () => { isClosed = true; });
        while (!isClosed && !page.isClosed()) {
            const buf = await page.screenshot({ type: 'jpeg', quality: 80 });
            res.write(`--frame\r\nContent-Type: image/jpeg\r\n\r\n`);
            res.write(buf);
            res.write(`\r\n`);
            await new Promise(r => setTimeout(r, 500)); // 降低帧率以节省CPU
        }
    } catch (e) { if (!isClosed) res.end(); } 
    finally { if (page && !page.isClosed()) await page.close(); }
});

app.listen(port, () => console.log(`Ready on ${port}`));
EOF

    # 安装 PM2 并启动 (限制内存 500M)
    echo -e "${YELLOW}配置 PM2 进程守护...${NC}"
    npm install -g pm2
    pm2 delete "$APP_NAME" 2>/dev/null
    # 关键优化：限制内存，防止内存泄漏导致死机
    pm2 start index.js --name "$APP_NAME" --max-memory-restart 500M --log-date-format "YYYY-MM-DD HH:mm:ss"
    pm2 save
    pm2 startup | bash &>/dev/null
    
    create_shortcut
    echo -e "${GREEN}安装完成! 你的 Token: ${YELLOW}$TOKEN${NC}"
    echo -e "${GREEN}快捷键: lvs${NC}"
    read -p "按回车继续..."
}

# 彻底卸载 (包含 Node/PM2/依赖)
uninstall_service_full() {
    echo -e "${RED}⚠️  警告: 这将执行彻底卸载！${NC}"
    echo -e "将删除: 项目文件、PM2、Node.js、NPM缓存及所有自动安装的依赖库。"
    read -p "确定要继续吗? (输入 y 确认): " confirm
    if [ "$confirm" == "y" ]; then
        echo -e "${YELLOW}停止服务...${NC}"
        pm2 kill 2>/dev/null
        pm2 unstartup systemd 2>/dev/null

        echo -e "${YELLOW}卸载 PM2 和全局包...${NC}"
        npm uninstall -g pm2
        rm -rf /root/.pm2 /root/.npm /usr/lib/node_modules /usr/local/lib/node_modules

        echo -e "${YELLOW}卸载 Node.js 及系统依赖...${NC}"
        apt-get purge -y nodejs npm
        # 自动清理不再被需要的库 (这将清除 Puppeteer 安装的那些库，如果其他软件不用的话)
        apt-get autoremove -y 

        echo -e "${YELLOW}删除项目文件和快捷键...${NC}"
        rm -rf "$PROJECT_DIR"
        rm -f "/usr/local/bin/$SHORTCUT_NAME"
        rm -f "/usr/local/bin/ss" # 再次确认删除那个恶意链接

        echo -e "${GREEN}✅ 系统已清理干净。${NC}"
    else
        echo "已取消。"
    fi
    read -p "按回车继续..."
}

# 简单管理功能
start_service() { pm2 start "$APP_NAME" 2>/dev/null || echo "未安装"; pm2 save; read -p "Done."; }
stop_service() { pm2 stop "$APP_NAME"; read -p "Done."; }
restart_service() { pm2 restart "$APP_NAME"; read -p "Done."; }
view_logs() { pm2 logs "$APP_NAME" --lines 50 --nostream; read -n 1 -s -r -p "Press any key..."; }

# [修改] 支持用户手动输入 Token
reset_token() {
    echo -e "${YELLOW}请输入新的 Token (直接回车将随机生成):${NC}"
    read -p "> " USER_INPUT
    
    if [ -n "$USER_INPUT" ]; then
        NEW_TOKEN="$USER_INPUT"
    else
        NEW_TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    fi
    
    mkdir -p "$PROJECT_DIR"
    echo "{\"token\": \"$NEW_TOKEN\"}" > "$CONFIG_FILE"
    pm2 restart "$APP_NAME" 2>/dev/null
    echo -e "${GREEN}Token 已更新为: $NEW_TOKEN${NC}"
    echo -e "服务已重启生效。"
    read -p "按回车继续..."
}

# 主菜单
show_menu() {
    check_root
    create_shortcut
    while true; do
        get_status_info
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}   LiveShot v4.1 (极速版) [Cmd: $SHORTCUT_NAME]${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo -e " 状态: $STATUS_COLOR | 运行: $UPTIME_TEXT"
        echo -e " Token: ${YELLOW}${CURRENT_TOKEN}${NC}"
        echo -e " 监控: ${BLUE}$LAST_LOG${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        echo -e " 1. 安装/重装服务 (低占用配置)"
        echo -e " 2. 启动服务"
        echo -e " 3. 停止服务"
        echo -e " 4. 重启服务"
        echo -e " 5. 查看日志"
        echo -e " 6. 修改/重置 Token"
        echo -e "${RED} 7. 彻底卸载 (含 Node/PM2/依赖)${NC}"
        echo -e " 0. 退出"
        echo -e ""
        read -p " 选择: " op
        case $op in
            1) install_service ;;
            2) start_service ;;
            3) stop_service ;;
            4) restart_service ;;
            5) view_logs ;;
            6) reset_token ;;
            7) uninstall_service_full ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

show_menu
