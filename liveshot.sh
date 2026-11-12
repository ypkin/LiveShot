#!/bin/bash

# =========================================================
# LiveShot v4.27 - 优化版
# 功能：Puppeteer 截图/直播 | 特性：空闲释放、并发限制、定时重启
# 更新日志（新→旧）：
#  v4.27 /gh-live 连续观看超 2 分钟自动断开（省流量）：120 秒后主动结束直播流，观众刷新可再看
#  v4.26 制片方每 6 小时重载时换主题：重载改为整页重建（openPanelPage 抽新主题），不再是 goto
#  v4.25 地图下方时间标签字号加大到 36px
#  v4.24 直播帧率改正常：截图间隔 4 秒→2 秒（跟面板数据推送节奏一致），地图重绘节流同步到 2 秒
#  v4.23 地图下方时间标签字号加大到 28px
#  v4.22 地图下方时间标签加上年月日（YYYY-MM-DD HH:MM:SS）
#  v4.21 地图下方时间标签改靠左、颜色同主题、字号加大到 20px
#  v4.20 地图下方加时间标签：透明背景，北京时间带秒，每秒更新；重载后重新注入
#  v4.19 防内存泄漏：制片方页面每 6 小时重载一次，清空 JS 堆与 DOM，客户端不断线
#  v4.18 制片方永久常驻：启动即开 plain 制片方，没人看也不关，新观众首帧约 0.5 秒；挂了 5 秒后重开
#  v4.17 /gh-live 没直播帧时每次都先发缓冲动画，不再发缓存的静态图
#  v4.16 /gh-shot 内存缓存过期时读盘上 last-frame.jpg（1 小时内）直接发，没人看直播时也能秒开
#  v4.15 /gh-shot 默认尺寸有 60 秒内缓存帧直接发，不现截（3-5s → 0.8s）
#  v4.14 URL 校验结果缓存 1 小时，免重复 DNS（/gh-live ttfb 0.85s → 0.57s）
#  v4.13 直播每 10 帧写盘 last-frame.jpg，启动读盘进缓存，先出静态再切直播
#  v4.12 及更早：缓冲占位图、间隔 4s、浏览器常驻、画质 72、帧缓存、GC、接口改名、并发防泄漏、SSRF 加固
# =========================================================
set -euo pipefail

# --- 配置区域 ---
APP_NAME="screenshot-api"
PROJECT_DIR="/opt/screenshot-api"
SCRIPT_PATH=$(readlink -f "$0")
SHORTCUT_NAME="lvs"
CONFIG_FILE="$PROJECT_DIR/config.json"
NODE_MAJOR="22"
PUPPETEER_VER="24"
EXPRESS_VER="4.21.2"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 发行版检测 ---
OS_ID="unknown"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
fi
is_alpine() { [ "$OS_ID" = "alpine" ]; }
is_debian() { [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; }

# --- 核心：自动修复系统劫持 ---
if [ -L "/usr/local/bin/ss" ]; then
  LINK_TARGET=$(readlink /usr/local/bin/ss)
  if [[ "$LINK_TARGET" == *"$APP_NAME"* ]] || [[ "$LINK_TARGET" == *"$SCRIPT_PATH"* ]] || [[ "$LINK_TARGET" == *"liveshot"* ]]; then
    rm -f /usr/local/bin/ss
    echo -e "${GREEN}[安全修复] 已删除恶意的 ss 命令劫持。${NC}"
  fi
fi

# 检查 Root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行。${NC}"
    exit 1
  fi
}

# 创建快捷键（已存在且指向正确时跳过）
create_shortcut() {
  if [ -L "/usr/local/bin/$SHORTCUT_NAME" ] && [ "$(readlink "/usr/local/bin/$SHORTCUT_NAME")" = "$SCRIPT_PATH" ]; then
    return 0
  fi
  rm -f "/usr/local/bin/$SHORTCUT_NAME"
  ln -sf "$SCRIPT_PATH" "/usr/local/bin/$SHORTCUT_NAME"
  chmod +x "$SCRIPT_PATH"
}

# 格式化时间
format_uptime() {
  local T=$1
  local D=$((T/60/60/24))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  local S=$((T%60))
  if [[ $D > 0 ]]; then printf '%d天 ' $D; fi
  if [[ $H > 0 ]]; then printf '%d小时 ' $H; fi
  if [[ $M > 0 ]]; then printf '%d分 ' $M; fi
  printf '%d秒' $S
}

