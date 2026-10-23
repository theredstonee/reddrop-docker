#!/usr/bin/env bash
# RedDrop — Installation auf einem Linux-Server (Debian/Ubuntu, auch RHEL-Verwandte).
# Einzeiler (legt alles nach /opt/reddrop, anderer Ordner: RD_DIR=/pfad davor):
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/install.sh | sudo bash
# Oder im Ordner mit den Dateien:  sudo bash install.sh
# Entfernen:  sudo bash /opt/reddrop/install.sh --deinstallieren
#
# Zwei Wege nach aussen, der Installer erkennt selbst, welcher passt:
#   Caddy  — Port 80/443 sind frei: eigener Caddy mit automatischem HTTPS (Let's Encrypt).
#   Port   — Port 80/443 sind schon belegt (nginx, Apache, Plesk …): die App bekommt einen freien
#            Port auf 127.0.0.1, dein Webserver bekommt einen Virtual Host fuer die Domain.
#
# Schalter (optional):  --port 8080  --domain drop.firma.de  --email du@firma.de
#                       --caddy (Caddy erzwingen)  --no-vhost (keinen Virtual Host anlegen)
#                       --deinstallieren (Container, Webserver-Eintraege und auf Wunsch alle Daten entfernen)
# Ein zweiter Aufruf aktualisiert nur (Image ziehen, neu starten) und fragt nichts mehr.
set -euo pipefail
QUELLE="https://raw.githubusercontent.com/theredstonee/reddrop-docker/main"
DATEIEN="docker-compose.yml compose.caddy.yml compose.port.yml compose.node.yml Caddyfile install.sh .env.example README.md"
# Ueber curl | bash gestartet (oder Dateien fehlen): alles nach /opt/reddrop holen und dort weitermachen
if [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; then
  cd "$(dirname "$0")"
else
  ZIEL="${RD_DIR:-/opt/reddrop}"
  echo "==> Hole die Installationsdateien nach $ZIEL"
  mkdir -p "$ZIEL" && cd "$ZIEL"
  for f in $DATEIEN; do curl -fsSL -o "$f" "$QUELLE/$f" || { echo "FEHLER: $f konnte nicht geladen werden."; exit 1; }; done
  # Fragen brauchen das Terminal (stdin ist bei curl | bash die Leitung) — ohne Terminal gelten die Vorgaben
  if { true </dev/tty; } 2>/dev/null; then exec bash ./install.sh "$@" </dev/tty; else exec bash ./install.sh "$@"; fi
fi

PORT=""; DOMAIN=""; EMAIL=""; MODUS=""; VHOST="ja"; WEG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; MODUS="port"; shift 2 ;;
    --domain) DOMAIN="${2,,}"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --caddy) MODUS="caddy"; shift ;;
    --no-vhost) VHOST="nein"; shift ;;
    --deinstallieren|--uninstall) WEG="ja"; shift ;;
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

# Deinstallieren: Container weg, Webserver-Eintraege weg (mit Backup), auf Wunsch auch alle Daten und der Ordner
if [ -n "$WEG" ]; then
  echo "==> RedDrop entfernen (Ordner: $PWD)"
  daten="nein"
  if ja "    Auch ALLE hochgeladenen Dateien und die Datenbank loeschen? Das laesst sich nicht rueckgaengig machen." "n"; then
    bestaetigt=$(frage "    Zur Bestaetigung bitte  loeschen  eintippen" "")
    [ "$bestaetigt" = "loeschen" ] && daten="ja" || { echo "    Nicht bestaetigt — Dateien und Datenbank bleiben erhalten."; }
  fi
  if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
    if [ "$daten" = "ja" ]; then docker compose down -v --remove-orphans || true; else docker compose down --remove-orphans || true; fi
    docker image rm ghcr.io/theredstonee/reddrop:latest >/dev/null 2>&1 || true
  fi
  stempel=$(date +%Y%m%d-%H%M%S); neu_laden=""
  for datei in /etc/nginx/sites-enabled/reddrop.conf /etc/nginx/sites-enabled/reddrop-setup.conf /etc/nginx/sites-available/reddrop.conf /etc/nginx/sites-available/reddrop-setup.conf \
               /etc/nginx/conf.d/reddrop.conf /etc/nginx/conf.d/reddrop-setup.conf /etc/apache2/sites-enabled/reddrop.conf /etc/apache2/sites-enabled/reddrop-setup.conf \
               /etc/apache2/sites-available/reddrop.conf /etc/apache2/sites-available/reddrop-setup.conf /etc/httpd/conf.d/reddrop.conf /etc/httpd/conf.d/reddrop-setup.conf; do
    if [ -L "$datei" ]; then rm -f "$datei"; neu_laden="ja"
    elif [ -f "$datei" ]; then mkdir -p /root/reddrop-backup && cp -a "$datei" "/root/reddrop-backup/$(basename "$datei").bak-$stempel" && rm -f "$datei"; neu_laden="ja"; fi
  done
  if [ -n "$neu_laden" ]; then
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload; fi
    if command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2; fi
    echo "==> Webserver-Eintraege entfernt (Sicherung in /root/reddrop-backup)."
  fi
  dom=$(sed -n 's/^RD_PROXY_DOMAIN=//p' .env 2>/dev/null | tail -1 || true)
  if [ -n "$dom" ] && command -v certbot >/dev/null 2>&1 && certbot certificates 2>/dev/null | grep -q "Certificate Name: $dom$"; then
    ja "    Zertifikat fuer $dom auch loeschen?" "n" && certbot delete --cert-name "$dom" -n || true
  fi
  if [ "$daten" = "ja" ]; then
    ordner="$PWD"; cd /
    if ja "    Ordner $ordner auch loeschen (inkl. .env und import/)?" "j"; then rm -rf "$ordner"; echo "==> Ordner entfernt."; fi
    echo "==> RedDrop ist vollstaendig entfernt."
  else
    echo "==> Container gestoppt und entfernt. Dateien, Datenbank und dieser Ordner sind noch da —"
    echo "    neu starten mit  sudo bash install.sh  (gleiches Datenbank-Passwort aus der .env)."
  fi
  exit 0
