#!/usr/bin/env bash
set -uo pipefail
WG=rd0
NETZ=10.87.0
PORT=51877
CONF=/etc/wireguard/$WG.conf
EXPORTS=/etc/exports.d/reddrop.exports
# Tailscale (1.11.0): Freigaben und Firewall je Server-IP, nie fürs ganze Tailnet
TS_INFO=.knoten-ts
TS_EXPORTS=/etc/exports.d/reddrop-ts.exports
TS_ORDNER=/etc/reddrop
TS_ERLAUBT=$TS_ORDNER/ts-erlaubt
TS_FW=/usr/local/bin/reddrop-ts-firewall
WEB=.knoten-web
NGINX_LB=/etc/nginx/conf.d/reddrop-knoten.conf
GEW=.knoten-gewichte
AUSFALL_AUS=.knoten-ohne-ausfall
DATEN="${DATEN:-.}"
ist_unraid() { [ -f /etc/unraid-version ] && [ -d /boot/config ]; }
ur_sichern() { :; }
# Fehlt die Datei nach einem Update ohne sie, bleibt es beim klaren Fehler weiter unten.
[ -f knoten-unraid.sh ] && . ./knoten-unraid.sh

fehler() { echo "$1" >&2; exit 1; }

pakete() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq --no-install-recommends "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@" >/dev/null 2>&1
  else
    return 1
  fi
}

tunnel_aufbauen() {
  if ist_unraid; then
    command -v ur_einrichten >/dev/null 2>&1 || fehler "knoten-unraid.sh fehlt, bitte RedDrop aktualisieren / knoten-unraid.sh is missing, please update RedDrop"
    command -v wg-quick >/dev/null 2>&1 || fehler "WireGuard fehlt, Unraid bringt es ab Version 6.8 mit / WireGuard is missing, Unraid includes it from version 6.8"
  fi
  command -v wg-quick >/dev/null 2>&1 || pakete wireguard-tools || fehler "WireGuard ließ sich nicht installieren / could not install WireGuard"
  command -v iptables >/dev/null 2>&1 || pakete iptables || true
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
  if [ ! -f "$CONF" ]; then
    local schluessel
    schluessel=$(wg genkey)
    umask 077
    # Unraid bedient über NFS oft auch das Heimnetz. Die Sperre von außen träfe dort die eigenen Freigaben, und die Freigabe gilt ohnehin nur für den Tunnel.
    local sperre_an="iptables -I INPUT -p tcp --dport 2049 ! -i $WG -j DROP; " sperre_aus="iptables -D INPUT -p tcp --dport 2049 ! -i $WG -j DROP || true; "
    if ist_unraid; then sperre_an=""; sperre_aus=""; fi
    cat > "$CONF" <<EOF
[Interface]
Address = $NETZ.1/24
ListenPort = $PORT
PrivateKey = $schluessel
PostUp = ${sperre_an}iptables -t nat -A POSTROUTING -o $WG -j MASQUERADE; iptables -I DOCKER-USER -o $WG -j ACCEPT || true; iptables -I DOCKER-USER -i $WG -j ACCEPT || true
PostDown = ${sperre_aus}iptables -t nat -D POSTROUTING -o $WG -j MASQUERADE || true; iptables -D DOCKER-USER -o $WG -j ACCEPT || true; iptables -D DOCKER-USER -i $WG -j ACCEPT || true
EOF
  fi
  if ! ip link show "$WG" >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      mkdir -p "/etc/systemd/system/wg-quick@$WG.service.d"
      printf '[Unit]\nBefore=docker.service\n' > "/etc/systemd/system/wg-quick@$WG.service.d/vor-docker.conf"
      systemctl daemon-reload
      systemctl enable --now "wg-quick@$WG" >/dev/null 2>&1 || fehler "Der Tunnel startet nicht / the tunnel does not start"
    else
      wg-quick up "$WG" >/dev/null 2>&1 || fehler "Der Tunnel startet nicht / the tunnel does not start"
    fi
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$PORT/udp" >/dev/null 2>&1 || true; fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$PORT/udp" || true
    firewall-cmd -q --reload || true
  fi
}

