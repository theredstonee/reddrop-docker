#!/usr/bin/env bash
set -uo pipefail
WG=rd0
NETZ=10.87.0
PORT=51877
CONF=/etc/wireguard/$WG.conf
EXPORTS=/etc/exports.d/reddrop.exports
WEB=.knoten-web
NGINX_LB=/etc/nginx/conf.d/reddrop-knoten.conf
GEW=.knoten-gewichte
AUSFALL_AUS=.knoten-ohne-ausfall
DATEN="${DATEN:-.}"

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
  [ -f /etc/unraid-version ] && fehler "Unraid wird für den automatischen Beitritt nicht unterstützt / Unraid is not supported for automatic joining"
  command -v wg-quick >/dev/null 2>&1 || pakete wireguard-tools || fehler "WireGuard ließ sich nicht installieren / could not install WireGuard"
  command -v iptables >/dev/null 2>&1 || pakete iptables || true
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
  if [ ! -f "$CONF" ]; then
    local schluessel
    schluessel=$(wg genkey)
    umask 077
    cat > "$CONF" <<EOF
[Interface]
Address = $NETZ.1/24
ListenPort = $PORT
PrivateKey = $schluessel
PostUp = iptables -I INPUT -p tcp --dport 2049 ! -i $WG -j DROP; iptables -t nat -A POSTROUTING -o $WG -j MASQUERADE; iptables -I DOCKER-USER -o $WG -j ACCEPT || true; iptables -I DOCKER-USER -i $WG -j ACCEPT || true
PostDown = iptables -D INPUT -p tcp --dport 2049 ! -i $WG -j DROP || true; iptables -t nat -D POSTROUTING -o $WG -j MASQUERADE || true; iptables -D DOCKER-USER -o $WG -j ACCEPT || true; iptables -D DOCKER-USER -i $WG -j ACCEPT || true
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

ordner_freigeben() {
  local quelle
  quelle=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$(docker compose ps -q app | head -1)" 2>/dev/null)
  [ -d "$quelle" ] || fehler "Der Datenordner wurde nicht gefunden / data folder not found"
  if ! command -v exportfs >/dev/null 2>&1; then
    pakete nfs-kernel-server || pakete nfs-utils || fehler "Der NFS-Dienst ließ sich nicht installieren / could not install NFS"
  fi
  mkdir -p /etc/exports.d
  printf '"%s" %s.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=87)\n' "$quelle" "$NETZ" > "$EXPORTS"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || true
  fi
  exportfs -ra || fehler "Die NFS-Freigabe schlug fehl / NFS export failed"
  nfs_im_tunnel_erlauben
  printf '%s' "$quelle"
}

# Antwortet auf dieser Adresse schon etwas? Auch eine Datenbank des Servers auf allen Adressen zählt,
# denn genau daran scheiterte Docker: "address already in use".
port_belegt() {
  timeout 2 bash -c "exec 3<>/dev/tcp/$NETZ.1/$1" 2>/dev/null
}

# Bleibt bei einem schon eingerichteten Port, sonst der Wunsch, sonst der erste freie aus der Reserve.
port_waehlen() {
  local innen="$1" wunsch="$2" reserve="$3" alt p
  alt=$(sed -n "s/.*\"$NETZ\.1:\([0-9]*\):$innen\".*/\1/p" compose.tunnel.yml 2>/dev/null | head -1)
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
  if grep -q '^COMPOSE_PROFILES=.*speicher' .env; then
    GARAGE_PORT=$(port_waehlen 3900 3900 13900) || fehler "Für den Speicherdienst ist kein Port im Tunnel frei / no free tunnel port for the storage service"
    garage="  garage:
    ports:
      - \"$NETZ.1:$GARAGE_PORT:3900\""
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
      - "$NETZ.1:$DB_PORT:5432"
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
  printf '{"pub":"%s","port":%s,"paket":%s,"nfsPfad":"%s","dbPort":%s,"garagePort":%s}\n' "$(wg show "$WG" public-key)" "$PORT" "$paket" "${1:-}" "$DB_PORT" "$GARAGE_PORT" > "$DATEN/.knoten-tunnel"
  chmod 644 "$DATEN/.knoten-tunnel"
}

vorbereiten() {
  local nfs="${1:-}" pfad=""
  tunnel_aufbauen
  [ "$nfs" = "nfs" ] && pfad=$(ordner_freigeben)
  compose_erweitern
  info_schreiben "$pfad"
}

peer_eintragen() {
  local pub="$1" ip="$2"
  [ -f "$CONF" ] || fehler "Der Tunnel ist nicht eingerichtet / tunnel not set up"
  [ -f "$EXPORTS" ] && nfs_im_tunnel_erlauben
  peer_austragen "$ip"
  wg set "$WG" peer "$pub" allowed-ips "$ip/32" || fehler "Der Server ließ sich nicht eintragen / could not add the server"
  printf '\n# knoten %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n# ende %s\n' "$ip" "$pub" "$ip" "$ip" >> "$CONF"
}

peer_austragen() {
  local ip="$1" alt
  alt=$(wg show "$WG" allowed-ips 2>/dev/null | awk -v i="$ip/32" '$2 == i {print $1}')
  [ -n "$alt" ] && wg set "$WG" peer "$alt" remove
  sed -i "/^# knoten $ip\$/,/^# ende $ip\$/d" "$CONF" 2>/dev/null || true
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
    case "$k" in haupt|10.87.0.[0-9]*) ;; *) rm -f "$neu"; fehler "Ungültiger Server: $k" ;; esac
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
  web-neu) if [ -s "$WEB" ]; then web_verteilen; fi ;;
  gewichte) gewichte_setzen "$1" "${2:-1}" ;;
  web-an) web_an "$1" ;;
  web-aus) web_aus "$1" ;;
  *) fehler "Unbekannte Aktion: $aktion" ;;
esac