fi

echo "==> RedDrop wird eingerichtet"

# 1. Docker (falls noch nicht da)
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker wird installiert …"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "FEHLER: 'docker compose' fehlt. Bitte Docker aktualisieren."; exit 1; }
for f in docker-compose.yml compose.caddy.yml compose.port.yml Caddyfile; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$QUELLE/$f" || { echo "FEHLER: $f fehlt neben install.sh und konnte nicht geladen werden."; exit 1; }
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
# --domain beim zweiten Aufruf: in der .env nachtragen, damit der Assistent sie vorwaehlt
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ]; then
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || { echo "FEHLER: ungueltige Domain: $DOMAIN"; exit 1; }
  if grep -q '^RD_PROXY_DOMAIN=' .env; then sed -i "s|^RD_PROXY_DOMAIN=.*|RD_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RD_PROXY_DOMAIN=$DOMAIN" >> .env; fi
fi

# 5. Starten
# Ordner fuer Importe (Seite „Import“ → Server-Ordner), lesbar fuer den App-Nutzer (uid 1000)
mkdir -p import && chmod 755 import
if [ -d .output ]; then docker compose up -d --build; else docker compose pull && docker compose up -d; fi

# 6. Virtual Host fuer die Domain in deinem Webserver (nur im Port-Modus, nur mit Domain).
#    Als Funktion: laeuft auch nach der Einrichtung ueber den Kurzzeit-Link (Schritt 9) mit der dort gewaehlten Domain.
vhost_angelegt=""
vhost_einrichten() {
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
}
vhost_einrichten

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

