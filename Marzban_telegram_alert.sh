#!/bin/bash

set -e

echo "🚀 شروع نصب Marzban Telegram Alert Bot..."

# ------------------------------
# مرحله 1: آپدیت و آپگرید سیستم
# ------------------------------
echo "🔄 آپدیت و آپگرید سیستم..."
apt update -y && apt upgrade -y

# ------------------------------
# مرحله 2: نصب پیش نیازها
# ------------------------------
echo "📦 نصب پیش نیازهای Python و ابزارهای لازم..."
apt install -y python3 python3-venv python3-pip curl git nano

# ------------------------------
# مرحله 3: ایجاد مسیر پروژه
# ------------------------------
ALERT_DIR="/root/alert"
echo "📁 ایجاد پوشه پروژه در $ALERT_DIR ..."
mkdir -p "$ALERT_DIR"

# ------------------------------
# مرحله 4: ایجاد محیط مجازی
# ------------------------------
echo "🧪 ایجاد محیط مجازی Python..."
python3 -m venv "$ALERT_DIR/venv"

# فعال کردن محیط مجازی
source "$ALERT_DIR/venv/bin/activate"

# نصب پکیج های مورد نیاز
echo "📦 نصب پکیج های Python..."
pip install --upgrade pip
pip install pyTelegramBotAPI requests

# ------------------------------
# مرحله 5: دریافت مشخصات از کاربر
# ------------------------------
echo "📝 لطفاً مشخصات مورد نیاز را وارد کنید:"

read -p "توکن ربات تلگرام: " BOT_TOKEN
read -p "آدرس پایه Marzban API (مثلاً https://all.tbznet.top:4178): " MARZBAN_BASE_URL
read -p "نام کاربری ادمین Marzban: " ADMIN_USERNAME
read -p "پسورد ادمین Marzban: " ADMIN_PASSWORD
read -p "حجم هشدار (به بایت) [1073741824 = 1GB]: " LOW_VOLUME_BYTES
read -p "تعداد روز باقی مانده برای هشدار اعتبار [1]: " LOW_DAYS_REMAINING
read -p "چند ثانیه یک‌بار کاربران چک شوند؟ (مثلاً 3600): " CHECK_INTERVAL

# ------------------------------
# مرحله 6: ایجاد config.json
# ------------------------------
CONFIG_FILE="$ALERT_DIR/config.json"
echo "💾 ساخت فایل config.json..."
cat > "$CONFIG_FILE" <<EOL
{
  "telegram_bot_token": "$BOT_TOKEN",
  "marzban_base_url": "$MARZBAN_BASE_URL",
  "marzban_admin_username": "$ADMIN_USERNAME",
  "marzban_admin_password": "$ADMIN_PASSWORD",
  "check_interval": $CHECK_INTERVAL,
  "thresholds": {
    "low_volume_bytes": $LOW_VOLUME_BYTES,
    "low_days_remaining": $LOW_DAYS_REMAINING
  },
  "messages": {
    "low_volume": "⚠️ هشدار! فقط 1 گیگ از حجم شما باقی مانده.",
    "empty_volume": "❌ حجم شما تمام شد. لطفا تمدید کنید.",
    "low_time": "⏰ فقط 1 روز تا پایان اعتبار باقی مانده!",
    "expired_time": "❌ اعتبار شما تمام شد. لطفا تمدید کنید."
  }
}
EOL

# ------------------------------
# مرحله 7: ایجاد اسکریپت پایتون — فقط اضافه شدن CHECK_INTERVAL
# ------------------------------
SCRIPT_FILE="$ALERT_DIR/marzban_telegram_alert.py"
echo "📄 ساخت اسکریپت پایتون..."
cat > "$SCRIPT_FILE" <<'PYTHON_EOF'
#!/usr/bin/env python3
import requests, re, json, os
from datetime import datetime, timezone
import urllib3
import telebot
import threading
import time

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

CONFIG_FILE = "/root/alert/config.json"
LOG_FILE = "/root/alert/marzban_telegram_log.json"

with open(CONFIG_FILE) as f:
    config = json.load(f)

BOT_TOKEN = config["telegram_bot_token"]
MARZBAN_BASE_URL = config["marzban_base_url"].rstrip("/")
ADMIN_USERNAME = config["marzban_admin_username"]
ADMIN_PASSWORD = config["marzban_admin_password"]
CHECK_INTERVAL = config.get("check_interval", 3600)   # ← اضافه شد
THRESHOLDS = config["thresholds"]
MESSAGES = config["messages"]

USERS_ENDPOINT = f"{MARZBAN_BASE_URL}/api/users"
TOKEN_ENDPOINT = f"{MARZBAN_BASE_URL}/api/admin/token"

bot = telebot.TeleBot(BOT_TOKEN, parse_mode="HTML")

@bot.message_handler(commands=['start'])
def start_handler(message):
    chat_id = message.chat.id
    user_id = message.from_user.id
    username = message.from_user.username
    first_name = message.from_user.first_name or "دوست عزیز"

    text = (
        f"سلام <b>{first_name}</b> 👋\n\n"
        f"این اطلاعات تلگرام شماست:\n"
        f"🔹 <b>Chat ID:</b> <code>{chat_id}</code>\n"
        f"🔹 <b>User ID:</b> <code>{user_id}</code>\n"
        f"🔹 <b>Username:</b> @{username if username else 'ندارید'}\n\n"
        f"لطفاً این Chat ID را در Note پنل Marzban وارد کنید تا هشدارها برای شما ارسال شود."
    )
    bot.send_message(chat_id, text)

