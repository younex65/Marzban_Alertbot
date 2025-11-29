#!/bin/bash

# ==========================
# اسکریپت نصب و اجرای Marzban Bot
# ==========================

PROJECT_DIR="/root/marzban_bot"
VENV_DIR="$PROJECT_DIR/venv"

echo "=== آپدیت و آپگرید سیستم ..."
apt update -y && apt upgrade -y

echo "=== نصب پیش‌نیازها ..."
apt install -y python3 python3-venv python3-pip curl git

echo "=== ساخت فولدر پروژه ..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR" || exit

# ==========================
# دریافت اطلاعات از کاربر
# ==========================
read -p "توکن ربات تلگرام خود را وارد کنید: " BOT_TOKEN
read -p "چت‌آیدی ادمین را وارد کنید: " ADMIN_ID

# ساخت admin.json
cat > admin.json <<EOL
{
    "bot_token": "$BOT_TOKEN",
    "admins": [$ADMIN_ID]
}
EOL

echo "admin.json ساخته شد."

# ==========================
# ساخت محیط مجازی و نصب کتابخانه‌ها
# ==========================
echo "=== ساخت محیط مجازی Python ..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "=== نصب کتابخانه‌های مورد نیاز ..."
pip install --upgrade pip
pip install --upgrade python-telegram-bot[job-queue] requests

# ==========================
# قرار دادن فایل‌های پروژه
# ==========================
echo "=== ساخت فایل‌های پروژه ..."
# فایل bot.py
cat > bot.py <<'EOF'
import os
import json
import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
    MessageHandler,
    filters,
)
from marzban import MarzbanClient

# -------------------
# فایل‌ها
USERS_FILE = "users.json"
ADMINS_FILE = "admin.json"
PANELS_FILE = "panels.json"
TRIGGERS_FILE = "triggers.json"
ALERTS_FILE = "alerts.json"

# -------------------
# Load/Save JSON helper
def load_json(file, default=None):
    try:
        with open(file, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return default if default is not None else {}

def save_json(file, data):
    with open(file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)

# -------------------
# داده‌ها
admins_data = load_json(ADMINS_FILE)
users_data = load_json(USERS_FILE, {})
panels_data = load_json(PANELS_FILE, {"panels": []})
triggers_data = load_json(TRIGGERS_FILE, {})
alerts_data = load_json(ALERTS_FILE, {})

BOT_TOKEN = admins_data.get("bot_token")
if not BOT_TOKEN:
    raise Exception("توکن بات در admin.json پیدا نشد!")

ADMIN_IDS = admins_data.get("admins", [])
client = MarzbanClient()

# -------------------
# دکمه‌ها
def get_user_buttons(user_id):
    buttons = []
    if user_id not in ADMIN_IDS:
        buttons.append([InlineKeyboardButton("✅ ثبت نام کاربری", callback_data="register")])
        buttons.append([InlineKeyboardButton("📄 مشخصات اکانت", callback_data="account_info")])
    return InlineKeyboardMarkup(buttons)

def back_button_user():
    return InlineKeyboardMarkup([[InlineKeyboardButton("🔙 بازگشت", callback_data="user_back")]])

def admin_menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🛠 افزودن پنل", callback_data="add_panel")],
        [InlineKeyboardButton("👤 افزودن ادمین", callback_data="add_admin")],
        [InlineKeyboardButton("⏱ تنظیم تریگرها", callback_data="set_triggers")],
        [InlineKeyboardButton("⚠️ تنظیم پیام‌های هشدار", callback_data="set_alerts")],
    ])