# 获取状态（只调用一次 pm2 jlist，日志直接读文件）
get_status_info() {
  STATUS_COLOR="${RED}Stopped${NC}"
  UPTIME_TEXT="0s"
  LAST_LOG="无记录"
  MEM_USAGE="0MB"
  CRON_STATUS="未设置"

  # 检查 Token（菜单只显示掩码，不展示完整值）
  if [ -f "$CONFIG_FILE" ]; then
    local raw_token
    raw_token=$(grep -oP '(?<="token": ")[^"]*' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$raw_token" ]; then
      CURRENT_TOKEN="${raw_token:0:3}***${raw_token: -2}"
    else
      CURRENT_TOKEN="未知"
    fi
  else
    CURRENT_TOKEN="未生成"
  fi

  # 检查 PM2 状态：一次 jlist，node 解析
  if command -v pm2 &>/dev/null && command -v node &>/dev/null; then
    local pm2_out parsed
    pm2_out=$(pm2 jlist 2>/dev/null || echo "[]")
    parsed=$(echo "$pm2_out" | node -e "
      let d='';
      process.stdin.on('data', c => d += c).on('end', () => {
        try {
          const list = JSON.parse(d);
          const app = list.find(a => a.name === '$APP_NAME');
          if (!app) { console.log('NOTFOUND'); return; }
          const st = app.pm2_env ? app.pm2_env.status : '?';
          const ts = app.pm2_env ? app.pm2_env.pm_uptime : 0;
          const mem = app.monit ? app.monit.memory : 0;
          console.log([st, ts, mem].join('|'));
        } catch (e) { console.log('PARSEERR'); }
      });
    " 2>/dev/null || echo "PARSEERR")
    if [ "$parsed" != "NOTFOUND" ] && [ "$parsed" != "PARSEERR" ] && [ -n "$parsed" ]; then
      local raw_status uptime_ts mem_bytes
      raw_status=$(echo "$parsed" | cut -d'|' -f1)
      uptime_ts=$(echo "$parsed" | cut -d'|' -f2)
      mem_bytes=$(echo "$parsed" | cut -d'|' -f3)
      if [ "$raw_status" = "online" ]; then
        STATUS_COLOR="${GREEN}Running${NC}"
        if [ -n "$uptime_ts" ] && [ "$uptime_ts" -gt 0 ] 2>/dev/null; then
          local now diff
          now=$(date +%s)
          diff=$(( now - uptime_ts / 1000 ))
          if [ "$diff" -lt 0 ]; then diff=0; fi
          UPTIME_TEXT=$(format_uptime $diff)
        fi
        if [ -n "$mem_bytes" ] && [ "$mem_bytes" != "0" ] 2>/dev/null; then
          MEM_USAGE=$(awk "BEGIN {printf \"%.1fMB\", $mem_bytes/1024/1024}")
        fi
      else
        STATUS_COLOR="${RED}$raw_status${NC}"
      fi
    fi
  fi

  # 最近日志：直接读 pm2 日志文件，不再 spawn pm2 logs
  local log_file="${PM2_HOME:-$HOME/.pm2}/logs/${APP_NAME}-out.log"
  if [ -f "$log_file" ]; then
    local log
    log=$(grep -E '\[Shot\]|\[Live\]|\[System\]' "$log_file" 2>/dev/null | tail -n 1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} *//' || true)
    if [ -n "$log" ]; then
      LAST_LOG=$(echo "$log" | cut -c 1-60)
    fi
  fi

  # 检查定时任务状态
  if crontab -l 2>/dev/null | grep -q "#LiveShotAutoRestart"; then
    CRON_STATUS="${GREEN}已开启${NC}"
  fi
}

# 1. 安装服务
install_service() {
  echo -e "${BLUE}>>> 开始部署 LiveShot v4.27 (优化版)...${NC}"

  # ---- 系统依赖（Debian/Ubuntu 用 apt，Alpine 用 apk）----
  if is_alpine; then
    apk update
    apk add --no-cache curl wget ca-certificates
  elif is_debian; then
    apt-get update -y
    # 增加 cron 安装以支持定时重启
    apt-get install -y --no-install-recommends curl wget gnupg2 ca-certificates lsb-release cron
  else
    echo -e "${RED}错误: 未识别的发行版 ($OS_ID)，仅支持 Debian/Ubuntu/Alpine。${NC}"
    return 1
  fi

  # Swap 检查 (对于 Puppeteer 至关重要)
  local phy_mem
  phy_mem=$(free -m | awk '/^Mem:/ {print $2}')
  if [ "$phy_mem" -lt 1500 ] && [ ! -f /swapfile ]; then
    echo -e "${YELLOW}检测到内存 < 1.5G，创建 1.5G Swap 交换分区以防崩溃...${NC}"
    if ! fallocate -l 1536M /swapfile 2>/dev/null; then
      echo -e "${YELLOW}fallocate 失败，改用 dd 创建...${NC}"
      dd if=/dev/zero of=/swapfile bs=1M count=1536 status=progress
    fi
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi

  # ---- Node.js ----
  if ! command -v node &>/dev/null; then
    echo -e "${YELLOW}安装 Node.js ${NODE_MAJOR}...${NC}"
    if is_alpine; then
      apk add --no-cache nodejs npm
    else
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
      apt-get install -y nodejs
    fi
  fi
  echo -e "Node 版本: $(node --version)"

  echo -e "${YELLOW}安装 Chromium 依赖库...${NC}"
  if is_alpine; then
    # Alpine 是 musl，跑不了 puppeteer 自带 Chromium，用系统 chromium
    apk add --no-cache chromium nss freetype harfbuzz font-noto-cjk font-noto-emoji ttf-dejavu
  else
    apt-get install -y --no-install-recommends \
      fonts-noto-cjk fonts-noto-color-emoji \
      libasound2 libatk-bridge2.0-0 libatk1.0-0 libc6 libcairo2 libcups2 \
      libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libgcc1 libglib2.0-0 \
      libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
      libstdc++6 libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
      libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 \
      libxss1 libxtst6 xdg-utils
  fi

  mkdir -p "$PROJECT_DIR" && cd "$PROJECT_DIR"
  if [ ! -f "package.json" ]; then
    npm init -y >/dev/null
  fi
  echo -e "${YELLOW}安装核心组件...${NC}"
  if is_alpine; then
    # Alpine 跳过 puppeteer 自带 Chromium 下载，运行时用系统 chromium
    PUPPETEER_SKIP_DOWNLOAD=true npm install "express@${EXPRESS_VER}" "puppeteer@${PUPPETEER_VER}" --no-audit --no-fund --registry=https://registry.npmmirror.com
  else
    PUPPETEER_DOWNLOAD_HOST=https://npmmirror.com/mirrors npm install "express@${EXPRESS_VER}" "puppeteer@${PUPPETEER_VER}" --no-audit --no-fund --registry=https://registry.npmmirror.com
  fi

  local TOKEN
  if [ -f "$CONFIG_FILE" ]; then
    TOKEN=$(grep -oP '(?<="token": ")[^"]*' "$CONFIG_FILE" || echo "")
  else
    TOKEN=""
  fi
  if [ -z "$TOKEN" ]; then
    TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12 || true)
    echo "{\"token\": \"$TOKEN\"}" > "$CONFIG_FILE"
  fi

  # --- 写入优化后的 Node 代码 (包含空闲销毁逻辑) ---
  cat << 'EOF' > index.js
const express = require('express');
const puppeteer = require('puppeteer');
const dns = require('dns').promises;
const net = require('net');
const fs = require('fs');
const app = express();
const port = 6000;
const config = JSON.parse(fs.readFileSync('./config.json', 'utf8'));

// 缓冲占位图：直播页还没出第一帧时，先发这张顶着，不让观众看黑屏
let bufferingJpeg = null;
try { bufferingJpeg = fs.readFileSync('./buffering.jpg'); } catch (e) { console.warn('[System] no buffering.jpg, skip placeholder'); }

// === 核心优化配置 ===
const MAX_CONCURRENT_PAGES = 3;
// 制片方永久常驻的目标面板地址：改成你自己的面板 URL；启动即开，没人看也不关
const PERMANENT_TARGET = 'https://your-dashboard.example.com/';
// 空闲检查间隔：120 秒无页面时检查一次浏览器年龄（常驻热浏览器，去掉冷启动）
const IDLE_TIMEOUT_MS = 120000;
// 浏览器最长 6 小时：超了且没人用就关掉清内存，防止 Chromium 久跑漏内存
const BROWSER_MAX_AGE_MS = 6 * 3600 * 1000;
// 截图尺寸上限，防止超大视口撑爆内存
const MAX_WIDTH = 3840;
const MAX_HEIGHT = 2160;

let activePages = 0;
let browser = null;
let browserPromise = null;
let idleTimer = null;
let browserLaunchTime = 0;

// === 浏览器常驻：去掉冷启动，浏览器一直热着；6 小时以上没人用才关一次清内存 ===
const updateIdleTimer = () => {
  // 先清除旧的计时器
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = null;
  // 如果当前没有任何活跃页面，120 秒后检查浏览器年龄
  if (activePages === 0) {
    idleTimer = setTimeout(async () => {
      idleTimer = null;
      if (browser && activePages === 0) {
        const age = Date.now() - browserLaunchTime;
        if (age > BROWSER_MAX_AGE_MS) {
          console.log(`[System] Browser age ${(age / 3600000).toFixed(1)}h > 6h, closing to free memory...`);
          try {
            await browser.close();
          } catch (e) { console.error('Close Error:', e); }
          browser = null;
        } else {
          console.log(`[System] Browser kept warm (age ${(age / 60000).toFixed(0)}m), no cold start for next viewer.`);
        }
      }
    }, IDLE_TIMEOUT_MS);
  }
};

async function getBrowser() {
  // 有新请求，立即取消空闲倒计时
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = null;

  if (browser && browser.isConnected()) return browser;
  // 并发守卫：启动中的请求共享同一个 Promise，不会重复拉起浏览器
  if (browserPromise) return browserPromise;

  console.log('[System] Launching new browser instance...');
  // Alpine 等系统用发行版自带 chromium（musl 跑不了 puppeteer 自带版）
  let executablePath;
  for (const p of ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']) {
    if (fs.existsSync(p)) { executablePath = p; break; }
  }
  browserPromise = puppeteer.launch({
    headless: true,
    executablePath,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--no-first-run',
      '--disable-extensions',
      '--disable-background-networking',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--disable-sync',
      '--disable-translate',
      '--disable-default-apps',
      '--no-default-browser-check',
      '--disable-component-extensions-with-background-pages',
      '--disable-features=TranslateUI',
      '--js-flags=--max-old-space-size=256',
    ],
  }).then((b) => {
    browser = b;
    browserLaunchTime = Date.now();
    browserPromise = null;
    // 浏览器意外退出时清掉引用，下次请求重新拉起
    b.on('disconnected', () => { if (browser === b) browser = null; });
    return b;
  }).catch((e) => {
    browserPromise = null;
    throw e;
  });
  return browserPromise;
}

// === SSRF 防护：解析出真实 IP 再按网段校验 ===
// URL 校验结果缓存：同一域名 1 小时内不用重复 DNS，首帧更快
const urlCheckCache = new Map(); // url -> { value, time }
function isPrivateIP(ip) {
  if (net.isIP(ip) === 4) {
    const [a, b] = ip.split('.').map(Number);
    return (
      a === 10 ||                          // 10.0.0.0/8
      (a === 172 && b >= 16 && b <= 31) || // 172.16.0.0/12
      (a === 192 && b === 168) ||          // 192.168.0.0/16
      a === 127 ||                         // 127.0.0.0/8
      (a === 169 && b === 254) ||          // 169.254.0.0/16 链路本地/云元数据
      a === 0                              // 0.0.0.0/8
    );
  }
  if (net.isIP(ip) === 6) {
    const lower = ip.toLowerCase();
    if (lower.startsWith('::ffff:')) return isPrivateIP(lower.slice(7)); // IPv4 映射地址
    return (
      lower === '::1' ||                   // loopback
      lower.startsWith('fc') ||            // fc00::/7 唯一本地
      lower.startsWith('fd') ||
      lower.startsWith('fe8') ||           // fe80::/10 链路本地
      lower.startsWith('fe9') ||
      lower.startsWith('fea') ||
      lower.startsWith('feb')
    );
  }
  return true; // 不是合法 IP，一律按内网处理
}

async function assertPublicURL(raw) {
  let u;
  try {
    u = new URL(raw.startsWith('http') ? raw : `http://${raw}`);
  } catch {
    throw new Error('Invalid URL');
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('Only http(s) allowed');
  const host = u.hostname;
  if (net.isIP(host)) {
    if (isPrivateIP(host)) throw new Error('Block Private IP');
    return u.toString();
  }
  // 域名：解析后逐个校验（防 DNS 重绑定与 0177.0.0.1 这类写法绕过）
  // 校验结果缓存 1 小时，同一域名不用每次都 DNS，首帧更快
  const key = u.toString();
  const hit = urlCheckCache.get(key);
  if (hit && Date.now() - hit.time < 3600000) return hit.value;
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch {
    throw new Error('DNS lookup failed');
  }
  if (!addrs.length || addrs.some((a) => isPrivateIP(a.address))) {
    throw new Error('Block Private IP');
  }
  urlCheckCache.set(key, { value: key, time: Date.now() });
  return key;
}

const clampInt = (v, def, min, max) => {
  const n = parseInt(v, 10);
  if (Number.isNaN(n)) return def;
  return Math.min(max, Math.max(min, n));
};

const auth = (req, res, next) => {
  // Token 不再放 URL：?token= / Bearer 头 / Cookie 三种方式都认，
  // 首次用 ?token= 验证通过后种下 HttpOnly Cookie，之后干净地址直接用
  const q = req.query.token;
  const cookie = req.headers.cookie || '';
  const m = cookie.match(/(?:^|;\s*)ls_token=([^;]+)/);
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const provided = q || (m && decodeURIComponent(m[1])) || bearer;
  if (provided !== config.token) return res.status(403).send('Invalid Token');
  if (q) res.cookie('ls_token', config.token, { httpOnly: true, secure: true, sameSite: 'none', maxAge: 30 * 24 * 3600 * 1000 });
  next();
};

// 刷新随机换颜色：每次新开页面随机换一个主题，默认首次是冰蓝，且保证每次都跟上次不同
const SHOT_THEMES = ['tz-ice', 'tz-crimson', 'tz-jade', 'tz-amber', 'tz-dusk', 'tz-neon', 'tz-carbon'];
let lastTheme = null;
function nextTheme() {
  let t;
  if (lastTheme === null) {
    t = 'tz-ice'; // 默认冰蓝
  } else {
    const pool = SHOT_THEMES.filter((x) => x !== lastTheme);
    t = pool[Math.floor(Math.random() * pool.length)];
  }
  lastTheme = t;
  return t;
}

// 地图下方加时间标签（透明背景，北京时间，带秒，每秒更新）：只在截图页里注入，不改面板本身
async function injectTimeLabel(page) {
  await page.evaluate(() => {
    if (document.getElementById('liveshot-clock')) return;
    let mapBox = null;
    for (const cv of document.querySelectorAll('canvas')) {
      const p = cv.parentElement;
      if (p && p.getAttribute('aria-hidden') === 'true' && p.querySelectorAll('canvas').length >= 2) { mapBox = p; break; }
    }
    if (!mapBox || !mapBox.parentElement) return;
    const el = document.createElement('div');
    el.id = 'liveshot-clock';
    el.style.cssText = 'background: transparent; text-align: left; color: var(--tz-line); font-size: 36px; line-height: 1.4; padding: 6px 0 2px; font-variant-numeric: tabular-nums; letter-spacing: 0.04em;';
    const fmt = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
    const tick = () => {
      const o = {};
      for (const p of fmt.formatToParts(new Date())) o[p.type] = p.value;
      el.textContent = `${o.year}-${o.month}-${o.day} ${o.hour}:${o.minute}:${o.second}`;
    };
    tick();
    setInterval(tick, 1000);
    mapBox.parentElement.insertBefore(el, mapBox.nextSibling);
  }).catch(() => {});
}

// 打开一个已加载好数据的面板页：播种主题 -> 加载 -> 等表格 -> 冻结动画。
// 冻结分两层：CSS 动画/过渡（进度条、辉光、脉冲）+ 地图的 requestAnimationFrame
// 逐帧重绘节流到 2 秒一次（canvas 动画，CSS 冻不住；标记一直在、跟得上最忙最快，CPU 也低）。
// 这样页面在两次截图之间几乎不消耗 CPU，截图本身也不用等动画。
async function openPanelPage(target, width, height) {
  const b = await getBrowser();
  const page = await b.newPage();
  try {
    await page.setViewport({ width, height });
    const preset = nextTheme(); // 每次新开页面随机换一个主题，首次默认冰蓝、之后必跟上次不同
    const seedHost = (() => { try { return new URL(PERMANENT_TARGET).hostname; } catch { return ''; } })(); // 主题播种只对常驻面板的域名生效
    await page.evaluateOnNewDocument((host, preset) => { try { if (host && location.hostname === host) { localStorage.setItem("theme-preset", preset); localStorage.setItem("theme", "dark"); } } catch (e) {} }, seedHost, preset); // 面板截图固定用用户主题，否则全新浏览器每次回默认，颜色看着随机
    console.log(`[Theme] ${target} -> ${preset}`);
    await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForSelector('tbody tr', { timeout: 3000 }).catch(() => {}); // 等表格数据出来再截，颜色/数据才稳定（3 秒够用，太久拖慢首帧）
    await page.addStyleTag({ content: '*,*::before,*::after{animation:none!important;transition:none!important}' }).catch(() => {}); // 冻结页面动画：截图/直播逐帧出图，动画看不见，冻住能省 CPU
    await page.evaluate(() => { window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 2000); }).catch(() => {}); // 地图 canvas 重绘节流到 2 秒一次：标记一直在、跟得上最忙最快，CPU 也低
    await injectTimeLabel(page); // 地图下方加时间标签（透明背景，北京时间带秒）
    return page;
  } catch (e) {
    await page.close().catch(() => {});
    throw e;
  }
}

// === 直播共享制：同一目标只开一个页面，所有观众共用它的帧 ===
// 之前每个观众各开一个页面各截各的，人一多 CPU 直接拉满还 503。
// 现在制片方每 2 秒截一帧广播给所有观众；新观众进来立刻拿到最新一帧，
// 不用等冷启动；plain 制片方永久常驻（没人看也不关），其他目标没人看了立刻关页。
const liveProducers = new Map(); // target -> { page, clients:Set, latest:Buffer|null, timer, reloadTimer, starting:Promise }
// 跨会话帧缓存：制片方关掉后，最后一帧留着给下个观众秒开（先看到图，再等直播帧）
const lastFrameCache = new Map(); // target -> { buf, time }
// 启动时读盘上的最后一帧进缓存：重启后第一个观众也能先看到静态图，再切直播
try {
  const st = fs.statSync('./last-frame.jpg');
  if (Date.now() - st.mtimeMs < 3600000) {
    lastFrameCache.set(PERMANENT_TARGET, { buf: fs.readFileSync('./last-frame.jpg'), time: st.mtimeMs });
    console.log('[System] loaded last-frame.jpg from disk');
  }
} catch (e) { /* 还没有盘上的帧 */ }
function stopLiveProducer(target) {
  const p = liveProducers.get(target);
  if (!p) return;
  liveProducers.delete(target);
  if (p.timer) clearTimeout(p.timer);
  if (p.reloadTimer) clearInterval(p.reloadTimer);
  if (p.page && !p.page.isClosed()) p.page.close().catch(() => {});
  activePages--;
  // 关页后立即 GC，把这一页的帧缓冲从 Node 堆里清掉
  if (global.gc) global.gc();
  updateIdleTimer();
}
// 制片方永久常驻（v4.18）：常驻面板启动即开，没人看也不关，新观众首帧约 0.5 秒
// 防内存泄漏：制片方页面每 6 小时重载一次，清空 JS 堆与 DOM，客户端不断线
const PRODUCER_RELOAD_MS = 6 * 3600 * 1000;
function startPermanentProducer() {
  getLiveProducer(PERMANENT_TARGET).catch((e) => {
    console.error('[Live] permanent producer start failed, retry in 5s:', e.message);
    setTimeout(startPermanentProducer, 5000);
  });
}
async function getLiveProducer(target) {
  let p = liveProducers.get(target);
  if (p) return p;
  if (activePages >= MAX_CONCURRENT_PAGES) throw new Error('Server Busy');
  activePages++;
  p = { target, page: null, clients: new Set(), latest: null, timer: null, reloadTimer: null, starting: null };
  liveProducers.set(target, p);
  p.starting = (async () => {
    const page = await openPanelPage(target, 1280, 1240);
    p.page = page;
    let frames = 0;
    let reloading = false;
    const loop = async () => {
      if (!liveProducers.has(target) || !p.page || p.page.isClosed()) return;
      if (reloading) { p.timer = setTimeout(loop, 1000); return; }
      try {
        const buf = await p.page.screenshot({ type: 'jpeg', quality: 72 });
        p.latest = buf;
        lastFrameCache.set(target, { buf, time: Date.now() });
        for (const res of [...p.clients]) {
          try {
            res.write('--frame\r\nContent-Type: image/jpeg\r\n\r\n');
            res.write(buf);
            res.write('\r\n');
          } catch { p.clients.delete(res); }
        }
        // 每 10 帧（约 20 秒）强制一次 GC，并把最新帧写盘，重启后也能先出静态图
        if (++frames % 10 === 0) {
          if (global.gc) global.gc();
          fs.writeFile('./last-frame.jpg', buf, () => {});
        }
      } catch (e) { /* 单帧失败跳过，下轮再截 */ }
      if (liveProducers.has(target)) p.timer = setTimeout(loop, 2000);
    };
    loop();
    // 每 6 小时重载页面防内存泄漏：清空 JS 堆与 DOM，客户端不断线（重载时发上一帧顶着，不出缓冲）
    p.reloadTimer = setInterval(async () => {
      if (!liveProducers.has(target) || !p.page || p.page.isClosed()) return;
      reloading = true;
      if (p.timer) { clearTimeout(p.timer); p.timer = null; }
      await new Promise((r) => setTimeout(r, 1000)); // 等在途截图完成，别截到重载中的半成品
      try {
        console.log(`[Live] reloading page to prevent memory leak: ${target}`);
        // 整页重建（不用 goto）：openPanelPage 内部抽新主题、重新播种、冻结动画、注入时间标签
        const newPage = await openPanelPage(target, 1280, 1240);
        const oldPage = p.page;
        p.page = newPage;
        if (oldPage && !oldPage.isClosed()) await oldPage.close().catch(() => {});
        if (global.gc) global.gc();
        console.log(`[Live] page reloaded: ${target}`);
      } catch (e) {
        console.error('[Live] reload failed:', e.message);
      } finally {
        reloading = false;
        if (liveProducers.has(target)) loop();
      }
    }, PRODUCER_RELOAD_MS);
  })().catch((e) => {
    console.error('[Live] producer failed:', e.message);
    for (const res of [...p.clients]) { try { if (!res.writableEnded) res.end(); } catch {} }
    stopLiveProducer(target);
    // 常驻制片方挂了就 5 秒后重开，保证一直有人在截
    if (target === PERMANENT_TARGET) setTimeout(startPermanentProducer, 5000);
  });
  return p;
}

app.get('/gh-shot', auth, async (req, res) => {
  const { url, width, height, full } = req.query;
  if (activePages >= MAX_CONCURRENT_PAGES) {
    console.warn(`[Busy] Rejecting shot ${url || ''}, active: ${activePages}`);
    return res.status(503).send(`Server Busy: Too many active windows (${activePages}/${MAX_CONCURRENT_PAGES})`);
  }
  console.log(`[Shot] ${url} (Active: ${activePages + 1})`);
  let page = null;
  try {
    activePages++;
    const target = await assertPublicURL(url || '');
    // 默认尺寸且非整页时，有 60 秒内的缓存帧就直接发，不用重新开页截图（秒开）
    const w = clampInt(width, 1920, 320, MAX_WIDTH);
    const h = clampInt(height, 1080, 240, MAX_HEIGHT);
    if (full !== 'true' && w === 1280 && h === 1240) {
      const c = lastFrameCache.get(target);
      if (c && Date.now() - c.time < 60000) {
        res.set('Content-Type', 'image/jpeg');
        res.set('Cache-Control', 'no-store');
        res.send(c.buf);
        return; // finally 会做 activePages-- 与 updateIdleTimer
      }
      // 内存缓存过期了，读盘上的 last-frame.jpg（1 小时内都算新鲜）：没人看直播时也能秒开
      try {
        const st = await fs.promises.stat('./last-frame.jpg');
        if (Date.now() - st.mtimeMs < 3600000) {
          const buf = await fs.promises.readFile('./last-frame.jpg');
          lastFrameCache.set(target, { buf, time: st.mtimeMs });
          res.set('Content-Type', 'image/jpeg');
          res.set('Cache-Control', 'no-store');
          res.send(buf);
          return; // finally 会做 activePages-- 与 updateIdleTimer
        }
      } catch (e) { /* 盘上也没有，往下走现截 */ }
    }
    page = await openPanelPage(target, w, h);
    await new Promise((r) => setTimeout(r, 500)); // 等首屏渲染，比 networkidle2 快得多
    const img = await page.screenshot({ type: 'jpeg', quality: 85, fullPage: full === 'true' });
    res.set('Content-Type', 'image/jpeg');
    res.set('Cache-Control', 'no-store');
    res.send(img);
  } catch (e) {
    if (!res.headersSent) res.status(e.message === 'Block Private IP' ? 403 : 500).send(e.message);
  } finally {
    if (page) await page.close().catch(() => {});
    if (global.gc) global.gc();
    activePages--;
    updateIdleTimer(); // 请求结束，尝试重置空闲计时器
  }
});

app.get('/gh-live', auth, async (req, res) => {
  const { url } = req.query;
  let target;
  try {
    target = await assertPublicURL(url || '');
  } catch (e) {
    return res.status(e.message === 'Block Private IP' ? 403 : 500).send(e.message);
  }
  let p;
  try {
    p = await getLiveProducer(target);
  } catch (e) {
    return res.status(503).send(`Server Busy: Too many active windows (${activePages}/${MAX_CONCURRENT_PAGES})`);
  }
  // 订阅共享帧：不用自己开页，立刻拿到最新一帧
  res.writeHead(200, { 'Content-Type': 'multipart/x-mixed-replace; boundary=frame', 'Cache-Control': 'no-store' });
  p.clients.add(res);
  // 连续观看超 2 分钟断开（省流量）：120 秒后主动结束本次直播流，观众刷新可再看
  const liveTimer = setTimeout(() => {
    try { if (!res.writableEnded) res.end(); } catch {}
  }, 120000);
  // 新观众先发一帧：有直播帧直接发直播帧；没有就发缓冲动画（每次都加），不再发缓存的静态图
  if (p.latest) {
    try {
      res.write('--frame\r\nContent-Type: image/jpeg\r\n\r\n');
      res.write(p.latest);
      res.write('\r\n');
    } catch { p.clients.delete(res); }
  } else if (bufferingJpeg) {
    // 还没帧（冷启动中）：先发缓冲动画，观众立刻看到"正在缓冲"，不等黑屏
    try {
      res.write('--frame\r\nContent-Type: image/jpeg\r\n\r\n');
      res.write(bufferingJpeg);
      res.write('\r\n');
    } catch { p.clients.delete(res); }
  }
  console.log(`[Live] ${url} (viewers: ${p.clients.size}, pages: ${activePages})`);
  req.on('close', () => {
    clearTimeout(liveTimer);
    p.clients.delete(res);
    // 没人看了就关页（常驻制片方除外，它一直开着）：下次有人来就新开一页、随机换个颜色，刷新必换色
    if (p.clients.size === 0 && target !== PERMANENT_TARGET) stopLiveProducer(target);
  });
});

app.listen(port, '127.0.0.1', () => {
  console.log(`Ready on 127.0.0.1:${port}`);
  updateIdleTimer(); // 启动时也初始化计时器
  startPermanentProducer(); // 制片方永久常驻：启动即开 plain 制片方，新观众首帧约 0.5 秒
});
EOF

  echo -e "${YELLOW}配置 PM2 进程守护...${NC}"
  if ! command -v pm2 &>/dev/null; then
    npm install -g pm2 --no-audit --no-fund --registry=https://registry.npmmirror.com
  fi
  pm2 delete "$APP_NAME" 2>/dev/null || true
  # 增加 --expose-gc 参数，允许手动触发垃圾回收（可选优化）
  pm2 start index.js --name "$APP_NAME" --node-args="--expose-gc" --max-memory-restart 1024M --log-date-format "YYYY-MM-DD HH:mm:ss"
  pm2 save 2>/dev/null || true
  # 开机自启：systemd / OpenRC 自动识别
  local init_system=""
  if command -v systemctl &>/dev/null; then
    init_system="systemd"
  elif command -v rc-update &>/dev/null; then
    init_system="openrc"
  fi
  if [ -n "$init_system" ]; then
    local startup_cmd
    startup_cmd=$(pm2 startup "$init_system" -u root --hp /root 2>&1 | grep -m1 -E 'pm2 startup' || true)
    if [ -n "$startup_cmd" ]; then
      # root 下不需要 sudo；Alpine 默认没装 sudo，去掉它
      if ! command -v sudo &>/dev/null; then
        startup_cmd=${startup_cmd#sudo }
      fi
      eval "$startup_cmd" >/dev/null 2>&1 || true
    fi
  else
    echo -e "${YELLOW}未识别到 systemd/OpenRC，开机自启未设置，请手动处理。${NC}"
  fi
  # 确保 cron 服务在运行（定时重启依赖它）
  if is_alpine; then
    rc-update add crond default 2>/dev/null || true
    rc-service crond start 2>/dev/null || true
  elif command -v systemctl &>/dev/null; then
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
  fi
  create_shortcut
  echo -e "${GREEN}安装完成! 你的 Token: ${YELLOW}$TOKEN${NC}"
  echo -e "${GREEN}快捷键: lvs${NC}"
  echo -e "${YELLOW}内存优化策略：浏览器常驻热备，超 6 小时无人才关一次。${NC}"
  read -p "按回车继续..." || true
}

# 彻底卸载（只删 LiveShot 自己的东西）
uninstall_service_full() {
  echo -e "${RED}⚠️ 警告: 这将卸载 LiveShot 服务！${NC}"
  local confirm
  read -p "确定要继续吗? (输入 y 确认): " confirm || true
  if [ "$confirm" == "y" ]; then
    echo -e "${YELLOW}停止服务...${NC}"
    # 只删自己的应用，不用 pm2 kill（会杀掉其他 pm2 应用）
    pm2 delete "$APP_NAME" 2>/dev/null || true
    pm2 save 2>/dev/null || true
    # 清除定时任务
    crontab -l 2>/dev/null | grep -v "#LiveShotAutoRestart" | crontab - || true
    echo -e "${YELLOW}删除项目文件和快捷键...${NC}"
    rm -rf "$PROJECT_DIR"
    rm -f "/usr/local/bin/$SHORTCUT_NAME"
    # 只删除被劫持的 ss（软链指向本脚本），不动系统自带的 ss
    if [ -L "/usr/local/bin/ss" ]; then
      local t
      t=$(readlink /usr/local/bin/ss)
      if [[ "$t" == *"$APP_NAME"* ]] || [[ "$t" == *"$SCRIPT_PATH"* ]] || [[ "$t" == *"liveshot"* ]]; then
        rm -f /usr/local/bin/ss
      fi
    fi
    echo -e "${GREEN}✅ LiveShot 已卸载（Node.js / PM2 / 系统依赖保留，供其他程序使用）。${NC}"
  else
    echo "已取消。"
  fi
  read -p "按回车继续..." || true
}

# 简单管理功能
start_service() { pm2 start "$APP_NAME" 2>/dev/null || echo "未安装"; pm2 save 2>/dev/null || true; read -p "Done." || true; }
stop_service() { pm2 stop "$APP_NAME" 2>/dev/null || echo "未安装/未运行"; read -p "Done." || true; }
restart_service() { pm2 restart "$APP_NAME" 2>/dev/null || echo "未安装/未运行"; read -p "Done." || true; }
view_logs() { pm2 logs "$APP_NAME" --lines 50 --nostream 2>/dev/null || echo "未安装"; read -n 1 -s -r -p "Press any key..." || true; }

# 重置 Token
reset_token() {
  echo -e "${YELLOW}请输入新的 Token (直接回车将随机生成):${NC}"
  local user_input new_token
  read -p "> " user_input || true
  if [ -n "$user_input" ]; then
    new_token="$user_input"
  else
    new_token=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12 || true)
  fi
  mkdir -p "$PROJECT_DIR"
  echo "{\"token\": \"$new_token\"}" > "$CONFIG_FILE"
  pm2 restart "$APP_NAME" 2>/dev/null || true
  echo -e "${GREEN}Token 已更新为: $new_token${NC}"
  read -p "按回车继续..." || true
}