# Die Datenbank kommt über Docker durch, NFS läuft aber auf dem Host. Ohne Freigabe blockt die Firewall es,
# und der neue Server wartet ewig auf den Datenordner. Nur im Tunnel, von außen bleibt der Port zu.
nfs_im_tunnel_erlauben() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw status | grep -q "2049/tcp on $WG" || ufw allow in on "$WG" to any port 2049 proto tcp comment 'RedDrop Knoten NFS' >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --direct --add-rule ipv4 filter INPUT 0 -i "$WG" -p tcp --dport 2049 -j ACCEPT 2>/dev/null || true
    firewall-cmd -q --reload || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -i "$WG" -p tcp --dport 2049 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$WG" -p tcp --dport 2049 -j ACCEPT 2>/dev/null || true
  fi
}

daten_quelle() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$(docker compose ps -q app | head -1)" 2>/dev/null
}

ordner_freigeben() {
  local quelle
  quelle=$(daten_quelle)
  [ -d "$quelle" ] || fehler "Der Datenordner wurde nicht gefunden / data folder not found"
  nfs_dienst
  mkdir -p /etc/exports.d
  printf '"%s" %s.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=87)\n' "$quelle" "$NETZ" > "$EXPORTS"
  exportfs -ra || fehler "Die NFS-Freigabe schlug fehl / NFS export failed"
  nfs_im_tunnel_erlauben
  printf '%s' "$quelle"
}

# NFS-Dienst bereitstellen (WireGuard und Tailscale), ohne selbst etwas freizugeben.
nfs_dienst() {
  if ist_unraid; then
    command -v exportfs >/dev/null 2>&1 || fehler "exportfs fehlt / exportfs is missing"
    if ! pgrep -x nfsd >/dev/null 2>&1; then
      [ -x /etc/rc.d/rc.nfsd ] && /etc/rc.d/rc.nfsd start >/dev/null 2>&1
      sleep 2
      pgrep -x nfsd >/dev/null 2>&1 || fehler "NFS läuft nicht. Bitte in Unraid unter Einstellungen > NFS einschalten / NFS is not running. Please enable it in Unraid under Settings > NFS"
    fi
  elif ! command -v exportfs >/dev/null 2>&1; then
    pakete nfs-kernel-server || pakete nfs-utils || fehler "Der NFS-Dienst ließ sich nicht installieren / could not install NFS"
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || true
  fi
}

# Antwortet auf dieser Adresse schon etwas? Auch eine Datenbank des Servers auf allen Adressen zählt,
# denn genau daran scheiterte Docker: "address already in use".
port_belegt() {
  local a
  for a in $(bind_adressen); do timeout 2 bash -c "exec 3<>/dev/tcp/$a/$1" 2>/dev/null && return 0; done
  return 1
}

# An diese Adressen binden Datenbank und Speicherdienst: WireGuard (10.87.0.1) und/oder Tailscale (100.x).
ts_eigene_ip() { [ -f "$TS_INFO" ] && sed -n 's/.*"ip":"\([0-9.]*\)".*/\1/p' "$TS_INFO" | head -1; }
bind_adressen() {
  [ -f "$CONF" ] && printf '%s.1\n' "$NETZ"
  ts_eigene_ip
  return 0
}