def load_log():
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, "r") as f:
            return json.load(f)
    return {}

def save_log(log):
    with open(LOG_FILE, "w") as f:
        json.dump(log, f, indent=2)

def send_telegram_message(chat_id, text):
    try:
        r = requests.post(f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
                          data={"chat_id": chat_id, "text": text}, timeout=10)
        return r.ok
    except Exception as e:
        print("❌ خطا در ارسال پیام تلگرام:", e)
        return False

def get_access_token():
    data = {"grant_type": "password", "username": ADMIN_USERNAME, "password": ADMIN_PASSWORD}
    try:
        resp = requests.post(TOKEN_ENDPOINT, data=data, verify=False, timeout=10)
        resp.raise_for_status()
        return resp.json().get("access_token")
    except Exception as e:
        print("❌ خطا در دریافت توکن:", e)
        return None

def get_chat_id_from_note(note):
    if note:
        note = note.strip()
        if re.fullmatch(r"-?\d+", note):
            return int(note)
        match = re.search(r"chat_id\s*[:=]\s*(-?\d+)", note)
        if match:
            return int(match.group(1))
    return None

def check_users():
    token = get_access_token()
    if not token:
        return
    headers = {"Authorization": f"Bearer {token}"}
    try:
        resp = requests.get(USERS_ENDPOINT, headers=headers, verify=False, timeout=15)
        resp.raise_for_status()
        users = resp.json().get("users", [])
    except Exception as e:
        print("❌ خطا در دریافت لیست کاربران:", e)
        return

    log = load_log()
    now = datetime.now(timezone.utc)

    for user in users:
        username = user.get("username")
        note = user.get("note", "")
        chat_id = get_chat_id_from_note(note)
        if not chat_id:
            continue

        data_limit = user.get("data_limit", 0) or 0
        used_traffic = user.get("used_traffic", 0) or 0
        expire_raw = user.get("expire")

        remaining = data_limit - used_traffic
        expire_date = None
        days_remaining = None
        if expire_raw:
            try:
                expire_ts = int(expire_raw)
                if expire_ts > 0:
                    expire_date = datetime.fromtimestamp(expire_ts, timezone.utc)
                    days_remaining = (expire_date - now).days
            except:
                pass

        user_log = log.get(username, {
            "low_volume_sent": False,
            "empty_volume_sent": False,
            "low_time_sent": False,
            "expired_time_sent": False
        })

        if data_limit > 0 and remaining <= THRESHOLDS["low_volume_bytes"] and remaining > 0 and not user_log["low_volume_sent"]:
            if send_telegram_message(chat_id, MESSAGES["low_volume"]):
                user_log["low_volume_sent"] = True

        if data_limit > 0 and remaining <= 0 and not user_log["empty_volume_sent"]:
            if send_telegram_message(chat_id, MESSAGES["empty_volume"]):
                user_log["empty_volume_sent"] = True

        if expire_date and days_remaining is not None and days_remaining <= THRESHOLDS["low_days_remaining"] and days_remaining > 0 and not user_log["low_time_sent"]:
            if send_telegram_message(chat_id, MESSAGES["low_time"]):
                user_log["low_time_sent"] = True

        if expire_date and days_remaining is not None and now >= expire_date and not user_log["expired_time_sent"]:
            if send_telegram_message(chat_id, MESSAGES["expired_time"]):
                user_log["expired_time_sent"] = True

        log[username] = user_log

    save_log(log)

def run_loop():
    while True:
        check_users()
        time.sleep(CHECK_INTERVAL)  # ← اینجا زمان از config.json خوانده می‌شود

threading.Thread(target=lambda: bot.infinity_polling(), daemon=True).start()

if __name__ == "__main__":
    run_loop()
PYTHON_EOF

chmod +x "$SCRIPT_FILE"

# ------------------------------
# مرحله 8: ایجاد systemd
# ------------------------------
SERVICE_FILE="/etc/systemd/system/alertbot.service"
echo "🔧 ایجاد سرویس systemd..."
cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Marzban Telegram Alert Bot (Full Setup)
After=network.target

[Service]
Type=simple
WorkingDirectory=$ALERT_DIR
ExecStart=$ALERT_DIR/venv/bin/python $ALERT_DIR/marzban_telegram_alert.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=append:$ALERT_DIR/cron.log
StandardError=append:$ALERT_DIR/cron.log

[Install]
WantedBy=multi-user.target
EOL

# ------------------------------
# مرحله 9: فعال‌سازی سرویس
# ------------------------------
echo "✅ فعال‌سازی و شروع سرویس..."
systemctl daemon-reload
systemctl enable alertbot
systemctl start alertbot
systemctl status alertbot --no-pager

echo "🎉 نصب و راه‌اندازی کامل شد! ربات آماده استفاده است."
echo "برای دیدن لاگ‌ها: tail -f $ALERT_DIR/cron.log"
