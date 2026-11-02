#!/usr/bin/env bash
set -uo pipefail
WG=rd0
NETZ=10.87.0
PORT=51877
CONF=/etc/wireguard/$WG.conf
EXPORTS=/etc/exports.d/reddrop.exports
WEB=.knoten-web
NGINX_LB=/etc/nginx/conf.d/reddrop-knoten.conf
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
  printf '%s' "$quelle"
}

compose_erweitern() {
  local garage="" alt
  if grep -q '^COMPOSE_PROFILES=.*speicher' .env; then
    garage="  garage:
    ports:
      - \"$NETZ.1:3900:3900\""
  fi
  cat > compose.tunnel.yml <<EOF
services:
  db:
    ports:
      - "$NETZ.1:5432:5432"
$garage
EOF
  alt=$(sed -n 's/^COMPOSE_FILE=//p' .env | tail -1)
  case ":$alt:" in
    *:compose.tunnel.yml:*) ;;
    *) sed -i "s#^COMPOSE_FILE=.*#COMPOSE_FILE=$alt:compose.tunnel.yml#" .env ;;
  esac
  docker compose up -d db ${garage:+garage} >/dev/null 2>&1 || fehler "Die Datenbank ließ sich nicht im Tunnel freigeben / could not expose the database in the tunnel"
}

info_schreiben() {
  local paket=false
  [ -f .paket ] && paket=true
  printf '{"pub":"%s","port":%s,"paket":%s,"nfsPfad":"%s"}\n' "$(wg show "$WG" public-key)" "$PORT" "$paket" "${1:-}" > "$DATEN/.knoten-tunnel"
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

web_verteilen() {
  local ziele="" port ip
  [ -f "$WEB" ] && ziele=$(tr '\n' ' ' < "$WEB")
  if grep -q 'compose.caddy.yml' .env; then
    [ -f Caddyfile.original ] || cp Caddyfile Caddyfile.original
    if [ -n "$ziele" ]; then
      local liste=""
      for ip in $ziele; do liste="$liste $ip:3000"; done
      sed -E "s#^([[:space:]]*)reverse_proxy app:3000[[:space:]]*\$#\1reverse_proxy app:3000$liste {\n\1\tlb_policy cookie\n\1}#" Caddyfile.original > Caddyfile
    else
      cp Caddyfile.original Caddyfile
    fi
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fehler "Caddy ließ sich nicht neu laden / could not reload Caddy"
    return 0
  fi
  port=$(sed -n 's/^RD_PORT=//p' .env | tail -1)
  if command -v nginx >/dev/null 2>&1; then
    local datei
    datei=$(grep -rlE "proxy_pass[[:space:]]+http://(127\.0\.0\.1:$port|reddrop_knoten)" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | grep -v "$NGINX_LB" | head -1)
    [ -n "$datei" ] || fehler "Kein nginx-Eintrag für Port $port gefunden. Bitte die Server von Hand eintragen / no nginx entry for port $port, please add the servers by hand"
    local sicherung="$datei.vor-knoten"
    cp -p "$datei" "$sicherung"
    local lb_alt=""
    [ -f "$NGINX_LB" ] && lb_alt=$(cat "$NGINX_LB")
    if [ -n "$ziele" ]; then
      { echo "upstream reddrop_knoten {"; echo "    ip_hash;"; echo "    server 127.0.0.1:$port;"; for ip in $ziele; do echo "    server $ip:3000;"; done; echo "}"; } > "$NGINX_LB"
      sed -i -E "s#proxy_pass[[:space:]]+http://127\.0\.0\.1:$port;#proxy_pass http://reddrop_knoten;#" "$datei"
    else
      rm -f "$NGINX_LB"
      sed -i -E "s#proxy_pass[[:space:]]+http://reddrop_knoten;#proxy_pass http://127.0.0.1:$port;#" "$datei"
    fi
    if nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; then
      rm -f "$sicherung"
      return 0
    fi
    mv -f "$sicherung" "$datei"
    if [ -n "$lb_alt" ]; then printf '%s\n' "$lb_alt" > "$NGINX_LB"; else rm -f "$NGINX_LB"; fi
    fehler "nginx lehnt die neue Einstellung ab, die alte bleibt aktiv / nginx rejected the change, the old one stays active"
  fi
  fehler "Dieser Webserver wird nicht automatisch angepasst. Bitte den Server von Hand im Lastverteiler eintragen / this web server is not adjusted automatically, please add the server to your load balancer by hand"
}

web_an() {
  touch "$WEB"
  grep -qxF "$1" "$WEB" || echo "$1" >> "$WEB"
  web_verteilen
}

web_aus() {
  [ -f "$WEB" ] || return 0
  sed -i "/^$1\$/d" "$WEB"
  web_verteilen
}

aktion="${1:-}"
shift || true
case "$aktion" in
  vorbereiten) vorbereiten "${1:-}" ;;
  peer)
    peer_eintragen "$1" "$2"
    if [ "${3:-}" = "web" ]; then web_an "$2"; fi
    ;;
  peer-weg) web_aus "$1" || true; peer_austragen "$1" ;;
  web-neu) if [ -s "$WEB" ]; then web_verteilen; fi ;;
  *) fehler "Unbekannte Aktion: $aktion" ;;
esac