# Bleibt bei einem schon eingerichteten Port, sonst der Wunsch, sonst der erste freie aus der Reserve.
port_waehlen() {
  local innen="$1" wunsch="$2" reserve="$3" alt p
  alt=$(sed -n "s/.*\"[0-9.]*:\([0-9]*\):$innen\".*/\1/p" compose.tunnel.yml 2>/dev/null | head -1)
  if [ -n "$alt" ] && grep -q '^COMPOSE_FILE=.*compose\.tunnel\.yml' .env; then
    printf '%s' "$alt"
    return 0
  fi
  for p in "$wunsch" $(seq "$reserve" $((reserve + 20))); do
    if ! port_belegt "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

DB_PORT=5432
GARAGE_PORT=3900

db_bereit() {
  local i
  for i in $(seq 1 30); do
    docker compose exec -T db pg_isready -U reddrop -d reddrop >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Scheitert das Freigeben, kommt der alte Zustand zurück. Sonst stünde die Datenbank still,
# und mit ihr die ganze Installation.
compose_erweitern() {
  local garage="" alt env_alt tunnel_alt=""
  DB_PORT=$(port_waehlen 5432 5432 15432) || fehler "Für die Datenbank ist kein Port im Tunnel frei / no free tunnel port for the database"
  local adressen a db_zeilen="" garage_zeilen=""
  adressen=$(bind_adressen)
  [ -n "$adressen" ] || fehler "Weder WireGuard noch Tailscale ist eingerichtet / neither WireGuard nor Tailscale is set up"
  for a in $adressen; do db_zeilen="$db_zeilen      - \"$a:$DB_PORT:5432\"
"; done
  if grep -q '^COMPOSE_PROFILES=.*speicher' .env; then
    GARAGE_PORT=$(port_waehlen 3900 3900 13900) || fehler "Für den Speicherdienst ist kein Port im Tunnel frei / no free tunnel port for the storage service"
    for a in $adressen; do garage_zeilen="$garage_zeilen      - \"$a:$GARAGE_PORT:3900\"
"; done
    garage="  garage:
    ports:
${garage_zeilen%
}"
  fi
  env_alt=$(mktemp)
  cp -p .env "$env_alt"
  if [ -f compose.tunnel.yml ]; then
    tunnel_alt=$(mktemp)
    cp -p compose.tunnel.yml "$tunnel_alt"
  fi
  cat > compose.tunnel.yml <<EOF
services:
  db:
    ports:
${db_zeilen%
}
$garage
EOF
  alt=$(sed -n 's/^COMPOSE_FILE=//p' .env | tail -1)
  case ":$alt:" in
    *:compose.tunnel.yml:*) ;;
    *) sed -i "s#^COMPOSE_FILE=.*#COMPOSE_FILE=$alt:compose.tunnel.yml#" .env ;;
  esac
  if ! docker compose up -d db ${garage:+garage} >/dev/null 2>&1 || ! db_bereit; then
    cp -p "$env_alt" .env
    if [ -n "$tunnel_alt" ]; then cp -p "$tunnel_alt" compose.tunnel.yml; else rm -f compose.tunnel.yml; fi
    rm -f "$env_alt" "$tunnel_alt"
    docker compose up -d db ${garage:+garage} >/dev/null 2>&1 || true
    fehler "Die Datenbank ließ sich nicht im Tunnel freigeben, der vorherige Zustand ist wiederhergestellt / could not expose the database in the tunnel, the previous state was restored"
  fi
  rm -f "$env_alt" "$tunnel_alt"
}

info_schreiben() {
  local paket=false
  [ -f .paket ] && paket=true
  local pub="" ts
  [ -f "$CONF" ] && pub=$(wg show "$WG" public-key 2>/dev/null)
  ts=$(ts_eigene_ip)
  printf '{"pub":"%s","port":%s,"paket":%s,"nfsPfad":"%s","dbPort":%s,"garagePort":%s,"ts":"%s"}\n' "$pub" "$PORT" "$paket" "${1:-}" "$DB_PORT" "$GARAGE_PORT" "$ts" > "$DATEN/.knoten-tunnel"
  chmod 644 "$DATEN/.knoten-tunnel"
}

vorbereiten() {
  local nfs="${1:-}" pfad=""
  tunnel_aufbauen
  # Ohne das exit liefe die Vorbereitung bei gescheiterter Freigabe weiter, und der neue Server arbeitete still ohne die Dateien.
  if [ "$nfs" = "nfs" ]; then pfad=$(ordner_freigeben) || exit 1; fi
  compose_erweitern
  info_schreiben "$pfad"
  if ist_unraid; then ur_einrichten "$PWD" >/dev/null || fehler "Auf dem USB-Stick ließ sich nichts einrichten / could not set up anything on the USB stick"; fi
}

peer_eintragen() {
  local pub="$1" ip="$2"
  [ -f "$CONF" ] || fehler "Der Tunnel ist nicht eingerichtet / tunnel not set up"
  [ -f "$EXPORTS" ] && nfs_im_tunnel_erlauben
  peer_austragen "$ip"
  wg set "$WG" peer "$pub" allowed-ips "$ip/32" || fehler "Der Server ließ sich nicht eintragen / could not add the server"
  printf '\n# knoten %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n# ende %s\n' "$ip" "$pub" "$ip" "$ip" >> "$CONF"
  ur_sichern
}