def back_button_admin():
    return InlineKeyboardMarkup([[InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")]])

# -------------------
# هندلر استارت
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if user_id in ADMIN_IDS:
        await update.message.reply_text("سلام ادمین! منوی مدیریت:", reply_markup=admin_menu())
    else:
        await update.message.reply_text("سلام! خوش آمدید.", reply_markup=get_user_buttons(user_id))

# -------------------
# کمک‌کننده‌ها
def push_admin_stack(context, view_name: str):
    stack = context.user_data.get("admin_stack", [])
    stack.append(view_name)
    context.user_data["admin_stack"] = stack

def pop_admin_stack(context):
    stack = context.user_data.get("admin_stack", [])
    if stack:
        stack.pop()
        context.user_data["admin_stack"] = stack
    return stack[-1] if stack else None

def clear_admin_awaits(context):
    keys = ["awaiting_panel_url", "awaiting_panel_username", "awaiting_panel_password",
            "awaiting_new_admin", "awaiting_trigger_time", "awaiting_trigger_data", "awaiting_alert_type"]
    for k in keys:
        context.user_data.pop(k, None)

# -------------------
# هندلر دکمه‌ها
async def button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    data = query.data

    # ---------------- کاربران ----------------
    if user_id not in ADMIN_IDS:
        if data == "user_back":
            await query.edit_message_text("منوی اصلی:", reply_markup=get_user_buttons(user_id))
            return

        if data == "register":
            if not panels_data["panels"]:
                await query.edit_message_text(
                    "فعلاً هیچ پنلی ثبت نشده است.\nلطفاً منتظر اضافه شدن پنل توسط ادمین بمانید.",
                    reply_markup=back_button_user()
                )
                return

            user_info = users_data.get(str(user_id))
            if user_info and "username" in user_info:
                try:
                    client.login_to_panel({
                        "url": user_info["panel_url"],
                        "token": user_info["panel_token"]
                    })
                    client.get_user_info(user_info["username"])
                    # اگر کاربر هنوز در پنل هست
                    await query.edit_message_text(
                        f"شما قبلاً ثبت نام کرده‌اید.\nنام کاربری: {user_info['username']}",
                        reply_markup=back_button_user()
                    )
                    return
                except Exception:
                    # اگر کاربر تو پنل حذف شده باشه
                    users_data.pop(str(user_id), None)
                    save_json(USERS_FILE, users_data)
                    # ادامه فرآیند ثبت نام جدید

            # اگر کاربر ثبت نام نکرده یا حذف شده
            context.user_data["awaiting_username"] = True
            await query.edit_message_text(
                "لطفاً نام کاربری خود را وارد کنید:", 
                reply_markup=back_button_user()
            )
            return

        if data == "account_info":
            user_info = users_data.get(str(user_id))
            if not user_info or "username" not in user_info:
                await query.edit_message_text("لطفاً ابتدا ثبت نام کنید.", reply_markup=back_button_user())
                return
            try:
                client.login_to_panel({"url": user_info["panel_url"], "token": user_info["panel_token"]})
                info = client.get_user_info(user_info["username"])
                days_left = client.calculate_days_remaining(int(info["expire"]))
                remaining_gb = client.bytes_to_gb(float(info["data_limit"]) - float(info["used_traffic"]))
                text = f"نام کاربری: {user_info['username']}\nزمان باقی مانده: {days_left} روز\nحجم باقی مانده: {remaining_gb} گیگابایت"
                await query.edit_message_text(text, reply_markup=back_button_user())
            except Exception as e:
                # اگر کاربر در پنل حذف شده باشه
                users_data.pop(str(user_id), None)
                save_json(USERS_FILE, users_data)
                await query.edit_message_text(
                    f"خطا در دریافت اطلاعات اکانت. ممکن است کاربر از پنل حذف شده باشد.\nلطفاً دوباره ثبت نام کنید.",
                    reply_markup=back_button_user()
                )
            return

    # ---------------- ادمین ----------------
    else:
        if data == "admin_back":
            clear_admin_awaits(context)
            prev = pop_admin_stack(context)
            if not prev or prev == "admin_main":
                await query.edit_message_text("منوی مدیریت:", reply_markup=admin_menu())
                return
            if prev == "set_triggers":
                buttons = [
                    [InlineKeyboardButton("⏱ تریگر زمان (ساعت)", callback_data="trigger_time")],
                    [InlineKeyboardButton("💾 تریگر حجم (گیگابایت)", callback_data="trigger_data")],
                    [InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")],
                ]
                await query.edit_message_text("کدام تریگر را می‌خواهید تنظیم کنید؟", reply_markup=InlineKeyboardMarkup(buttons))
                return
            if prev == "set_alerts":
                buttons = [
                    [InlineKeyboardButton("⏳ هشدار زمان باقی مانده", callback_data="alert_time_left")],
                    [InlineKeyboardButton("⏰ هشدار اتمام زمان", callback_data="alert_time_end")],
                    [InlineKeyboardButton("📦 هشدار حجم باقی مانده", callback_data="alert_data_left")],
                    [InlineKeyboardButton("❌ هشدار اتمام حجم", callback_data="alert_data_end")],
                    [InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")],
                ]
                await query.edit_message_text("کدام پیام هشدار را می‌خواهید تنظیم کنید؟", reply_markup=InlineKeyboardMarkup(buttons))
                return

        if data == "add_panel":
            push_admin_stack(context, "admin_main")
            context.user_data["awaiting_panel_url"] = True
            await query.edit_message_text("لطفاً آدرس پنل را وارد کنید:", reply_markup=back_button_admin())
            return

        if data == "add_admin":
            push_admin_stack(context, "admin_main")
            context.user_data["awaiting_new_admin"] = True
            await query.edit_message_text("لطفاً چت‌آیدی ادمین جدید را وارد کنید:", reply_markup=back_button_admin())
            return

        if data == "set_triggers":
            push_admin_stack(context, "admin_main")
            buttons = [
                [InlineKeyboardButton("⏱ تریگر زمان (ساعت)", callback_data="trigger_time")],
                [InlineKeyboardButton("💾 تریگر حجم (گیگابایت)", callback_data="trigger_data")],
                [InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")],
            ]
            await query.edit_message_text("کدام تریگر را می‌خواهید تنظیم کنید؟", reply_markup=InlineKeyboardMarkup(buttons))
            return

        if data == "set_alerts":
            push_admin_stack(context, "admin_main")
            buttons = [
                [InlineKeyboardButton("⏳ هشدار زمان باقی مانده", callback_data="alert_time_left")],
                [InlineKeyboardButton("⏰ هشدار اتمام زمان", callback_data="alert_time_end")],
                [InlineKeyboardButton("📦 هشدار حجم باقی مانده", callback_data="alert_data_left")],
                [InlineKeyboardButton("❌ هشدار اتمام حجم", callback_data="alert_data_end")],
                [InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")],
            ]
            await query.edit_message_text("کدام پیام هشدار را می‌خواهید تنظیم کنید؟", reply_markup=InlineKeyboardMarkup(buttons))
            return

        if data == "trigger_time":
            push_admin_stack(context, "set_triggers")
            context.user_data["awaiting_trigger_time"] = True
            await query.edit_message_text("لطفاً مقدار تریگر زمان را وارد کنید (ساعت):", reply_markup=back_button_admin())
            return

        if data == "trigger_data":
            push_admin_stack(context, "set_triggers")
            context.user_data["awaiting_trigger_data"] = True
            await query.edit_message_text("لطفاً مقدار تریگر حجم را وارد کنید (گیگابایت):", reply_markup=back_button_admin())
            return

        if data.startswith("alert_"):
            push_admin_stack(context, "set_alerts")
            context.user_data["awaiting_alert_type"] = data
            await query.edit_message_text("لطفاً متن پیام هشدار را وارد کنید:", reply_markup=back_button_admin())
            return

# -------------------
# هندلر پیام‌ها
async def message_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    text = update.message.text

    # کاربران
    if context.user_data.get("awaiting_username"):
        if not panels_data["panels"]:
            await update.message.reply_text(
                "فعلاً هیچ پنلی ثبت نشده است.",
                reply_markup=get_user_buttons(user_id)
            )
            context.user_data["awaiting_username"] = False
            return

        panel = panels_data["panels"][0]
        users_data[str(user_id)] = {
            "username": text,
            "panel_url": panel["url"],
            "panel_token": panel["token"],
            "sent_alerts": []
        }
        save_json(USERS_FILE, users_data)
        context.user_data["awaiting_username"] = False
        await update.message.reply_text(
            f"ثبت نام موفق! نام کاربری شما: {text}\nاکانت شما به پنل {panel['url']} اختصاص داده شد.",
            reply_markup=get_user_buttons(user_id)
        )
        return

    # ادمین
    if context.user_data.get("awaiting_panel_url"):
        context.user_data["panel_url_temp"] = text
        context.user_data["awaiting_panel_url"] = False
        context.user_data["awaiting_panel_username"] = True
        await update.message.reply_text("لطفاً یوزرنیم پنل را وارد کنید:", reply_markup=back_button_admin())
        return

    if context.user_data.get("awaiting_panel_username"):
        context.user_data["panel_username_temp"] = text
        context.user_data["awaiting_panel_username"] = False
        context.user_data["awaiting_panel_password"] = True
        await update.message.reply_text("لطفاً پسورد پنل را وارد کنید:", reply_markup=back_button_admin())
        return

    if context.user_data.get("awaiting_panel_password"):
        password = text
        panel_url = context.user_data.pop("panel_url_temp")
        username = context.user_data.pop("panel_username_temp")
        context.user_data["awaiting_panel_password"] = False
        clear_admin_awaits(context)
        context.user_data["admin_stack"] = []
        try:
            token = client.get_token(panel_url, username, password)
            panels_data["panels"].append({"url": panel_url, "token": token})
            save_json(PANELS_FILE, panels_data)
            await update.message.reply_text("پنل با موفقیت اضافه شد!", reply_markup=admin_menu())
        except Exception as e:
            await update.message.reply_text(f"خطا در افزودن پنل: {e}", reply_markup=admin_menu())
        return

    if context.user_data.get("awaiting_new_admin"):
        try:
            new_admin_id = int(text)
            if new_admin_id not in ADMIN_IDS:
                ADMIN_IDS.append(new_admin_id)
                admins_data["admins"] = ADMIN_IDS
                save_json(ADMINS_FILE, admins_data)
            context.user_data["awaiting_new_admin"] = False
            context.user_data["admin_stack"] = []
            await update.message.reply_text(f"ادمین با چت‌آیدی {new_admin_id} اضافه شد.", reply_markup=admin_menu())
        except ValueError:
            await update.message.reply_text("لطفاً یک عدد معتبر وارد کنید.", reply_markup=back_button_admin())
        return

    if context.user_data.get("awaiting_trigger_time"):
        triggers_data["time_hours"] = int(text)
        save_json(TRIGGERS_FILE, triggers_data)
        context.user_data["awaiting_trigger_time"] = False
        context.user_data["admin_stack"] = []
        await update.message.reply_text(f"تریگر زمان با موفقیت روی {text} ساعت تنظیم شد.", reply_markup=admin_menu())
        return

    if context.user_data.get("awaiting_trigger_data"):
        triggers_data["data_gb"] = float(text)
        save_json(TRIGGERS_FILE, triggers_data)
        context.user_data["awaiting_trigger_data"] = False
        context.user_data["admin_stack"] = []
        await update.message.reply_text(f"تریگر حجم با موفقیت روی {text} گیگابایت تنظیم شد.", reply_markup=admin_menu())
        return

    if context.user_data.get("awaiting_alert_type"):
        alert_type = context.user_data.pop("awaiting_alert_type")
        alerts_data[alert_type] = text
        save_json(ALERTS_FILE, alerts_data)
        context.user_data["admin_stack"] = []
        await update.message.reply_text(f"پیام هشدار '{alert_type}' با موفقیت ذخیره شد.", reply_markup=admin_menu())
        return

# -------------------
# هشدار خودکار
async def run_alert_job(context: ContextTypes.DEFAULT_TYPE):
    for user_id, udata in users_data.items():
        username = udata.get("username")
        if not username:
            continue
        try:
            client.login_to_panel({"url": udata["panel_url"], "token": udata["panel_token"]})
            info = client.get_user_info(username)
            remaining_gb = client.bytes_to_gb(float(info["data_limit"]) - float(info["used_traffic"]))
            expire_days = client.calculate_days_remaining(int(info["expire"]))
        except:
            continue

        sent_alerts = udata.get("sent_alerts", [])

        if "data_gb" in triggers_data and remaining_gb <= triggers_data["data_gb"]:
            if "alert_data_left" not in sent_alerts:
                msg = alerts_data.get("alert_data_left", f"حجم باقی مانده شما: {remaining_gb} گیگابایت")
                await context.bot.send_message(chat_id=int(user_id), text=msg)
                sent_alerts.append("alert_data_left")
        if remaining_gb <= 0:
            if "alert_data_end" not in sent_alerts:
                msg = alerts_data.get("alert_data_end", "حجم شما تمام شد!")
                await context.bot.send_message(chat_id=int(user_id), text=msg)
                sent_alerts.append("alert_data_end")
        if "time_hours" in triggers_data and expire_days <= triggers_data["time_hours"]:
            if "alert_time_left" not in sent_alerts:
                msg = alerts_data.get("alert_time_left", f"زمان باقی مانده: {expire_days} روز")
                await context.bot.send_message(chat_id=int(user_id), text=msg)
                sent_alerts.append("alert_time_left")
        if expire_days <= 0:
            if "alert_time_end" not in sent_alerts:
                msg = alerts_data.get("alert_time_end", "زمان اکانت شما تمام شد!")
                await context.bot.send_message(chat_id=int(user_id), text=msg)
                sent_alerts.append("alert_time_end")

        udata["sent_alerts"] = sent_alerts

    save_json(USERS_FILE, users_data)

# -------------------
# اجرای بات
app = ApplicationBuilder().token(BOT_TOKEN).build()
app.add_handler(CommandHandler("start", start))
app.add_handler(CallbackQueryHandler(button))
app.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), message_handler))

app.job_queue.run_repeating(run_alert_job, interval=60, first=10)

app.run_polling()
EOF

# فایل marzban.py
cat > marzban.py <<'EOF'
import requests
import time
from datetime import datetime
import math

class MarzbanClient:
    def __init__(self):
        self.base_url = None
        self.token = None

    def get_token(self, base_url, username, password):
        if not base_url.endswith("/api"):
            base_url = base_url.rstrip("/") + "/api"
        self.base_url = base_url

        data = {
            "grant_type": "password",
            "username": username,
            "password": password
        }

        try:
            resp = requests.post(f"{base_url}/admin/token", data=data, verify=False)
            resp.raise_for_status()
            result = resp.json()
            self.token = result.get("access_token")
            return self.token
        except requests.exceptions.RequestException as e:
            raise Exception(f"خطا در دریافت توکن: {e}")

    def set_base_url(self, base_url):
        if not base_url.endswith("/api"):
            base_url = base_url.rstrip("/") + "/api"
        self.base_url = base_url

    def set_token(self, token):
        self.token = token

    def get_user_info(self, username):
        if not self.base_url or not self.token:
            raise Exception("base_url یا token تنظیم نشده است.")
        headers = {"Authorization": f"Bearer {self.token}"}
        try:
            resp = requests.get(f"{self.base_url}/user/{username}", headers=headers, verify=False)
            resp.raise_for_status()
            data = resp.json()
            if isinstance(data.get("expire"), str):
                dt = datetime.fromisoformat(data["expire"])
                data["expire"] = int(dt.timestamp())
            if isinstance(data.get("online_at"), str):
                dt = datetime.fromisoformat(data["online_at"])
                data["online_at"] = int(dt.timestamp())
            return data
        except requests.exceptions.RequestException as e:
            raise Exception(f"خطا در دریافت اطلاعات کاربر: {e}")

    @staticmethod
    def bytes_to_gb(bytes_value):
        return round(bytes_value / (1024 ** 3), 2)

    @staticmethod
    def calculate_days_remaining(expire_timestamp):
        now_ts = int(time.time())
        seconds_remaining = max(expire_timestamp - now_ts, 0)
        return math.ceil(seconds_remaining / 86400)

    def login_to_panel(self, panel):
        self.set_base_url(panel["url"])
        self.set_token(panel["token"])
EOF

# فایل های خالی JSON دیگر
touch users.json panels.json triggers.json alerts.json

# ==========================
# ساخت سرویس systemd
# ==========================
SERVICE_FILE="/etc/systemd/system/marzban_bot.service"

echo "=== ایجاد سرویس systemd ..."
cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Marzban Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_DIR
ExecStart=$VENV_DIR/bin/python $PROJECT_DIR/bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# ریفرش systemd و استارت سرویس
systemctl daemon-reload
systemctl enable marzban_bot.service
systemctl start marzban_bot.service

echo "=== نصب و راه‌اندازی ربات کامل شد."
echo "برای مشاهده وضعیت سرویس: systemctl status marzban_bot.service"
