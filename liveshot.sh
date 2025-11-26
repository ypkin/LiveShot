#!/bin/bash

# =========================================================
# LiveShot - Puppeteer 截图与直播服务管理脚本
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
SKYBLUE='\033[0;36m'
PURPLE='\033[0;35m'
GREY='\033[0;37m'
NC='\033[0m'

# 项目配置
APP_NAME="screenshot-api"
PROJECT_DIR="/opt/screenshot-api"
SCRIPT_PATH=$(readlink -f "$0")
SHORTCUT_NAME="ss" # 快捷键名称

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本。${NC}"
        exit 1
    fi
}

# 创建全局快捷键
create_shortcut() {
    if [ -f "$SCRIPT_PATH" ]; then
        rm -f /usr/local/bin/liveshot
        rm -f /usr/local/bin/lvs
        
        # 创建新的快捷键
        ln -sf "$SCRIPT_PATH" /usr/local/bin/$SHORTCUT_NAME
        chmod +x /usr/local/bin/$SHORTCUT_NAME
    fi
}

# 格式化时间
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

# 获取服务状态信息
get_status_info() {
    STATUS_COLOR="${RED}Stopped${NC}"
    UPTIME_TEXT="0s"
    LAST_LOG="无记录"

    if command -v pm2 &> /dev/null; then
        DATA=$(pm2 jlist | node -e "
            try {
                const fs = require('fs');
                const list = JSON.parse(fs.readFileSync(0, 'utf-8'));
                const app = list.find(x => x.name === '$APP_NAME');
                if (app) {
                    const status = app.pm2_env.status;
                    const uptime = Math.floor((Date.now() - app.pm2_env.pm_uptime) / 1000);
                    console.log(status + '|' + uptime);
                } else { console.log('null'); }
            } catch (e) { console.log('error'); }
        ")

        if [[ "$DATA" != "null" && "$DATA" != "error" ]]; then
            IFS='|' read -r RAW_STATUS RAW_UPTIME <<< "$DATA"
            
            if [ "$RAW_STATUS" == "online" ]; then
                STATUS_COLOR="${GREEN}Running${NC}"
            else
                STATUS_COLOR="${RED}$RAW_STATUS${NC}"
            fi

            UPTIME_TEXT=$(format_uptime $RAW_UPTIME)

            LOG_LINE=$(pm2 logs $APP_NAME --lines 5 --nostream --raw 2>/dev/null | grep -E "\[Shot\]|\[Live\]" | tail -n 1)
            if [ ! -z "$LOG_LINE" ]; then
                LAST_LOG=$(echo "$LOG_LINE" | cut -c 1-55)
            fi
        fi
    fi
}

# 1. 安装服务
install_service() {
    echo -e "${SKYBLUE}>>> 正在开始安装 LiveShot 服务...${NC}"
    
    apt update -y >/dev/null 2>&1
    apt install -y curl wget gnupg2 ca-certificates lsb-release >/dev/null 2>&1

    PHY_MEM=$(free -m | grep Mem | awk '{print $2}')
    if [ "$PHY_MEM" -lt 2000 ]; then
        if [ ! -f /swapfile ]; then
            echo -e "${YELLOW}检测到内存 < 2GB，正在创建 Swap...${NC}"
            fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
        fi
    fi

    apt install -y fonts-noto-cjk fonts-noto-color-emoji >/dev/null 2>&1
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
        apt install -y nodejs >/dev/null 2>&1
    fi

    echo -e "${YELLOW}正在安装 Chrome 依赖库...${NC}"
    apt install -y libasound2 libatk-bridge2.0-0 libatk1.0-0 libc6 libcairo2 libcups2 \
    libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libgcc1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
    libstdc++6 libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
    libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 \
    libxss1 libxtst6 xdg-utils >/dev/null 2>&1

    mkdir -p $PROJECT_DIR && cd $PROJECT_DIR
    [ ! -f "package.json" ] && npm init -y >/dev/null 2>&1
    npm install express@4.18.2 puppeteer@21.5.0 >/dev/null 2>&1

    cat << 'EOF' > index.js
const express = require('express');
const puppeteer = require('puppeteer');
const app = express();
const port = 3000;
let browser;
async function initBrowser() {
    if (browser && browser.isConnected()) return;
    browser = await puppeteer.launch({
        headless: 'new',
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--no-first-run', '--single-process']
    });
}
initBrowser();
app.get('/', (req, res) => res.send('<h1>LiveShot Service Ready</h1>'));
app.get('/screenshot', async (req, res) => {
    const { url, width, height, full } = req.query;
    if (!url) return res.status(400).send('Missing url');
    console.log(`[Shot] ${url}`);
    let page = null;
    try {
        await initBrowser();
        page = await browser.newPage();
        await page.setViewport({ width: parseInt(width)||1920, height: parseInt(height)||1080 });
        await page.goto(url.startsWith('http')?url:`http://${url}`, { waitUntil: 'networkidle2', timeout: 30000 });
        const img = await page.screenshot({ type: 'jpeg', quality: 80, fullPage: full==='true' });
        res.set('Content-Type', 'image/jpeg');
        res.send(img);
    } catch (e) { res.status(500).send(e.message); } 
    finally { if (page) await page.close(); }
});
app.get('/live', async (req, res) => {
    const { url, width, height } = req.query;
    if (!url) return res.status(400).send('Missing url');
    console.log(`[Live] ${url}`);
    let page = null;
    let isClosed = false;
    res.writeHead(200, { 'Content-Type': 'multipart/x-mixed-replace; boundary=frame' });
    try {
        await initBrowser();
        page = await browser.newPage();
        await page.setViewport({ width: parseInt(width)||1280, height: parseInt(height)||720 });
        await page.goto(url.startsWith('http')?url:`http://${url}`, { waitUntil: 'domcontentloaded', timeout: 20000 });
        req.on('close', () => { isClosed = true; });
        while (!isClosed) {
            if (page.isClosed()) break;
            const buffer = await page.screenshot({ type: 'jpeg', quality: 50 });
            res.write(`--frame\r\nContent-Type: image/jpeg\r\n\r\n`);
            res.write(buffer);
            res.write(`\r\n`);
            await new Promise(r => setTimeout(r, 200));
        }
    } catch (e) { if (!isClosed) res.end(); } 
    finally { if (page && !page.isClosed()) await page.close(); }
});
app.listen(port, () => console.log(`Service started on ${port}`));
EOF

    npm install -g pm2 >/dev/null 2>&1
    pm2 delete $APP_NAME 2>/dev/null
    pm2 start index.js --name "$APP_NAME" --max-memory-restart 500M
    pm2 save
    pm2 startup | bash &>/dev/null
    create_shortcut
    echo -e "${GREEN}安装完成! 快捷命令已更新为: $SHORTCUT_NAME ${NC}"
    read -p "按回车继续..."
}

# 2. 卸载
uninstall_service() {
    read -p "确认卸载? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        pm2 delete $APP_NAME 2>/dev/null && pm2 save
        rm -rf $PROJECT_DIR
        rm -f /usr/local/bin/$SHORTCUT_NAME
        echo -e "${GREEN}已卸载。${NC}"
    fi
    read -p "按回车继续..."
}

# 控制函数
start_service() { pm2 start $APP_NAME; read -p "Done..."; }
stop_service() { pm2 stop $APP_NAME; read -p "Done..."; }
restart_service() { pm2 restart $APP_NAME; echo "重启完毕"; read -p "Done..."; }

# 查看日志 (非流式，按键返回)
view_logs() {
    clear
    echo -e "${YELLOW}正在读取最近 50 条日志...${NC}"
    echo "------------------------------------------------"
    pm2 logs $APP_NAME --lines 50 --nostream
    echo "------------------------------------------------"
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 主菜单
show_menu() {
    create_shortcut 
    check_root
    while true; do
        get_status_info
        clear
        echo -e "${SKYBLUE}====================================================${NC}"
        echo -e "${SKYBLUE}      LiveShot 管理面板 v2.4 (快捷键: $SHORTCUT_NAME)      ${NC}"
        echo -e "${SKYBLUE}====================================================${NC}"
        echo -e " 状态: $STATUS_COLOR"
        echo -e " 时间: ${PURPLE}$UPTIME_TEXT${NC}"
        echo -e " 监控: ${BLUE}$LAST_LOG${NC}"
        echo -e "${SKYBLUE}----------------------------------------------------${NC}"
        echo -e " ${GREY}截图: https://你的域名/screenshot?url=https://... (监控的网址)${NC}"
        echo -e " ${GREY}直播: https://你的域名/live?url=https://... (监控的网址)${NC}"
        echo -e "${SKYBLUE}----------------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} 安装/重装服务 (修复)"
        echo -e " ${GREEN}2.${NC} 卸载服务"
        echo -e " ${GREEN}3.${NC} 启动服务"
        echo -e " ${GREEN}4.${NC} 停止服务"
        echo -e " ${GREEN}5.${NC} 重启服务"
        echo -e " ${GREEN}6.${NC} 查看日志 (按任意键返回)"
        echo -e " ${GREEN}0.${NC} 退出"
        echo -e ""
        read -p " 请输入选项 [0-6]: " option

        case $option in
            1) install_service ;;
            2) uninstall_service ;;
            3) start_service ;;
            4) stop_service ;;
            5) restart_service ;;
            6) view_logs ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

show_menu