peer_austragen() {
  local ip="$1" alt
  alt=$(wg show "$WG" allowed-ips 2>/dev/null | awk -v i="$ip/32" '$2 == i {print $1}')
  [ -n "$alt" ] && wg set "$WG" peer "$alt" remove
  sed -i "/^# knoten $ip\$/,/^# ende $ip\$/d" "$CONF" 2>/dev/null || true
  ur_sichern
}

# Gewicht eines Ziels (haupt oder Tunnel-Adresse). Ohne Eintrag zählen alle gleich.
gewicht_von() {
  local g=""
  [ -f "$GEW" ] && g=$(sed -n "s/^$1 //p" "$GEW" | head -1)
  case "$g" in ''|*[!0-9]*) echo 1 ;; *) echo "$g" ;; esac
}
mit_ausfall() { [ ! -f "$AUSFALL_AUS" ]; }

# Caddy kennt mit Sitzungs-Cookie auch Gewichte. Für „nur als Ersatz“ (0 %) gibt es dort nur die feste Reihenfolge.
caddy_block() {
  local ziele="$1" einzug="$2" liste="" gew="" ersatz="" haupt ip g
  haupt=$(gewicht_von haupt)
  if [ "$haupt" -gt 0 ]; then liste="app:3000"; gew="$haupt"; else ersatz="app:3000"; fi
  for ip in $ziele; do
    g=$(gewicht_von "$ip")
    if [ "$g" -gt 0 ]; then liste="$liste $ip:3000"; gew="$gew $g"; else ersatz="$ersatz $ip:3000"; fi
  done
  printf '%sreverse_proxy %s %s {\n' "$einzug" "$liste" "$ersatz"
  if [ -n "$(echo "$ersatz" | tr -d ' ')" ]; then
    printf '%s\tlb_policy first\n' "$einzug"
  else
    printf '%s\tlb_policy cookie {\n%s\t\tfallback weighted_round_robin %s\n%s\t}\n' "$einzug" "$einzug" "$gew" "$einzug"
  fi
  if mit_ausfall; then printf '%s\tfail_duration 30s\n%s\tmax_fails 3\n' "$einzug" "$einzug"; fi
  printf '%s}\n' "$einzug"
}

web_verteilen() {
  local ziele="" port ip
  [ -f "$WEB" ] && ziele=$(tr '\n' ' ' < "$WEB")
  if grep -q 'compose.caddy.yml' .env; then
    [ -f Caddyfile.original ] || cp Caddyfile Caddyfile.original
    local alt neu
    alt=$(mktemp); neu=$(mktemp)
    cp -p Caddyfile "$alt"
    if [ -n "$ziele" ]; then
      while IFS= read -r zeile || [ -n "$zeile" ]; do
        case "$zeile" in
          *'reverse_proxy app:3000'*) caddy_block "$ziele" "${zeile%%reverse_proxy*}" ;;
          *) printf '%s\n' "$zeile" ;;
        esac
      done < Caddyfile.original > "$neu"
    else
      cp Caddyfile.original "$neu"
    fi
    # In die vorhandene Datei schreiben: Sie ist einzeln in den Container eingebunden, ein Austausch käme dort nicht an.
    cat "$neu" > Caddyfile
    rm -f "$neu"
    if docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
      && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
      rm -f "$alt"
      return 0
    fi
    cat "$alt" > Caddyfile
    rm -f "$alt"
    fehler "Caddy lehnt die neue Einstellung ab, die alte bleibt aktiv / Caddy rejected the change, the old one stays active"
  fi
  port=$(sed -n 's/^RD_PORT=//p' .env | tail -1)
  if command -v nginx >/dev/null 2>&1; then
    local datei
    datei=$(grep -rlE "proxy_pass[[:space:]]+http://(127\.0\.0\.1:$port|reddrop_knoten)" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | grep -v "$NGINX_LB" | head -1)
    [ -n "$datei" ] || fehler "Kein nginx-Eintrag für Port $port gefunden. Bitte die Server von Hand eintragen / no nginx entry for port $port, please add the servers by hand"
    # Nicht neben dem vHost ablegen: nginx liest den ganzen Ordner ein und stolpert sonst über die Kopie.
    local sicherung
    sicherung=$(mktemp)
    cp -p "$datei" "$sicherung"
    rm -f "$datei.vor-knoten"
    local lb_alt=""
    [ -f "$NGINX_LB" ] && lb_alt=$(cat "$NGINX_LB")
    if [ -n "$ziele" ]; then
      # ip_hash und backup schließen sich in nginx aus. Gibt es einen Ersatz-Server, verteilt nginx ohne feste Zuordnung.
      local ersatz="" g zusatz=" max_fails=0"
      mit_ausfall && zusatz=" max_fails=3 fail_timeout=30s"
      [ "$(gewicht_von haupt)" = 0 ] && ersatz=1
      for ip in $ziele; do [ "$(gewicht_von "$ip")" = 0 ] && ersatz=1; done
      {
        echo "upstream reddrop_knoten {"
        [ -n "$ersatz" ] || echo "    ip_hash;"
        g=$(gewicht_von haupt)
        if [ "$g" = 0 ]; then echo "    server 127.0.0.1:$port backup;"; else echo "    server 127.0.0.1:$port weight=$g$zusatz;"; fi
        for ip in $ziele; do
          g=$(gewicht_von "$ip")
          if [ "$g" = 0 ]; then echo "    server $ip:3000 backup;"; else echo "    server $ip:3000 weight=$g$zusatz;"; fi
        done
        echo "}"
      } > "$NGINX_LB"
      sed -i -E "s#proxy_pass[[:space:]]+http://127\.0\.0\.1:$port;#proxy_pass http://reddrop_knoten;#" "$datei"
    else
      rm -f "$NGINX_LB"
      sed -i -E "s#proxy_pass[[:space:]]+http://reddrop_knoten;#proxy_pass http://127.0.0.1:$port;#" "$datei"
    fi
    if nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; then
      rm -f "$sicherung"
      return 0
    fi
    cat "$sicherung" > "$datei"
    rm -f "$sicherung"
    if [ -n "$lb_alt" ]; then printf '%s\n' "$lb_alt" > "$NGINX_LB"; else rm -f "$NGINX_LB"; fi
    fehler "nginx lehnt die neue Einstellung ab, die alte bleibt aktiv / nginx rejected the change, the old one stays active"
  fi
  fehler "Dieser Webserver wird nicht automatisch angepasst. Bitte den Server von Hand im Lastverteiler eintragen / this web server is not adjusted automatically, please add the server to your load balancer by hand"
}

