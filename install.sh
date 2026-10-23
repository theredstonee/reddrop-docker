#!/usr/bin/env bash
# RedDrop — Installation auf einem Linux-Server (Debian/Ubuntu, auch RHEL-Verwandte).
# Aufruf im Ordner mit den Dateien:  sudo bash install.sh
#
# Zwei Wege nach aussen, der Installer erkennt selbst, welcher passt:
#   Caddy  — Port 80/443 sind frei: eigener Caddy mit automatischem HTTPS (Let's Encrypt).
#   Port   — Port 80/443 sind schon belegt (nginx, Apache, Plesk …): die App bekommt einen freien
#            Port auf 127.0.0.1, dein Webserver bekommt einen Virtual Host fuer die Domain.
#
# Schalter (optional):  --port 8080  --domain drop.firma.de  --email du@firma.de
#                       --caddy (Caddy erzwingen)  --no-vhost (keinen Virtual Host anlegen)
# Ein zweiter Aufruf aktualisiert nur (Image ziehen, neu starten) und fragt nichts mehr.
set -euo pipefail
cd "$(dirname "$0")"

PORT=""; DOMAIN=""; EMAIL=""; MODUS=""; VHOST="ja"
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; MODUS="port"; shift 2 ;;
    --domain) DOMAIN="${2,,}"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --caddy) MODUS="caddy"; shift ;;
    --no-vhost) VHOST="nein"; shift ;;
    *) echo "Unbekannter Schalter: $1"; exit 1 ;;
  esac
done
# Zum Testen: RD_DRY_RUN=1 zeigt Aenderungen am Webserver nur an, statt sie auszufuehren.
tu() { if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    (Probelauf) $*"; else "$@"; fi; }
frage() { # frage "Text" "Vorgabe" -> Antwort (ohne Terminal: Vorgabe)
  local antwort=""
  if [ -t 0 ]; then read -r -p "$1 [$2] " antwort </dev/tty || true; fi
  echo "${antwort:-$2}"
}
ja() { # ja "Text" "J" -> 0 bei ja
  local a; a=$(frage "$1 (j/n)" "$2"); case "${a,,}" in j|ja|y|yes) return 0 ;; *) return 1 ;; esac
}
belegt() { # lauscht etwas auf dem Port?
  if command -v ss >/dev/null 2>&1; then ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}
wer_lauscht() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//'; }

echo "==> RedDrop wird eingerichtet"

# 1. Docker (falls noch nicht da)
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker wird installiert …"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "FEHLER: 'docker compose' fehlt. Bitte Docker aktualisieren."; exit 1; }
for f in docker-compose.yml compose.caddy.yml compose.port.yml Caddyfile; do
  [ -f "$f" ] || { echo "FEHLER: $f fehlt neben install.sh. Bitte alle Dateien aus dem Paket in diesen Ordner legen."; exit 1; }
done

# 2. Bei wenig Arbeitsspeicher eine Auslagerungsdatei anlegen (unter 1,5 GB RAM, noch kein Swap)
ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$ram_mb" -lt 1500 ] && [ "$(swapon --noheadings 2>/dev/null | wc -l)" -eq 0 ] && [ ! -f /swapfile ]; then
  echo "==> Nur ${ram_mb} MB RAM: lege 1 GB Auslagerungsdatei an …"
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. .env: Datenbank-Passwort nur beim ersten Mal (sonst passt es nicht mehr zur Datenbank)
if [ ! -f .env ]; then
  printf 'DB_PASSWORD=%s\nTZ=Europe/Berlin\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > .env
  chmod 600 .env
  echo "==> .env mit zufaelligem Datenbank-Passwort angelegt"
fi

