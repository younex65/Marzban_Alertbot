#!/bin/bash

set -e

echo "🔵 شروع نصب ربات هشدار Marzban ..."

INSTALL_DIR="/opt/telegram_bot"
VENV_DIR="$INSTALL_DIR/venv"

echo "📦 آپدیت مخازن..."
apt update -y && apt upgrade -y

echo "📦 نصب پیش‌نیازهای اصلی..."
apt install -y python3 python3-venv python3-pip

echo "📁 ساخت پوشه ربات..."
mkdir -p "$INSTALL_DIR"

echo "🐍 ساخت محیط مجازی پایتون..."
python3 -m venv "$VENV_DIR"

echo "🐍 فعال‌سازی محیط مجازی..."
source "$VENV_DIR/bin/activate"

echo "📦 نصب کتابخانه‌های ضروری..."
pip install --upgrade pip
pip install "python-telegram-bot[job-queue]"==20.7
pip install requests

echo "📄 ساخت فایل admin.json ..."

read -p "🔑 BOT TOKEN را وارد کنید: " BOT_TOKEN
read -p "👤 Chat ID ادمین را وارد کنید: " ADMIN_ID

cat > "$INSTALL_DIR/admin.json" <<EOF
{
    "bot_token": "$BOT_TOKEN",
    "admins": [$ADMIN_ID]
}
EOF

echo "📄 ساخت فایل bot.py (با placeholder)..."

cat > "$INSTALL_DIR/bot.py" <<'EOF'
#!/usr/bin/env python3
# coding: utf-8

import os
import json
import time
import math
import signal
import asyncio
import logging
from typing import Optional, Dict, Any

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

# ---------- Logging ----------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("telegram_bot")

# ---------- Files ----------
USERS_FILE = "users.json"
ADMINS_FILE = "admin.json"
PANELS_FILE = "panels.json"
TRIGGERS_FILE = "triggers.json"
ALERTS_FILE = "alerts.json"

# ---------- Globals (will be loaded from files) ----------
admins_data: Dict[str, Any] = {}
users_data: Dict[str, Any] = {}
panels_data: Dict[str, Any] = {}
triggers_data: Dict[str, Any] = {}
alerts_data: Dict[str, Any] = {}

BOT_TOKEN: Optional[str] = None
ADMIN_IDS = []
client = MarzbanClient()

# ---------- Helpers to load/save JSON ----------
def load_json(path: str, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default if default is not None else {}
    except json.JSONDecodeError as e:
        logger.error("خطا در خواندن JSON از %s: %s", path, e)
        return default if default is not None else {}
    except Exception as e:
        logger.exception("خطا هنگام خواندن فایل %s: %s", path, e)
        return default if default is not None else {}

def save_json(path: str, data):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
    except Exception as e:
        logger.exception("خطا هنگام نوشتن فایل %s: %s", path, e)

# ---------- Config reload (used on SIGHUP or manual call) ----------
def reload_configs():
    global admins_data, users_data, panels_data, triggers_data, alerts_data, BOT_TOKEN, ADMIN_IDS
    try:
        admins_data = load_json(ADMINS_FILE, {})
        users_data = load_json(USERS_FILE, {})
        panels_data = load_json(PANELS_FILE, {"panels": []})
        triggers_data = load_json(TRIGGERS_FILE, {})
        alerts_data = load_json(ALERTS_FILE, {})

        BOT_TOKEN = admins_data.get("bot_token")
        ADMIN_IDS = admins_data.get("admins", [])

        logger.info("پیکربندی‌ها مجدداً بارگذاری شدند. (%d admins, %d users, %d panels)",
                    len(ADMIN_IDS), len(users_data), len(panels_data.get("panels", [])))
    except Exception as e:
        logger.exception("خطا در بارگذاری پیکربندی‌ها: %s", e)

# Immediately load configs at startup
reload_configs()

# ---------- UI helpers ----------
def get_user_buttons(user_id: int) -> InlineKeyboardMarkup:
    buttons = []
    if user_id not in ADMIN_IDS:
        buttons.append([InlineKeyboardButton("✅ ثبت نام کاربری", callback_data="register")])
        buttons.append([InlineKeyboardButton("📄 مشخصات اکانت", callback_data="account_info")])
    return InlineKeyboardMarkup(buttons)

def back_button_user() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[InlineKeyboardButton("🔙 بازگشت", callback_data="user_back")]])

def admin_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🛠 افزودن پنل", callback_data="add_panel")],
        [InlineKeyboardButton("👤 افزودن ادمین", callback_data="add_admin")],
        [InlineKeyboardButton("⏱ تنظیم تریگرها", callback_data="set_triggers")],
        [InlineKeyboardButton("⚠️ تنظیم پیام‌های هشدار", callback_data="set_alerts")],
    ])