# 9. Kurzzeit-Link: Port-Modus ohne Domain → die Einrichtung voruebergehend ueber http://<Server-IP> erlauben.
#    Ein eigener Eintrag NUR fuer die IP (andere Domains im Webserver bleiben unberuehrt), geschuetzt durch
#    den Setup-Code; nach der Einrichtung (oder bei Abbruch) wird er wieder entfernt. Wurde im Assistenten
#    eine Domain eingetragen, bekommt sie danach ihren Virtual Host und das Zertifikat.
setup_wert() { docker compose exec -T db psql -U reddrop -d reddrop -tAc "SELECT coalesce(value->>'$2', '') FROM settings WHERE key = '$1'" 2>/dev/null | tr -d '[:space:]'; }
setup_fertig() { [ "$(setup_wert setup done)" = "true" ]; }
kurz_datei=""; kurz_link=""; kurz_web=""
kurz_weg() {
  [ -n "$kurz_datei" ] || return 0
  if [ "$kurz_web" = "apache2" ]; then a2dissite -q reddrop-setup.conf >/dev/null 2>&1 || true; fi
  rm -f "$kurz_datei" ${kurz_link:+"$kurz_link"}
  case "$kurz_web" in nginx) nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || nginx -s reload; } ;; apache2) systemctl reload apache2 ;; httpd) systemctl reload httpd ;; esac
  echo "==> Kurzzeit-Eintrag fuer http://${ip} wieder entfernt."
  kurz_datei=""
}
if [ "$MODUS" = "port" ] && [ -z "$vhost_angelegt" ] && [ -z "$DOMAIN" ] && [ "$VHOST" = "ja" ] && [[ "${ip:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "${RD_DRY_RUN:-}" != "1" ] && ! setup_fertig; then
  if command -v nginx >/dev/null 2>&1; then kurz_web="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then kurz_web="apache2"
  elif command -v httpd >/dev/null 2>&1; then kurz_web="httpd"
  fi
  if [ -n "$kurz_web" ] && ja "==> Fuer die Einrichtung voruebergehend unter http://${ip} erreichbar machen? (eigener Eintrag nur fuer die IP, wird danach entfernt)" "j"; then
    if [ "$kurz_web" = "nginx" ]; then
      if [ -d /etc/nginx/sites-enabled ]; then kurz_datei=/etc/nginx/sites-available/reddrop-setup.conf; kurz_link=/etc/nginx/sites-enabled/reddrop-setup.conf
      else kurz_datei=/etc/nginx/conf.d/reddrop-setup.conf; fi
      printf '%s\n' "# RedDrop — nur fuer die Einrichtung, entfernt install.sh wieder" "server {" "    listen 80;" "    server_name ${ip};" "    client_max_body_size 0;" \
        "    location / {" "        proxy_pass http://127.0.0.1:${PORT};" "        proxy_set_header Host \$host;" "        proxy_set_header X-Real-IP \$remote_addr;" \
        "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" "        proxy_set_header X-Forwarded-Proto \$scheme;" "    }" "}" > "$kurz_datei"
      [ -n "$kurz_link" ] && ln -sf "$kurz_datei" "$kurz_link"
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload; else echo "    nginx -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt."; kurz_weg; fi
    else
      if [ "$kurz_web" = "apache2" ]; then kurz_datei=/etc/apache2/sites-available/reddrop-setup.conf; else kurz_datei=/etc/httpd/conf.d/reddrop-setup.conf; fi
      printf '%s\n' "# RedDrop — nur fuer die Einrichtung, entfernt install.sh wieder" "<VirtualHost *:80>" "    ServerName ${ip}" "    ProxyPreserveHost On" \
        "    ProxyPass / http://127.0.0.1:${PORT}/" "    ProxyPassReverse / http://127.0.0.1:${PORT}/" "</VirtualHost>" > "$kurz_datei"
      if [ "$kurz_web" = "apache2" ]; then a2enmod -q proxy proxy_http >/dev/null; a2ensite -q reddrop-setup.conf >/dev/null; apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || { echo "    Apache-Konfigtest schlaegt fehl — Kurzzeit-Eintrag wieder entfernt."; kurz_weg; }
      else httpd -t >/dev/null 2>&1 && systemctl reload httpd || { echo "    httpd -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt."; kurz_weg; }; fi
    fi
    if [ -n "$kurz_datei" ]; then
      trap 'echo; kurz_weg; exit 130' INT TERM
      trap 'kurz_weg' EXIT
      echo ""
      echo "==> Oeffne jetzt im Browser:  http://${ip}   und gib den Setup-Code von oben ein."
      echo "    Waehle im Assistenten „Hinter eigenem Proxy“ und trage deine Domain ein — der Installer"
      echo "    legt danach den Virtual Host und das Zertifikat dafuer an. (Strg+C bricht ab.)"
      echo -n "    Warte auf die Einrichtung "
      for _ in $(seq 1 720); do setup_fertig && break; echo -n "."; sleep 10; done
      echo ""
      kurz_weg
      trap - INT TERM EXIT
      if setup_fertig; then
        neu=$(setup_wert net domain | tr 'A-Z' 'a-z')
        if [[ "$neu" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
          DOMAIN="$neu"
          if grep -q '^RD_PROXY_DOMAIN=' .env; then sed -i "s|^RD_PROXY_DOMAIN=.*|RD_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RD_PROXY_DOMAIN=$DOMAIN" >> .env; fi
          echo "==> Einrichtung abgeschlossen. Domain aus dem Assistenten: $DOMAIN"
          vhost_einrichten
          if [ -n "$vhost_angelegt" ]; then
            if [ -n "${https_ok:-}" ]; then echo "==> Fertig. RedDrop laeuft unter  https://${DOMAIN}"; else echo "==> Fertig. RedDrop laeuft unter  http://${DOMAIN}  (HTTPS: certbot --nginx -d ${DOMAIN} --redirect)"; fi
            exit 0
          fi
        else
          echo "==> Einrichtung abgeschlossen, aber ohne Domain. Spaeter:  sudo bash install.sh --domain drop.deinefirma.de"
          exit 0
        fi
      else
        echo "==> Zeit abgelaufen. Einfach nochmal:  sudo bash install.sh"
        exit 0
      fi
    fi
  fi
fi
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