# 4. Weg nach aussen festlegen — nur, solange die .env noch keinen kennt
if ! grep -q '^COMPOSE_FILE=' .env; then
  # Bestehende Installation mit altem Compose (Caddy stand noch in docker-compose.yml): Caddy behalten.
  if [ -z "$MODUS" ] && docker ps --filter "label=com.docker.compose.service=caddy" --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | grep -qx "$PWD"; then
    MODUS="caddy"
  fi
  if [ -z "$MODUS" ]; then
    if belegt 80 || belegt 443; then
      server=$(wer_lauscht 80); [ -n "$server" ] || server=$(wer_lauscht 443)
      echo ""
      echo "==> Port 80/443 sind schon belegt (${server:-unbekannter Dienst})."
      echo "    RedDrop bekommt dann einen eigenen Port auf 127.0.0.1, und dein Webserver"
      echo "    leitet die Domain dorthin weiter (Virtual Host, HTTPS ueber deinen Webserver)."
      if ja "    So einrichten? Bei Nein versucht Caddy, Port 80/443 selbst zu belegen." "j"; then MODUS="port"; else MODUS="caddy"; fi
    else
      MODUS="caddy"
    fi
  fi

  if [ "$MODUS" = "port" ]; then
    if [ -z "$PORT" ]; then
      for p in 8080 8081 8082 8088 8090 8100 8180 8280 3100 3200 9080; do belegt "$p" || { PORT=$p; break; }; done
      [ -n "$PORT" ] || { echo "FEHLER: kein freier Port gefunden. Bitte mit --port angeben."; exit 1; }
      PORT=$(frage "    Port fuer RedDrop (frei)" "$PORT")
    fi
    belegt "$PORT" && { echo "FEHLER: Port $PORT ist belegt."; exit 1; }
    [ -n "$DOMAIN" ] || DOMAIN=$(frage "    Domain, unter der das Panel laufen soll (leer = spaeter)" "")
    DOMAIN="${DOMAIN,,}"
    {
      echo "COMPOSE_FILE=docker-compose.yml:compose.port.yml"
      echo "RD_PORT=$PORT"
      echo "RD_BIND=127.0.0.1"
      echo "RD_PROXY_DOMAIN=$DOMAIN"
    } >> .env
    echo "==> App hoert auf 127.0.0.1:$PORT (ohne eigenen Caddy)"
  else
    echo "COMPOSE_FILE=docker-compose.yml:compose.caddy.yml" >> .env
    echo "==> Caddy uebernimmt Port 80/443 und holt das Zertifikat selbst"
  fi
fi
# Werte aus der .env (auch bei einem zweiten Aufruf)
PORT=$(sed -n 's/^RD_PORT=//p' .env | tail -1)
[ -n "$DOMAIN" ] || DOMAIN=$(sed -n 's/^RD_PROXY_DOMAIN=//p' .env | tail -1)
grep -q 'compose.port.yml' .env && MODUS="port" || MODUS="caddy"

# 5. Starten
# Ordner fuer Importe (Seite „Import“ → Server-Ordner), lesbar fuer den App-Nutzer (uid 1000)
mkdir -p import && chmod 755 import
if [ -d .output ]; then docker compose up -d --build; else docker compose pull && docker compose up -d; fi

# 6. Virtual Host fuer die Domain in deinem Webserver (nur im Port-Modus, nur mit Domain)
vhost_angelegt=""
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ] && [ "$VHOST" = "ja" ]; then
  webserver=""
  if command -v nginx >/dev/null 2>&1; then webserver="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then webserver="apache2"
  elif command -v httpd >/dev/null 2>&1; then webserver="httpd"
  fi
  if [ -n "$webserver" ] && ja "==> Virtual Host fuer $DOMAIN in $webserver anlegen (Backup vorhandener Dateien, Konfigtest, Neuladen)?" "j"; then
    stempel=$(date +%Y%m%d-%H%M%S)
    if [ "$webserver" = "nginx" ]; then
      if [ -d /etc/nginx/sites-enabled ]; then datei=/etc/nginx/sites-available/reddrop.conf; link=/etc/nginx/sites-enabled/reddrop.conf
      else datei=/etc/nginx/conf.d/reddrop.conf; link=""; fi
      inhalt="# RedDrop — angelegt von install.sh am $stempel
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}"
      [ -f "$datei" ] && tu cp -a "$datei" "$datei.bak-$stempel"
      if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    (Probelauf) schreibe $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      [ -n "$link" ] && tu ln -sf "$datei" "$link"
      if tu nginx -t; then tu systemctl reload nginx 2>/dev/null || tu nginx -s reload; vhost_angelegt="$webserver"
      else echo "    FEHLER: nginx -t schlaegt fehl — Datei $datei bitte pruefen (Backup: $datei.bak-$stempel)."; fi
    else
      if [ "$webserver" = "apache2" ]; then datei=/etc/apache2/sites-available/reddrop.conf; else datei=/etc/httpd/conf.d/reddrop.conf; fi
      inhalt="# RedDrop — angelegt von install.sh am $stempel
<VirtualHost *:80>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:$PORT/
    ProxyPassReverse / http://127.0.0.1:$PORT/
    RequestHeader set X-Forwarded-Proto \"expr=%{REQUEST_SCHEME}\"