def back_button_admin() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[InlineKeyboardButton("🔙 بازگشت", callback_data="admin_back")]])

# ---------- Admin UI constants ----------
ALERT_KEYS = [
    "alert_time_left",
    "alert_time_end",
    "alert_data_left",
    "alert_data_end",
    "alert_account_deleted"
]

# ---------- Start handler ----------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if user_id in ADMIN_IDS:
        await update.message.reply_text("سلام ادمین! منوی مدیریت:", reply_markup=admin_menu())
    else:
        await update.message.reply_text("سلام! خوش آمدید.", reply_markup=get_user_buttons(user_id))

# ---------- Admin stack helpers ----------
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

# ---------- Callback button handler ----------
async def button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    data = query.data

    # reload in-memory configs if they were changed by external process recently
    # (Note: we don't reload token here because application token cannot be changed live)
    # reload_configs()  # optionally call here if you want aggressive reload

    # ------------ regular users ------------
    if user_id not in ADMIN_IDS:
        if data == "user_back":
            await query.edit_message_text("منوی اصلی:", reply_markup=get_user_buttons(user_id))
            return

        if data == "register":
            if not panels_data.get("panels"):
                await query.edit_message_text(
                    """فعلاً هیچ پنلی ثبت نشده است.
لطفاً منتظر اضافه شدن پنل توسط ادمین بمانید.""",
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
                    await query.edit_message_text(
                        f"شما قبلاً ثبت نام کرده‌اید.\nنام کاربری: {user_info['username']}",
                        reply_markup=back_button_user()
                    )
                    return
                except Exception:
                    # user not found in panel -> send account-deleted alert (if configured), remove locally
                    try:
                        msg = alerts_data.get("alert_account_deleted", "اکانت شما از پنل حذف شده است.")
                        await context.bot.send_message(chat_id=int(user_id), text=msg)
                    except Exception:
                        logger.debug("خطا در ارسال پیام حذف اکانت به کاربر %s", user_id)
                    users_data.pop(str(user_id), None)
                    save_json(USERS_FILE, users_data)
                    # continue to registration flow

            # ask for username
            context.user_data["awaiting_username"] = True
            await query.edit_message_text("لطفاً نام کاربری خود را وارد کنید:", reply_markup=back_button_user())
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
            except Exception:
                try:
                    msg = alerts_data.get("alert_account_deleted", "اکانت شما از پنل حذف شده است.")
                    await context.bot.send_message(chat_id=int(user_id), text=msg)
                except Exception:
                    logger.debug("خطا در ارسال پیام حذف اکانت به کاربر %s", user_id)
                users_data.pop(str(user_id), None)
                save_json(USERS_FILE, users_data)
                await query.edit_message_text(
                    """خطا در دریافت اطلاعات اکانت. ممکن است کاربر از پنل حذف شده باشد.
لطفاً دوباره ثبت نام کنید.""",
                    reply_markup=back_button_user()
                )
            return

    # ------------ admins ------------
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
                    [InlineKeyboardButton("⚠️ هشدار حذف اکانت از پنل", callback_data="alert_account_deleted")],
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
                [InlineKeyboardButton("⚠️ هشدار حذف اکانت از پنل", callback_data="alert_account_deleted")],
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

# ---------- Message handler ----------
async def message_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    text = update.message.text.strip() if update.message.text else ""

    # registration username
    if context.user_data.get("awaiting_username"):
        if not panels_data.get("panels"):
            await update.message.reply_text("""فعلاً هیچ پنلی ثبت نشده است.
لطفاً منتظر اضافه شدن پنل توسط ادمین بمانید.""", reply_markup=get_user_buttons(user_id))
            context.user_data["awaiting_username"] = False
            return

        panel = panels_data["panels"][0]
        users_data[str(user_id)] = {
            "username": text,
            "panel_url": panel["url"],
            "panel_token": panel["token"],
            "sent_alerts": [],
            "last_expire": None,
            "last_limit": None
        }

        try:
            client.login_to_panel({"url": panel["url"], "token": panel["token"]})
            info = client.get_user_info(text)
            users_data[str(user_id)]["last_expire"] = int(info.get("expire"))
            users_data[str(user_id)]["last_limit"] = float(info.get("data_limit"))
        except Exception:
            logger.debug("نشد که اطلاعات اولیه کاربر را از پنل بخوانیم؛ مقدارهای last_* None نگه داشته شدند")

        save_json(USERS_FILE, users_data)
        context.user_data["awaiting_username"] = False
        await update.message.reply_text(
            f"ثبت نام موفق! نام کاربری شما: {text}\nاکانت شما به پنل {panel['url']} اختصاص داده شد.",
            reply_markup=get_user_buttons(user_id)
        )
        return

    # admin flows
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
            panels = panels_data.get("panels", [])
            panels.append({"url": panel_url, "token": token})
            panels_data["panels"] = panels
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
        try:
            triggers_data["time_hours"] = int(text)
            save_json(TRIGGERS_FILE, triggers_data)
            context.user_data["awaiting_trigger_time"] = False
            context.user_data["admin_stack"] = []
            await update.message.reply_text(f"تریگر زمان با موفقیت روی {text} ساعت تنظیم شد.", reply_markup=admin_menu())
        except ValueError:
            await update.message.reply_text("لطفاً یک عدد معتبر وارد کنید.", reply_markup=back_button_admin())
        return

    if context.user_data.get("awaiting_trigger_data"):
        try:
            triggers_data["data_gb"] = float(text)
            save_json(TRIGGERS_FILE, triggers_data)
            context.user_data["awaiting_trigger_data"] = False
            context.user_data["admin_stack"] = []
            await update.message.reply_text(f"تریگر حجم با موفقیت روی {text} گیگابایت تنظیم شد.", reply_markup=admin_menu())
        except ValueError:
            await update.message.reply_text("لطفاً یک مقدار عددی معتبر وارد کنید.", reply_markup=back_button_admin())
        return

    if context.user_data.get("awaiting_alert_type"):
        alert_type = context.user_data.pop("awaiting_alert_type")
        alerts_data[alert_type] = text
        save_json(ALERTS_FILE, alerts_data)
        context.user_data["admin_stack"] = []
        await update.message.reply_text(f"پیام هشدار '{alert_type}' با موفقیت ذخیره شد.", reply_markup=admin_menu())
        return

# ---------- Alert job ----------
async def run_alert_job(context: ContextTypes.DEFAULT_TYPE):
    # We operate on the in-memory users_data; saving after modifications
    to_delete = []

    for user_id, udata in list(users_data.items()):
        username = udata.get("username")
        if not username:
            continue

        try:
            client.login_to_panel({"url": udata["panel_url"], "token": udata["panel_token"]})
            info = client.get_user_info(username)

            remaining_gb = client.bytes_to_gb(float(info.get("data_limit", 0)) - float(info.get("used_traffic", 0)))
            expire_days = client.calculate_days_remaining(int(info.get("expire", 0)))

            # reset alerts if renewed
            old_expire = udata.get("last_expire")
            old_limit = udata.get("last_limit")

            try:
                new_expire = int(info.get("expire"))
            except Exception:
                new_expire = None
            try:
                new_limit = float(info.get("data_limit"))
            except Exception:
                new_limit = None

            if (old_expire is not None and new_expire is not None and new_expire > old_expire) or \
               (old_limit is not None and new_limit is not None and new_limit > old_limit):
                udata["sent_alerts"] = []

            if new_expire is not None:
                udata["last_expire"] = new_expire
            if new_limit is not None:
                udata["last_limit"] = new_limit

        except Exception:
            # assume user removed from panel
            try:
                msg = alerts_data.get("alert_account_deleted", "اکانت شما از پنل حذف شده است.")
                await context.bot.send_message(chat_id=int(user_id), text=msg)
            except Exception:
                logger.debug("نشد پیام حذف اکانت را به کاربر %s ارسال کنیم", user_id)
            to_delete.append(str(user_id))
            continue

        sent_alerts = udata.get("sent_alerts", [])

        # data left
        if "data_gb" in triggers_data and remaining_gb <= triggers_data["data_gb"]:
            if "alert_data_left" not in sent_alerts:
                msg = alerts_data.get("alert_data_left", f"حجم باقی مانده شما: {remaining_gb} گیگابایت")
                try:
                    await context.bot.send_message(chat_id=int(user_id), text=msg)
                except Exception:
                    logger.debug("خطا در ارسال پیام alert_data_left به %s", user_id)
                sent_alerts.append("alert_data_left")

        # data end
        if remaining_gb <= 0:
            if "alert_data_end" not in sent_alerts:
                msg = alerts_data.get("alert_data_end", "حجم شما تمام شد!")
                try:
                    await context.bot.send_message(chat_id=int(user_id), text=msg)
                except Exception:
                    logger.debug("خطا در ارسال پیام alert_data_end به %s", user_id)
                sent_alerts.append("alert_data_end")

        # time left
        if "time_hours" in triggers_data and expire_days <= triggers_data["time_hours"]:
            if "alert_time_left" not in sent_alerts:
                msg = alerts_data.get("alert_time_left", f"زمان باقی مانده: {expire_days} روز")
                try:
                    await context.bot.send_message(chat_id=int(user_id), text=msg)
                except Exception:
                    logger.debug("خطا در ارسال پیام alert_time_left به %s", user_id)
                sent_alerts.append("alert_time_left")

        # time end
        if expire_days <= 0:
            if "alert_time_end" not in sent_alerts:
                msg = alerts_data.get("alert_time_end", "زمان اکانت شما تمام شد!")
                try:
                    await context.bot.send_message(chat_id=int(user_id), text=msg)
                except Exception:
                    logger.debug("خطا در ارسال پیام alert_time_end به %s", user_id)
                sent_alerts.append("alert_time_end")

        udata["sent_alerts"] = sent_alerts

    # persist deletions
    if to_delete:
        for uid in to_delete:
            users_data.pop(uid, None)
        save_json(USERS_FILE, users_data)
        logger.info("تعداد %d کاربر از users.json حذف شدند (از پنل پاک شده بودند).", len(to_delete))

# ---------- Signal handler for reload ----------
def _sighup_handler():
    logger.info("SIGHUP دریافت شد — بارگذاری مجدد پیکربندی‌ها.")
    reload_configs()

def install_signal_handlers(loop: Optional[asyncio.AbstractEventLoop] = None):
    # Best-effort: only install signal handlers on UNIX
    try:
        if loop is None:
            loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGHUP, _sighup_handler)
        logger.info("Signal handler for SIGHUP نصب شد (برای reload پیکربندی‌ها).")
    except NotImplementedError:
        logger.warning("Signal handlers پشتیبانی نشده است (شاید در ویندوز هستید).")
    except Exception as e:
        logger.exception("خطا در نصب signal handler: %s", e)

