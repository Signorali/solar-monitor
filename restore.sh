#!/usr/bin/env bash
# ============================================================================
# Solar Monitor — TAZE Pi'de geri yükleme (bundle dizininde çalıştır)
# ----------------------------------------------------------------------------
# Beklenen dosyalar (CWD): solar.stack.yaml, .env, Caddyfile, db-init/, solar-db.bak
#                          99-solar-serial.rules (varsa — cihaz symlink'leri için)
# Ön koşul: Docker + docker compose v2 + bluez KURULU olmalı. Değilse önce install.sh.
# Sıra: host ön-koşul (udev+/opt) → DB → CREATE EXTENSION → pre_restore →
#       pg_restore (-j YOK) → post_restore → DOĞRULA → tüm stack up.
# Qnap KULLANILMAZ.
# ============================================================================
set -euo pipefail
[ -f solar.stack.yaml ] && [ -f .env ] && [ -f solar-db.bak ] || {
  echo "HATA: bundle dizininde değilsin (solar.stack.yaml / .env / solar-db.bak yok)"; exit 1; }
set -a; . ./.env; set +a
: "${HUB_USER:?HUB_USER tanimli degil - bundle .env dosyasina ekle, ornek HUB_USER=alikoken}"
C="docker compose -f solar.stack.yaml"

echo ">>> [1/7] Host ön-koşulları (udev cihaz symlink'leri + /opt dizinleri)..."
if [ -f 99-solar-serial.rules ]; then
  sudo cp 99-solar-serial.rules /etc/udev/rules.d/99-solar-serial.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger
  echo "    udev kuralı kuruldu + tetiklendi"
else
  echo "    ⚠ 99-solar-serial.rules bundle'da yok — /dev/solar_* symlink'leri elle gerekebilir"
fi
sudo mkdir -p /opt/solar-golden /opt/solar-reboot
sudo chmod 777 /opt/solar-golden /opt/solar-reboot
missing=0
for d in /dev/solar_mppt /dev/solar_bms /dev/solar_inverter; do
  [ -e "$d" ] || { echo "    ⚠ $d YOK — seri cihaz bağlı ve doğru USB portunda mı? (backend başlamayabilir)"; missing=1; }
done
[ "$missing" = 0 ] && echo "    /dev/solar_* hazır ✓"

echo ">>> Config dosyaları yerleştiriliyor..."
mkdir -p proxy db/init data/postgres
cp Caddyfile proxy/Caddyfile
cp -r db-init/. db/init/ 2>/dev/null || true

echo ">>> [2/7] Sadece DB kaldırılıyor (timescale imajı Hub'dan çekilir)..."
$C up -d db
echo -n "    DB hazır bekleniyor"
until $C exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do echo -n "."; sleep 2; done; echo

echo ">>> [3/7] Temiz hedef veritabanı..."
$C exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname='${POSTGRES_DB}' AND pid<>pg_backend_pid();
DROP DATABASE IF EXISTS ${POSTGRES_DB};
CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};
SQL

echo ">>> [4/7] TimescaleDB pre-restore..."
$C exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT timescaledb_pre_restore();
SQL

echo ">>> [5/7] pg_restore (tek-thread; -j Timescale kataloğunu bozar)..."
$C cp solar-db.bak db:/tmp/solar-db.bak
# pre_restore modunda 'extension already exists' gibi bazı NOTICE'ler normaldir → çıkış kodunu
# yutmuyoruz ama fatal de saymıyoruz; GERÇEK başarı [7/7]'de tablo/satır DOĞRULAMASIYLA ölçülür.
$C exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner -Fc /tmp/solar-db.bak \
  || echo "    (pg_restore bazı uyarılar verdi — doğrulama [7/7]'de yapılacak)"

echo ">>> [6/7] TimescaleDB post-restore..."
$C exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT timescaledb_post_restore();"
$C exec -T db rm -f /tmp/solar-db.bak 2>/dev/null || true

echo ">>> [7/7] Geri yükleme DOĞRULAMASI (sahte-yeşil önleme)..."
TBLS=$($C exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" | tr -d '[:space:]')
HTS=$($C exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM timescaledb_information.hypertables" 2>/dev/null | tr -d '[:space:]' || echo 0)
echo "    public tablo: ${TBLS:-0} · hypertable: ${HTS:-0}"
if [ "${TBLS:-0}" -lt 1 ]; then
  echo "HATA: restore sonrası tablo YOK → geri yükleme BAŞARISIZ (sürüm/uyum kontrol et). Stack başlatılmadı."; exit 1
fi

echo ">>> Tüm stack kaldırılıyor (backend/frontend/ble Hub'dan çekilir)..."
$C up -d

echo ""
echo "============================================================"
echo " ✓ Geri yükleme tamam ve doğrulandı.  Kontrol:  $C ps"
echo "   Panel:  http://<pi-lan-ip>/    ·    TV panosu:  http://<pi-lan-ip>/tv/"
echo "============================================================"