# Lehnt der Webserver ab, muss auch die gemerkte Liste wieder stimmen.
web_liste_zurueck() {
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$WEB"; else : > "$WEB"; fi
  exit 1
}

web_an() {
  touch "$WEB"
  local alt
  alt=$(cat "$WEB")
  grep -qxF "$1" "$WEB" || echo "$1" >> "$WEB"
  ( web_verteilen ) || web_liste_zurueck "$alt"
}

web_aus() {
  [ -f "$WEB" ] || return 0
  local alt
  alt=$(cat "$WEB")
  sed -i "/^$1\$/d" "$WEB"
  ( web_verteilen ) || web_liste_zurueck "$alt"
}

gewichte_setzen() {
  local liste="$1" ausfall="${2:-1}" paar k v neu
  neu=$(mktemp)
  for paar in $(printf '%s' "$liste" | tr ',' ' '); do
    k="${paar%%=*}"; v="${paar#*=}"
    case "$k" in haupt|10.87.0.[0-9]*|100.[0-9]*.[0-9]*.[0-9]*) ;; *) rm -f "$neu"; fehler "Ungültiger Server: $k" ;; esac
    case "$v" in ''|*[!0-9]*) rm -f "$neu"; fehler "Ungültiges Gewicht: $v" ;; esac
    echo "$k $v" >> "$neu"
  done
  cp -p "$GEW" "$neu.alt" 2>/dev/null || true
  mv -f "$neu" "$GEW"
  if [ "$ausfall" = 0 ]; then touch "$AUSFALL_AUS"; else rm -f "$AUSFALL_AUS"; fi
  if [ -s "$WEB" ] && ! ( web_verteilen ); then
    if [ -f "$neu.alt" ]; then mv -f "$neu.alt" "$GEW"; else rm -f "$GEW"; fi
    exit 1
  fi
  rm -f "$neu.alt"
}

# ---------- Tailscale (1.11.0) ----------
# Ein vorhandenes Tailnet bleibt unangetastet: nur status/ip lesen, nie „up --reset“, Exit-Node und DNS bleiben.
mit_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }
ts_laeuft() { tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; }
ts_ip() { tailscale ip -4 2>/dev/null | head -1; }
ts_gueltige_ip() { case "$1" in 100.[0-9]*.[0-9]*.[0-9]*) [ "$(printf '%s' "$1" | tr -cd '.' | wc -c)" = 3 ] ;; *) return 1 ;; esac; }

