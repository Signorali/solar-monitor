#!/usr/bin/env bash
# ============================================================================
# Solar Monitor - CasaOS-tarzi TEK-KOMUT kurulum
# ----------------------------------------------------------------------------
# Formatli bos bir Raspberry Pi'de tek satir:
#   curl -fsSL https://raw.githubusercontent.com/Signorali/solar-monitor/main/install.sh | bash
#
# Yaptigi: Docker + bluez + udev/cihaz + /opt kurar, imajlari Docker Hub'dan
# ceker, sonra bir WEB KURULUM SIHIRBAZI acar. O sayfadan yedegini yukle ->
# veritabani + ayarlar geri yuklenir -> tum sistem calisir. Qnap KULLANILMAZ.
# ============================================================================
set -euo pipefail
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Signorali/solar-monitor/main}"
DIR="${SOLAR_DIR:-$HOME/solar-monitor}"
PORT="${SETUP_PORT:-8888}"
SUDO="sudo"; [ "$(id -u)" = 0 ] && SUDO=""

echo "============================================================"
echo " Solar Monitor - kurulum basliyor"
echo "============================================================"

# 1) Docker
if ! command -v docker >/dev/null 2>&1; then
  echo ">>> Docker kuruluyor (get.docker.com)..."
  curl -fsSL https://get.docker.com | sh
  $SUDO usermod -aG docker "$USER" || true
fi
$SUDO docker compose version >/dev/null 2>&1 || { echo "HATA: 'docker compose' v2 eklentisi yok."; exit 1; }

# 2) bluez (BLE) + python3 (sihirbaz) + tar/curl
if ! command -v bluetoothctl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  $SUDO apt-get update -y && $SUDO apt-get install -y bluez python3 curl tar || true
fi
$SUDO usermod -aG dialout "$USER" || true

# 3) deploy dosyalarini indir
echo ">>> Kurulum dosyalari indiriliyor..."
mkdir -p "$DIR/db/init" "$DIR/proxy"
for f in solar.stack.yaml restore.sh setup-wizard.py Caddyfile 99-solar-serial.rules; do
  curl -fsSL "$REPO_RAW/$f" -o "$DIR/$f"
done
curl -fsSL "$REPO_RAW/db/init/01_schema.sql"          -o "$DIR/db/init/01_schema.sql"
curl -fsSL "$REPO_RAW/db/init/02_initial_sensors.sql" -o "$DIR/db/init/02_initial_sensors.sql"
cp "$DIR/Caddyfile" "$DIR/proxy/Caddyfile"
chmod +x "$DIR/restore.sh"

# 4) host on-kosul: /dev/solar_* udev symlink'leri + /opt dizinleri
$SUDO cp "$DIR/99-solar-serial.rules" /etc/udev/rules.d/ 2>/dev/null || true
$SUDO udevadm control --reload-rules 2>/dev/null || true; $SUDO udevadm trigger 2>/dev/null || true
$SUDO mkdir -p /opt/solar-golden /opt/solar-reboot && $SUDO chmod 777 /opt/solar-golden /opt/solar-reboot

# 5) imajlari onden cek (public depo -> login gerekmez)
echo ">>> Docker Hub imajlari cekiliyor (signorali/solar-*)..."
for img in solar-backend solar-frontend solar-ble_gateway; do $SUDO docker pull "signorali/$img:latest" || true; done

# 6) tek-seferlik kod + web sihirbazi
TOKEN="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$IP" ] && IP="<pi-ip>"
echo ""
echo "============================================================"
echo " ✓ Hazir. Tarayicidan KURULUM SIHIRBAZINI ac:"
echo ""
echo "       http://$IP:$PORT"
echo ""
echo "   Tek-seferlik kod:   $TOKEN"
echo ""
echo "   -> O sayfadan yedegini yukle, sistem calismaya baslasin."
echo "      (Sonra panel: http://$IP/   ·   TV panosu: http://$IP/tv/)"
echo "============================================================"
SOLAR_DIR="$DIR" SETUP_TOKEN="$TOKEN" SETUP_PORT="$PORT" $SUDO -E python3 "$DIR/setup-wizard.py"