# 定时重启设置
set_auto_restart() {
  echo -e "${BLUE}=========================${NC}"
  echo -e "${BLUE} 设置定时重启策略 ${NC}"
  echo -e "${BLUE}=========================${NC}"
  echo -e "说明: 强制重启可清理僵尸进程和长期内存碎片"
  echo -e "-------------------------"
  echo " 1. 每天凌晨 04:00 (推荐)"
  echo " 2. 每周一凌晨 04:00"
  echo " 3. 自定义 Cron 表达式"
  echo " 4. ${RED}关闭/删除定时重启${NC}"
  echo " 0. 返回"
  echo -e "-------------------------"
  local restart_opt
  read -p "请选择: " restart_opt || true
  local PM2_PATH
  PM2_PATH=$(which pm2)
  if [ -z "$PM2_PATH" ]; then
    echo -e "${RED}错误: 找不到 pm2，请先执行安装服务。${NC}"
    read -p "按回车返回..." || true
    return
  fi
  # 构造重启命令 (带有特定标记以便后续管理)
  local RESTART_CMD="$PM2_PATH restart $APP_NAME --update-env >/dev/null 2>&1 #LiveShotAutoRestart"
  local CRON_EXP=""
  case $restart_opt in
    1)
      CRON_EXP="0 4 * * *"
      ;;
    2)
      CRON_EXP="0 4 * * 1"
      ;;
    3)
      echo -e "${YELLOW}请输入 Cron 表达式 (例如 '0 3 * * *' 表示每天3点):${NC}"
      read -p "> " CRON_EXP || true
      if [ -z "$CRON_EXP" ]; then echo "输入为空"; return; fi
      if ! echo "$CRON_EXP" | grep -qE '^([0-9*,/-]+ ){4}[0-9*,/-]+$'; then
        echo -e "${RED}Cron 表达式格式不对（需要 5 段）。${NC}"
        read -p "按回车返回..." || true
        return
      fi
      ;;
    4)
      crontab -l 2>/dev/null | grep -v "#LiveShotAutoRestart" | crontab - || true
      echo -e "${GREEN}✅ 已关闭定时重启。${NC}"
      read -p "按回车继续..." || true
      return
      ;;
    0)
      return
      ;;
    *)
      echo "无效选项"
      read -p "按回车返回..." || true
      return
      ;;
  esac
  # 写入 Crontab
  # 1. 导出当前 crontab
  # 2. 过滤掉旧的 LiveShotAutoRestart 任务
  # 3. 追加新任务
  # 4. 重新导入
  (crontab -l 2>/dev/null | grep -v "#LiveShotAutoRestart" || true; echo "$CRON_EXP $RESTART_CMD") | crontab -
  echo -e "${GREEN}✅ 设置成功！${NC}"
  echo -e "任务内容: ${YELLOW}$CRON_EXP $PM2_PATH restart $APP_NAME${NC}"
  read -p "按回车继续..." || true
}