</VirtualHost>"
      [ -f "$datei" ] && tu cp -a "$datei" "$datei.bak-$stempel"
      if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    (Probelauf) schreibe $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      if [ "$webserver" = "apache2" ]; then
        tu a2enmod -q proxy proxy_http headers
        tu a2ensite -q reddrop.conf
        if tu apache2ctl configtest; then tu systemctl reload apache2; vhost_angelegt="$webserver"; else echo "    FEHLER: Apache-Konfigtest schlaegt fehl — $datei bitte pruefen."; fi
      else
        if tu httpd -t; then tu systemctl reload httpd; vhost_angelegt="$webserver"; else echo "    FEHLER: httpd -t schlaegt fehl — $datei bitte pruefen."; fi
      fi
    fi
  elif [ -z "$webserver" ]; then
    echo "==> Keinen nginx/Apache gefunden — die Vorlage fuer deinen Webserver steht unten."
  fi

  # 7. Zertifikat per certbot (HTTP-01 ueber den gerade angelegten Virtual Host)
  if [ -n "$vhost_angelegt" ]; then
    plugin="nginx"; [ "$vhost_angelegt" = "nginx" ] || plugin="apache"
    meine_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    domain_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$meine_ip" ] && [ "$domain_ip" != "$meine_ip" ]; then
      echo "==> $DOMAIN zeigt auf '${domain_ip:-nichts}', dieser Server hat $meine_ip — Zertifikat spaeter holen:"
      echo "    certbot --$plugin -d $DOMAIN --redirect"
    elif ja "==> HTTPS-Zertifikat fuer $DOMAIN mit certbot holen (Let's Encrypt)?" "j"; then
      if ! command -v certbot >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then tu apt-get install -y -qq certbot "python3-certbot-$plugin"
        elif command -v dnf >/dev/null 2>&1; then tu dnf install -y -q certbot "python3-certbot-$plugin"
        else echo "    certbot fehlt und konnte nicht installiert werden — bitte von Hand: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
      if command -v certbot >/dev/null 2>&1 || [ "${RD_DRY_RUN:-}" = "1" ]; then
        [ -n "$EMAIL" ] || EMAIL=$(frage "    E-Mail fuer Ablauf-Hinweise von Let's Encrypt (leer = keine)" "")
        if [ -n "$EMAIL" ]; then mail_arg=(-m "$EMAIL"); else mail_arg=(--register-unsafely-without-email); fi
        if tu certbot "--$plugin" -d "$DOMAIN" --redirect -n --agree-tos "${mail_arg[@]}"; then https_ok=1
        else echo "    certbot hat nicht geklappt (Ausgabe oben). Spaeter nochmal: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
    fi
  fi
fi

# 8. Auf die App warten und den Setup-Code zeigen
echo "==> Warte auf den Start …"
for _ in $(seq 1 60); do
  if docker compose logs app 2>/dev/null | grep -q 'Setup-Code\|bereit\|ready'; then break; fi
  sleep 2
done
ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
docker compose logs app 2>/dev/null | grep -A1 -B2 'Setup-Code' | tail -5 || true
echo ""
if [ "$MODUS" = "port" ]; then
  if [ -n "$vhost_angelegt" ]; then
    if [ -n "${https_ok:-}" ]; then echo "==> Fertig. Oeffne im Browser:  https://${DOMAIN}"; else echo "==> Fertig. Oeffne im Browser:  http://${DOMAIN}"; fi
  else
    echo "==> Fertig. Die App hoert auf 127.0.0.1:${PORT}. Trage in deinem Webserver einen Virtual Host ein:"
    echo ""
    echo "    nginx:                                                 Apache:"
    echo "    server {                                               <VirtualHost *:80>"
    echo "        listen 80;                                             ServerName ${DOMAIN:-drop.deinefirma.de}"
    echo "        server_name ${DOMAIN:-drop.deinefirma.de};          ProxyPreserveHost On"
    echo "        location / {                                           ProxyPass / http://127.0.0.1:${PORT}/"
    echo "            proxy_pass http://127.0.0.1:${PORT};               ProxyPassReverse / http://127.0.0.1:${PORT}/"
    echo "            proxy_set_header Host \$host;                       RequestHeader set X-Forwarded-Proto \"expr=%{REQUEST_SCHEME}\""
    echo "            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;   </VirtualHost>"
    echo "            proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        }"
    echo "    }"
    echo ""
    echo "    HTTPS danach z. B. mit:  certbot --nginx -d ${DOMAIN:-drop.deinefirma.de} --redirect"
    echo "    Zum Ausprobieren ohne Domain:  ssh -L ${PORT}:127.0.0.1:${PORT} root@${ip}  und dann  http://127.0.0.1:${PORT}"
  fi
  echo "    Im Assistenten ist „Hinter eigenem Proxy“ mit deiner Domain schon vorgewaehlt."
else
  echo "==> Fertig. Oeffne im Browser:  http://${ip}"
  echo "    Firewall: Port 80 und 443 muessen von aussen erreichbar sein."
fi
echo "    Den Setup-Code siehst du oben (oder: docker compose logs app | grep Setup-Code)."