ts_installieren() {
  command -v tailscale >/dev/null 2>&1 && return 0
  ist_unraid && fehler "Unraid: Bitte das offizielle Tailscale-Plugin installieren und anmelden, dann erneut versuchen / please install and sign in with the official Tailscale plugin, then try again"
  command -v curl >/dev/null 2>&1 || pakete curl || true
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || fehler "Tailscale ließ sich nicht installieren / could not install Tailscale"
  if mit_systemd; then systemctl enable --now tailscaled >/dev/null 2>&1 || true; fi
  touch "$TS_ORDNER/von-reddrop-installiert" 2>/dev/null || { mkdir -p "$TS_ORDNER" && touch "$TS_ORDNER/von-reddrop-installiert"; }
}

# Anmelde-Link fürs Panel: der Update-Dienst schreibt danach selbst „fertig“ oder „fehler“.
ts_link_melden() {
  printf '{"status":"laeuft","link":"%s","zeit":"%s"}\n' "$1" "$(date -Is)" > "$DATEN/.knoten-status.neu" && mv -f "$DATEN/.knoten-status.neu" "$DATEN/.knoten-status"
  chmod 644 "$DATEN/.knoten-status" 2>/dev/null || true
}

ts_anmelden() {
  local key="$1" ls="$2" name log i url=""
  name="reddrop-$(hostname | tr -cd 'A-Za-z0-9-' | cut -c1-30)"
  local args=(up --accept-dns=false "--hostname=$name")
  [ -n "$ls" ] && args+=("--login-server=$ls")
  if [ -n "$key" ] && [ -s "$key" ]; then
    if ! tailscale "${args[@]}" "--auth-key=file:$key" --timeout=90s >/dev/null 2>&1; then
      rm -f "$key"
      fehler "Die Tailscale-Anmeldung mit dem Schlüssel schlug fehl. Ist er gültig und nicht abgelaufen? / Tailscale sign-in with the key failed. Is it valid and not expired?"
    fi
    rm -f "$key"
    return 0
  fi
  rm -f "$key"
  log=$(mktemp)
  ( tailscale "${args[@]}" --timeout=600s > "$log" 2>&1 & )
  for i in $(seq 1 30); do
    url=$(grep -oE 'https?://[^[:space:]]+' "$log" | head -1)
    [ -n "$url" ] && break
    ts_laeuft && break
    sleep 1
  done
  [ -n "$url" ] && ts_link_melden "$url"
  for i in $(seq 1 600); do ts_laeuft && break; sleep 1; done
  rm -f "$log"
  ts_laeuft || fehler "Die Tailscale-Anmeldung wurde nicht bestätigt / the Tailscale sign-in was not confirmed"
}

