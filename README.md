# SSH Tunnel (ایران ← خارج)

تانل ساده پورت‌فوروارد با SSH: سرور ایران روی پورت‌های انتخابی (پیش‌فرض `443 2053 2083 2087 2096 8443`) گوش می‌دهد و ترافیک را از داخل یک اتصال SSH به `127.0.0.1` همان پورت روی سرور خارج می‌فرستد.

- روی خارج یک **sshd جداگانه** (پورت، کلید، سرویس و کاربر مخصوص خودش) ساخته می‌شود؛ به sshd اصلی (پورت 22)، کلیدهای root، WaterWall و x-ui **دست نمی‌زند**.
- ورود فقط با کلید، بدون شل، فقط فوروارد به `127.0.0.1:<پورت‌های مجاز>`.
- روی ایران یک سرویس systemd با `ssh -N -L` که در صورت قطعی خودش دوباره وصل می‌شود.
- پورت‌هایی که روی ایران اشغال هستند (x-ui / xray / WaterWall / nginx ...) تشخیص داده و با هشدار رد می‌شوند.

## نصب (یک خط)

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/ssh-tunnel/master/install.sh | sudo bash
```

### مراحل

1. **اول روی سرور خارج** دستور بالا را بزنید و گزینه `2) Install Kharej` را انتخاب کنید.
   - پورت SSH تانل (پیش‌فرض `2222`) و پورت‌های مجاز را تأیید کنید.
   - در پایان یک **کد اتصال** (یک خط طولانی) چاپ می‌شود؛ کپی‌اش کنید.
   - اگر فایروال ابری دارید، پورت `2222/tcp` را باز کنید.
2. **بعد روی سرور ایران** همان دستور را بزنید و `1) Install Iran` را انتخاب کنید.
   - کد اتصال را paste کنید.
   - پورت‌ها را تأیید کنید (پورت‌های اشغال‌شده خودکار رد می‌شوند).
3. کلاینت‌ها به **IP ایران** روی همان پورت‌ها وصل می‌شوند.

> کد اتصال شامل کلید خصوصی تانل است؛ آن را جایی منتشر نکنید.

## مدیریت

بعد از نصب، دستور `sshtun` همان منو را باز می‌کند:

```
1) Install Iran   (client)
2) Install Kharej (server)
3) Status
4) Restart
5) Edit ports
6) Show tunnel logs
7) Show connection code (Kharej)
8) Uninstall
0) Exit
```

یا مستقیم:

| دستور | کار |
|---|---|
| `sshtun status` | وضعیت |
| `sshtun restart` | ری‌استارت |
| `sshtun ports` | تغییر پورت‌ها |
| `sshtun logs` | لاگ‌ها |
| `sshtun code` | نمایش دوباره کد اتصال (خارج) |
| `sshtun uninstall` | حذف کامل |

تغییر پورت: اگر پورت جدیدی اضافه می‌کنید، اول روی **خارج** `sshtun ports` (مجاز کردن)، بعد روی **ایران** `sshtun ports`.

## نصب بدون سؤال (اختیاری)

```bash
# خارج
curl -fsSL https://raw.githubusercontent.com/khodehamed/ssh-tunnel/master/install.sh | sudo NONINTERACTIVE=1 SSH_PORT=2222 PORTS="443 2053 2083 2087 2096 8443" bash -s -- install-kharej
# ایران
curl -fsSL https://raw.githubusercontent.com/khodehamed/ssh-tunnel/master/install.sh | sudo NONINTERACTIVE=1 CODE='<کد اتصال>' bash -s -- install-iran
```

## حذف

```bash
sudo sshtun uninstall
```

سرویس `ssh-tunnel`، sshd اختصاصی، کاربر `sshtun`، کلیدها، قوانین فایروال اضافه‌شده، دستور `sshtun` و پوشه `/opt/ssh-tunnel` پاک می‌شوند.

## فایل‌ها

- `/opt/ssh-tunnel/tunnel.env` — تنظیمات
- `/etc/systemd/system/ssh-tunnel.service` — سرویس
- خارج: `/opt/ssh-tunnel/sshd_config`، `authorized_keys`، کلیدها
- ایران: `/opt/ssh-tunnel/id_ed25519`، `known_hosts`

نیازمندی: Ubuntu/Debian، دسترسی root.