# 主菜单
show_menu() {
  check_root
  create_shortcut
  while true; do
    get_status_info
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} LiveShot v4.27 (Auto-Idle) [Cmd: $SHORTCUT_NAME]${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 状态: $STATUS_COLOR | 运行: $UPTIME_TEXT"
    echo -e " 内存: ${YELLOW}${MEM_USAGE}${NC} (PM2 Monitor)"
    echo -e " Token: ${YELLOW}${CURRENT_TOKEN}${NC}"
    echo -e " 监控: ${BLUE}$LAST_LOG${NC}"
    echo -e " 策略: ${YELLOW}浏览器常驻·6h 阀${NC} | 定时: $CRON_STATUS"
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e " 1. 安装/重装服务"
    echo -e " 2. 启动服务"
    echo -e " 3. 停止服务"
    echo -e " 4. 重启服务 (立即)"
    echo -e " 5. 查看日志"
    echo -e " 6. 修改/重置 Token"
    echo -e " 7. 彻底卸载"
    echo -e "${GREEN} 8. 设置定时重启任务${NC}"
    echo -e " 0. 退出"
    echo -e ""
    local op
    read -p " 选择: " op || exit 0
    case $op in
      1) install_service || true ;;
      2) start_service ;;
      3) stop_service ;;
      4) restart_service ;;
      5) view_logs ;;
      6) reset_token ;;
      7) uninstall_service_full ;;
      8) set_auto_restart || true ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

show_menu