# Nach einem Neustart soll Docker an die 100.x-Adresse binden können, auch wenn tailscaled noch verbindet.
ts_bindung_absichern() {
  printf 'net.ipv4.ip_nonlocal_bind = 1\n' > /etc/sysctl.d/90-reddrop-tailscale.conf 2>/dev/null || true
  sysctl -q -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
  if mit_systemd; then
    mkdir -p /etc/systemd/system/docker.service.d
    printf '[Unit]\nAfter=tailscaled.service\nWants=tailscaled.service\n' > /etc/systemd/system/docker.service.d/nach-tailscale.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

# Firewall: Datenbank, Speicherdienst und NFS über Tailscale nur von eingebundenen Servern.
# Eigene Kette RD-TS, beim Booten neu gesetzt (systemd), SSH und andere Dienste im Tailnet bleiben unberührt.
ts_firewall_einrichten() {
  mkdir -p "$TS_ORDNER"
  touch "$TS_ERLAUBT"
  cat > "$TS_FW" <<'FW'
#!/bin/sh
# RedDrop: Zugriff über Tailscale auf Datenbank, Speicherdienst und NFS nur von eingebundenen Servern.
O=/etc/reddrop
IP=$(cat "$O/ts-ip" 2>/dev/null); PORTE=$(cat "$O/ts-porte" 2>/dev/null)
[ -n "$IP" ] || exit 0
command -v iptables >/dev/null 2>&1 || exit 0
# raw/PREROUTING: läuft vor Dockers Umleitung (DNAT) und vor den Ketten von Tailscale (ts-input, ts-forward
# nehmen alles von tailscale0 an). Ziel ist hier noch die Tailscale-Adresse mit dem veröffentlichten Port.
iptables -t raw -N RD-TS 2>/dev/null || true
iptables -t raw -F RD-TS
while read -r a; do [ -n "$a" ] && iptables -t raw -A RD-TS -s "$a" -j RETURN; done < "$O/ts-erlaubt"
iptables -t raw -A RD-TS -j DROP
for p in 2049 $PORTE; do
  iptables -t raw -C PREROUTING -i tailscale0 -d "$IP" -p tcp --dport "$p" -j RD-TS 2>/dev/null || iptables -t raw -I PREROUTING -i tailscale0 -d "$IP" -p tcp --dport "$p" -j RD-TS
done
FW
  chmod 755 "$TS_FW"
  printf '%s\n' "$(ts_eigene_ip)" > "$TS_ORDNER/ts-ip"
  printf '%s %s\n' "$DB_PORT" "$GARAGE_PORT" > "$TS_ORDNER/ts-porte"
  if mit_systemd; then
    printf '%s\n' "[Unit]" "Description=RedDrop: Tailscale-Freigaben nur für eingebundene Server" "After=docker.service tailscaled.service" "Wants=docker.service" "[Service]" "Type=oneshot" "RemainAfterExit=yes" "ExecStart=$TS_FW" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/reddrop-ts-firewall.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable reddrop-ts-firewall.service >/dev/null 2>&1 || true
  fi
  "$TS_FW" || true
}

# Ablauf der Schlüssel (dieser Server und alle Geräte im Tailnet) fürs Panel, ohne API-Zugang: halbstündlich.
ts_stand_einrichten() {
  cat > /usr/local/bin/reddrop-ts-stand <<STAND
#!/bin/sh
tailscale status --json 2>/dev/null > "$DATEN/.ts-stand.neu" && mv -f "$DATEN/.ts-stand.neu" "$DATEN/.ts-stand" && chmod 644 "$DATEN/.ts-stand"
STAND
  chmod 755 /usr/local/bin/reddrop-ts-stand
  if mit_systemd; then
    printf '%s\n' "[Unit]" "Description=RedDrop: Tailscale-Stand" "[Service]" "Type=oneshot" "ExecStart=/usr/local/bin/reddrop-ts-stand" > /etc/systemd/system/reddrop-ts-stand.service
    printf '%s\n' "[Unit]" "Description=RedDrop: Tailscale-Stand halbstündlich" "[Timer]" "OnBootSec=2min" "OnUnitActiveSec=30min" "[Install]" "WantedBy=timers.target" > /etc/systemd/system/reddrop-ts-stand.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now reddrop-ts-stand.timer >/dev/null 2>&1 || true
  elif [ -d /etc/cron.d ]; then
    printf '%s\n' "*/30 * * * * root /usr/local/bin/reddrop-ts-stand >/dev/null 2>&1" > /etc/cron.d/reddrop-ts-stand
  fi
  /usr/local/bin/reddrop-ts-stand || true
}

ts_vorbereiten() {
  local nfs="$1" key="$2" ls="$3" vorhanden=false pfad="" ip
  [ "$nfs" = "-" ] && nfs=""; [ "$ls" = "-" ] && ls=""; [ "$key" = "-" ] && key=""
  ts_installieren
  if ts_laeuft; then vorhanden=true; rm -f "$key"; else ts_anmelden "$key" "$ls"; fi
  ip=$(ts_ip)
  ts_gueltige_ip "$ip" || fehler "Keine Tailscale-Adresse / no Tailscale address"
  printf '{"ip":"%s","vorhanden":%s}\n' "$ip" "$vorhanden" > "$TS_INFO"
  ts_bindung_absichern
  if [ "$nfs" = "nfs" ]; then
    pfad=$(daten_quelle)
    [ -d "$pfad" ] || fehler "Der Datenordner wurde nicht gefunden / data folder not found"
    ( nfs_dienst ) || exit 1
    mkdir -p /etc/exports.d; touch "$TS_EXPORTS"
  elif [ -f "$DATEN/.knoten-tunnel" ]; then
    pfad=$(sed -n 's/.*"nfsPfad":"\([^"]*\)".*/\1/p' "$DATEN/.knoten-tunnel" | head -1)
  fi
  compose_erweitern
  ts_firewall_einrichten
  ts_stand_einrichten
  info_schreiben "$pfad"
}

ts_exports_schreiben() {
  local quelle ip
  quelle=$(sed -n 's/.*"nfsPfad":"\([^"]*\)".*/\1/p' "$DATEN/.knoten-tunnel" 2>/dev/null | head -1)
  [ -n "$quelle" ] || return 0
  mkdir -p /etc/exports.d
  : > "$TS_EXPORTS.neu"
  while read -r ip; do [ -n "$ip" ] && printf '"%s" %s(rw,sync,no_subtree_check,no_root_squash,fsid=87)\n' "$quelle" "$ip" >> "$TS_EXPORTS.neu"; done < "$TS_ERLAUBT"
  mv -f "$TS_EXPORTS.neu" "$TS_EXPORTS"
  exportfs -ra || fehler "Die NFS-Freigabe schlug fehl / NFS export failed"
}

ts_ufw() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if [ "$1" = an ]; then ufw allow in on tailscale0 from "$2" to any port 2049 proto tcp comment 'RedDrop Knoten NFS' >/dev/null 2>&1 || true
  else ufw delete allow in on tailscale0 from "$2" to any port 2049 proto tcp >/dev/null 2>&1 || true; fi
}

