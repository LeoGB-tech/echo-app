#!/bin/bash
# Écho Store — installation automatique sur une machine Oracle Cloud « Always Free » (Ubuntu).
# À coller dans « Script cloud-init » à la création de la machine, OU à lancer en SSH :  sudo bash install-oracle.sh
set -e
export DEBIAN_FRONTEND=noninteractive
SUPABASE_URL="https://haguqqwnfzpyveexzhej.supabase.co"
SUPABASE_KEY="sb_publishable_M0DNl76L_b9XSNzZeSZ7Rg_wlxmNYmE"

# 1) logiciels : Node.js 20 + Caddy (HTTPS automatique)
apt-get update -y
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https iptables-persistent cloud-guest-utils || apt-get install -y curl ca-certificates gnupg
if ! command -v node >/dev/null || [ "$(node -v | cut -c2- | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

# 2) le serveur Écho
mkdir -p /opt/echo-store /var/lib/echo-store
cat > /opt/echo-store/server.mjs <<'ECHO_SERVER_END'
__SERVER__
ECHO_SERVER_END
[ -f /opt/echo-store/secret ] || head -c 48 /dev/urandom | base64 | tr -d '\n/+=' > /opt/echo-store/secret
id echostore >/dev/null 2>&1 || useradd --system --home /var/lib/echo-store --shell /usr/sbin/nologin echostore
chown -R echostore:echostore /var/lib/echo-store; chown echostore:echostore /opt/echo-store/secret; chmod 600 /opt/echo-store/secret
cat > /etc/systemd/system/echo-store.service <<ECHO_UNIT_END
[Unit]
Description=Echo Store
After=network-online.target
[Service]
User=echostore
Environment=PORT=8080 DATA=/var/lib/echo-store SUPABASE_URL=$SUPABASE_URL SUPABASE_KEY=$SUPABASE_KEY
ExecStart=/bin/sh -c 'SECRET=\$(cat /opt/echo-store/secret) exec /usr/bin/node /opt/echo-store/server.mjs'
Restart=always
[Install]
WantedBy=multi-user.target
ECHO_UNIT_END

# 2 bis) l'enregistreur radio (écoute les radios, ajoute les nouveaux morceaux et les podcasts à ta bibliothèque)
apt-get install -y ffmpeg
cat > /opt/echo-store/recorder.mjs <<'ECHO_REC_END'
__RECORDER__
ECHO_REC_END
cat > /etc/systemd/system/echo-recorder.service <<ECHO_UNIT2_END
[Unit]
Description=Echo enregistreur radio
After=network-online.target echo-store.service
[Service]
User=echostore
Nice=5
Environment=DATA=/var/lib/echo-store SUPABASE_URL=$SUPABASE_URL SUPABASE_KEY=$SUPABASE_KEY
ExecStart=/usr/bin/node /opt/echo-store/recorder.mjs
Restart=always
RestartSec=20
[Install]
WantedBy=multi-user.target
ECHO_UNIT2_END

# 3) adresse publique en HTTPS : <ip-avec-tirets>.sslip.io (aucun nom de domaine à acheter)
IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)
HOST="$(echo "$IP" | tr . -).sslip.io"
cat > /etc/caddy/Caddyfile <<ECHO_CADDY_END
$HOST {
  request_body {
    max_size 2GB
  }
  reverse_proxy 127.0.0.1:8080 {
    flush_interval -1
  }
}
ECHO_CADDY_END

# 4) pare-feu de la machine (les images Oracle bloquent 80/443 par défaut)
for p in 80 443; do iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $p -j ACCEPT; done
netfilter-persistent save 2>/dev/null || (mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4) || true

# 5) disque : utilise tout l'espace du disque de démarrage
ROOT=$(findmnt -n -o SOURCE /); DISK=/dev/$(lsblk -no PKNAME "$ROOT" 2>/dev/null); PART=$(echo "$ROOT" | grep -o '[0-9]*$')
[ -n "$PART" ] && growpart "$DISK" "$PART" 2>/dev/null && resize2fs "$ROOT" 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now echo-store echo-recorder
systemctl restart echo-store echo-recorder
systemctl restart caddy
echo "https://$HOST" > /opt/echo-store/adresse.txt
echo
echo "=============================================="
echo " Écho Store est prêt :  https://$HOST"
echo " Dans Écho → Réglages → Stockage Oracle, colle : $IP"
echo " Puis dans Écho → Radio → Enregistreur radio → Activer"
echo "=============================================="
