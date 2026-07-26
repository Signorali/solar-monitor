# Solar Monitor — tek-komut kurulum + web yedek geri yükleme

Formatlı **boş bir Raspberry Pi**'de tek satır → sistem kendini kurar → açılan web
sihirbazından yedeğini yükle → çalışmaya başlar. (Qnap kullanılmaz.)

## Kurulum (tek link)

Yeni Pi'de bir terminal aç ve şunu yapıştır:

```bash
curl -fsSL https://raw.githubusercontent.com/Signorali/solar-monitor/main/install.sh | bash
```

Bu komut:
1. Docker + `docker compose` + **bluez** (BLE) kurar, `dialout` grubunu ekler,
2. `/dev/solar_*` için **udev** kuralını + `/opt` dizinlerini ayarlar,
3. imajları **Docker Hub**'dan çeker (`signorali/solar-backend|frontend|ble_gateway`),
4. bir **web kurulum sihirbazı** açar: `http://<pi-ip>:8888` + terminalde bir **tek-seferlik kod**.

## Yedeği yükle (web)

Tarayıcıdan `http://<pi-ip>:8888` aç → tek-seferlik kodu gir → `solar-backup-*.tgz`
dosyasını yükle → **Yedeği Yükle & Kur**. Sihirbaz veritabanını (TimescaleDB-güvenli)
ve ayarları geri yükler, tüm stack'i başlatır. Bitince:

- Panel: `http://<pi-ip>/`
- TV panosu: `http://<pi-ip>/tv/`

Yedeğin yoksa **Sıfırdan Başlat** ile boş bir sistem de kurabilirsin (yeni admin parolası üretilir).

## Yedek nasıl alınır (mevcut/çalışan Pi'de)

```bash
HUB_USER=signorali bash ~/solar-monitor/deploy/backup-dump.sh
scp ali@<pi>:/home/ali/YEDEK/solar-backup-*.tgz .   # dizüstüne indir
```

## Notlar
- Depo **public**; içinde **gizli bilgi yoktur** (parolalar yalnız senin `.tgz` yedeğinde).
- TimescaleDB imajı `2.27.1-pg16`'ya sabitlenmiştir (yedeğin sürümüyle uyumlu; downgrade olmaz).
- Seri cihazlar (MPPT/İnverter/BMS) doğru USB portlarına takılı olmalı (udev port topolojisine göre eşler).
- Uzaktan erişim istersen: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`.

## Dosyalar
`install.sh` · `setup-wizard.py` (web sihirbazı) · `solar.stack.yaml` (compose) ·
`restore.sh` (TimescaleDB-güvenli geri yükleme) · `Caddyfile` · `db/init/` (şema) · `99-solar-serial.rules` (udev)