ts_peer_eintragen() {
  local ip="$1"
  ts_gueltige_ip "$ip" || fehler "Ungültige Tailscale-Adresse: $ip"
  [ -f "$TS_INFO" ] || fehler "Tailscale ist auf diesem Server nicht eingerichtet / Tailscale is not set up on this server"
  mkdir -p "$TS_ORDNER"; touch "$TS_ERLAUBT"
  grep -qxF "$ip" "$TS_ERLAUBT" || echo "$ip" >> "$TS_ERLAUBT"
  ts_exports_schreiben
  ts_ufw an "$ip"
  "$TS_FW" || true
}

ts_peer_austragen() {
  local ip="$1"
  ts_gueltige_ip "$ip" || fehler "Ungültige Tailscale-Adresse: $ip"
  [ -f "$TS_ERLAUBT" ] && sed -i "/^$ip\$/d" "$TS_ERLAUBT"
  ts_exports_schreiben
  ts_ufw aus "$ip"
  [ -x "$TS_FW" ] && "$TS_FW" || true
}

aktion="${1:-}"
shift || true
case "$aktion" in
  vorbereiten) vorbereiten "${1:-}" ;;
  peer)
    peer_eintragen "$1" "$2"
    if [ "${3:-}" = "web" ]; then web_an "$2"; fi
    ;;
  peer-weg)
    # Der Server geht in jedem Fall aus dem Tunnel. Lehnt der Webserver ab, kommt das als Fehler zurück.
    rc=0
    ( web_aus "$1" ) || rc=1
    if [ -f "$WEB" ]; then sed -i "/^$1\$/d" "$WEB"; fi
    peer_austragen "$1"
    exit "$rc"
    ;;
  ts-vorbereiten) ts_vorbereiten "${1:--}" "${2:--}" "${3:--}" ;;
  ts-peer)
    ts_gueltige_ip "${1:-}" || fehler "Ungültige Tailscale-Adresse: ${1:-}"
    ts_peer_eintragen "$1"
    if [ "${2:-}" = "web" ]; then web_an "$1"; fi
    ;;
  ts-peer-weg)
    ts_gueltige_ip "${1:-}" || fehler "Ungültige Tailscale-Adresse: ${1:-}"
    rc=0
    ( web_aus "$1" ) || rc=1
    if [ -f "$WEB" ]; then sed -i "/^$1\$/d" "$WEB"; fi
    ts_peer_austragen "$1"
    exit "$rc"
    ;;
  web-neu) if [ -s "$WEB" ]; then web_verteilen; fi ;;
  gewichte) gewichte_setzen "$1" "${2:-1}" ;;
  web-an) web_an "$1" ;;
  web-aus) web_aus "$1" ;;
  *) fehler "Unbekannte Aktion: $aktion" ;;
esac