# ---------- Main: build app and run ----------
def main():
    global BOT_TOKEN

    if not BOT_TOKEN:
        logger.error("توکن بات در admin.json پیدا نشد! لطفاً admin.json را تنظیم کنید.")
        raise SystemExit(1)

    application = ApplicationBuilder().token(BOT_TOKEN).build()

    application.add_handler(CommandHandler("start", start))
    application.add_handler(CallbackQueryHandler(button))
    application.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), message_handler))

    # schedule job: use job_queue of application
    # every 60 seconds by default; you can change interval in triggers.json or here
    run_interval = 60
    try:
        run_interval = int(triggers_data.get("job_interval_seconds", 60))
    except Exception:
        run_interval = 60

    application.job_queue.run_repeating(run_alert_job, interval=run_interval, first=10)

    # install signal handlers for SIGHUP to reload config
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        install_signal_handlers(loop)
    except Exception:
        pass

    logger.info("بات راه‌اندازی می‌شود. (token present: %s...)",
                (BOT_TOKEN[:8] + "...") if BOT_TOKEN else "NO_TOKEN")

    # run application (this will manage its own event loop)
    # we use .run_polling() which is blocking
    try:
        application.run_polling()
    except KeyboardInterrupt:
        logger.info("دریافت SIGINT — خروج.")
    except Exception:
        logger.exception("خطا هنگام اجرای بات:")

if __name__ == "__main__":
    main()

EOF

echo "📄 ساخت فایل marzban.py (با placeholder)..."

cat > "$INSTALL_DIR/marzban.py" <<'EOF'
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


echo "⚙️ ساخت سرویس systemd..."

cat > /etc/systemd/system/telegrambot.service <<EOF
[Unit]
Description=Telegram Alert Bot (Marzban)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/bot.py
Restart=always
RestartSec=3

# Reload config without restart
ExecReload=/bin/kill -HUP \$MAINPID

User=root

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 ریلود systemd..."
systemctl daemon-reload

echo "▶️ فعال‌سازی و اجرای سرویس..."
systemctl enable telegrambot
systemctl start telegrambot

echo "✅ نصب با موفقیت انجام شد!"
echo "📌 فایل‌ها ایجاد شدند:"
echo "   $INSTALL_DIR/bot.py"
echo "   $INSTALL_DIR/marzban.py"
echo "📌 لطفاً جایگزین‌کردن کد اصلی را فراموش نکنید."
echo "📌 برای مشاهده لاگ‌ها:"
echo "   journalctl -fu telegrambot"
echo "📌 برای Reload (اعمال تغییرات بدون ری‌استارت):"
echo "   systemctl reload telegrambot"
