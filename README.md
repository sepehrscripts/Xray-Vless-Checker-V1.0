<div align="center">

```
▣  VLESS MONITOR
```

**پنل مانیتورینگ لینک‌های VLESS با اطلاع‌رسانی تلگرام**

[![License](https://img.shields.io/badge/license-MIT-00e5a0?style=flat-square)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.10+-3b82f6?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-ff3b5c?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Flask](https://img.shields.io/badge/flask-3.x-ffc043?style=flat-square&logo=flask&logoColor=black)](https://flask.palletsprojects.com)

</div>

---

## ✦ معرفی

**VLESS Monitor** یه ابزار سبک و خودکفاست که لینک‌های VLESS شما رو هر چند دقیقه یه‌بار بررسی می‌کنه و اگه هر سروری از دسترس خارج بشه، **فوری از طریق تلگرام بهتون خبر می‌ده**.

همه چیز با یه دستور نصب میشه — بدون Docker، بدون پیچیدگی.

---

## ✦ امکانات

- 🟢 **پینگ TCP** به تمام سرورها در فواصل زمانی تنظیم‌شده
- 📨 **اطلاع‌رسانی تلگرام** به محض down شدن هر سرور
- 🌐 **وب پنل** با داشبورد لحظه‌ای، لاگ رویدادها و تنظیمات آنلاین
- 🔔 **تشخیص بازگشت سرور** — وقتی سرور دوباره آنلاین شد هم خبر میده
- ⚡ **نصب یک‌خطی** مثل 3x-ui — فقط یه دستور کافیه
- 🔁 **اجرا به‌عنوان systemd service** — بعد از ریبوت هم خودکار شروع میکنه

---

## ✦ نصب سریع

```bash
bash <(curl -Ls https://raw.githubusercontent.com/USERNAME/vless-monitor/main/install.sh)
```

> نیاز به `sudo` یا اجرا با کاربر `root` داری.

بعد از نصب، پنل وب در آدرس زیر در دسترسه:

```
http://IP-سرور:5000
```

---

## ✦ تنظیمات اولیه

بعد از نصب، از بخش **تنظیمات** پنل وب:

| مرحله | توضیح |
|-------|-------|
| ۱ | **Bot Token** رو از [@BotFather](https://t.me/BotFather) بگیر و وارد کن |
| ۲ | **Chat ID** رو از [@userinfobot](https://t.me/userinfobot) بگیر و وارد کن |
| ۳ | لینک‌های VLESS رو هر کدام در یک خط وارد کن |
| ۴ | دکمه **تست ارسال پیام** رو بزن تا مطمئن بشی همه چیز درسته |
| ۵ | **ذخیره** کن |

---

## ✦ پنل وب

| بخش | توضیح |
|-----|-------|
| **داشبورد** | وضعیت لحظه‌ای سرورها با نمایش latency و pulse animation |
| **رویدادها** | لاگ کامل up/down با تاریخ و ساعت |
| **تنظیمات** | مدیریت لینک‌ها، توکن تلگرام و فاصله بررسی |

---

## ✦ پیام تلگرام

وقتی سروری down بشه، یه پیام مثل این دریافت می‌کنی:

```
🚨 سرور(های) زیر در دسترس نیستند

• Server1  1.2.3.4:443
  تأخیر: 10043ms

• Server2  5.6.7.8:443
  تأخیر: 10021ms

🕐 2026-06-06 14:32:11
```

---

## ✦ مدیریت سرویس

```bash
# وضعیت
systemctl status vless-monitor

# مشاهده لاگ زنده
journalctl -u vless-monitor -f

# ری‌استارت
systemctl restart vless-monitor

# توقف
systemctl stop vless-monitor
```

---

## ✦ فایل‌های نصب‌شده

```
/opt/vless-monitor/
├── monitor.py        ← موتور اصلی + Flask API
├── templates/
│   └── index.html    ← وب پنل
├── config.json       ← تنظیمات (ویرایش از پنل)
├── events.json       ← لاگ رویدادها
└── venv/             ← محیط مجازی Python
```

---

## ✦ نیازمندی‌ها

- Ubuntu 22.04 / 24.04
- Python 3.10+
- دسترسی اینترنت برای ارسال پیام تلگرام
- پورت `5000` باز باشه

---

## ✦ حذف

```bash
systemctl stop vless-monitor
systemctl disable vless-monitor
rm /etc/systemd/system/vless-monitor.service
rm -rf /opt/vless-monitor
systemctl daemon-reload
```

---

## ✦ لایسنس

MIT — آزادانه استفاده، تغییر و توزیع کن.

---

<div align="center">
<sub>ساخته‌شده با Python · Flask · ❤️</sub>
</div>
