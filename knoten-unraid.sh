# Unraid: Alles außer /boot und /mnt liegt im Arbeitsspeicher, und es gibt weder systemd noch Paketverwaltung.
# Darum liegt der Tunnel auf dem USB-Stick, und ein kleiner Wächter stellt ihn nach jedem Neustart wieder her.
# Die Einstellungen von Unraid selbst bleiben unberührt: kein Eintrag in /boot/config/wireguard, nichts an wg0 und Co.
# Diese Datei gibt es zweimal, in server/assets und in deploy. Beide müssen gleich sein.
UR_ORDNER=/boot/config/plugins/reddrop-knoten
UR_CRON=/boot/config/plugins/dynamix/reddrop-knoten.cron
UR_GO=/boot/config/go
UR_ANFANG='# >>> RedDrop: Server im Verbund. Wird beim Entfernen wieder gelöscht.'
UR_ENDE='# <<< RedDrop'
UR_COMPOSE=v2.29.7

ist_unraid() { [ -f /etc/unraid-version ] && [ -d /boot/config ]; }

# Fehlt das Compose-Plugin, kommt eine geprüfte Fassung auf den Stick. Das Installationsskript von Docker darf hier nie laufen.
ur_compose() {
  docker compose version >/dev/null 2>&1 && { docker compose version; return 0; }
  local art t quelle soll
  case "$(uname -m)" in
    x86_64) art=x86_64 ;;
    aarch64) art=aarch64 ;;
    *) echo "uname: $(uname -m)"; return 1 ;;
  esac
  quelle="https://github.com/docker/compose/releases/download/$UR_COMPOSE/docker-compose-linux-$art"
  t=$(mktemp -d)
  echo "$quelle"
  curl -fsSL --max-time 300 -o "$t/docker-compose" "$quelle" && curl -fsSL --max-time 60 -o "$t/summe" "$quelle.sha256" || { rm -rf "$t"; return 1; }
  soll=$(cut -d' ' -f1 "$t/summe")
  [ -n "$soll" ] && [ "$(sha256sum "$t/docker-compose" | cut -d' ' -f1)" = "$soll" ] || { echo "sha256"; rm -rf "$t"; return 1; }
  mkdir -p "$UR_ORDNER" /usr/local/lib/docker/cli-plugins || { rm -rf "$t"; return 1; }
  cp -f "$t/docker-compose" "$UR_ORDNER/docker-compose" || { rm -rf "$t"; return 1; }
  cp -f "$t/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
  chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf "$t"
  docker compose version
}

# Überträgt den Tunnel und die Freigabe auf den Stick. Danach übersteht beides den nächsten Neustart.
ur_sichern() {
  ist_unraid || return 0
  [ -d "$UR_ORDNER" ] || return 0
  [ -f /etc/wireguard/rd0.conf ] && cp -f /etc/wireguard/rd0.conf "$UR_ORDNER/rd0.conf"
  if [ -f /etc/exports.d/reddrop.exports ]; then cp -f /etc/exports.d/reddrop.exports "$UR_ORDNER/exports"; else rm -f "$UR_ORDNER/exports"; fi
  return 0
}

ur_wache_schreiben() {
  cat > "$UR_ORDNER/wache.neu" <<'WACHE'
#!/bin/bash
# RedDrop auf Unraid: Läuft beim Start und jede Minute. Stellt wieder her, was ein Neustart aus dem Arbeitsspeicher gelöscht hat.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
P=/boot/config/plugins/reddrop-knoten
[ -d "$P" ] || exit 0
exec 9>/tmp/reddrop-knoten.sperre
flock -n 9 || exit 0

if [ -f "$P/rd0.conf" ]; then
  if [ ! -f /etc/wireguard/rd0.conf ]; then
    mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
    cp -f "$P/rd0.conf" /etc/wireguard/rd0.conf && chmod 600 /etc/wireguard/rd0.conf
  fi
  ip link show rd0 >/dev/null 2>&1 || wg-quick up rd0 >/dev/null 2>&1
fi

if [ -f "$P/exports" ] && [ ! -f /etc/exports.d/reddrop.exports ]; then
  mkdir -p /etc/exports.d
  cp -f "$P/exports" /etc/exports.d/reddrop.exports
  exportfs -ra >/dev/null 2>&1
fi
# Die Freigabe braucht den NFS-Dienst, auch wenn er unter Einstellungen nicht eingeschaltet ist. Sie gilt nur für den Tunnel.
if [ -f "$P/exports" ] && ! pgrep -x nfsd >/dev/null 2>&1 && [ -x /etc/rc.d/rc.nfsd ]; then
  /etc/rc.d/rc.nfsd start >/dev/null 2>&1
  exportfs -ra >/dev/null 2>&1
fi

if [ -f "$P/docker-compose" ] && [ ! -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then
  mkdir -p /usr/local/lib/docker/cli-plugins
  cp -f "$P/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
  chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
fi

# Docker läuft erst mit dem Array, und Unraid hält beim Stoppen alle Container an. Darum einmal je Docker-Start hochfahren.
docker info >/dev/null 2>&1 || exit 0
Z=$(cat "$P/ziel" 2>/dev/null)
[ -n "$Z" ] && [ -f "$Z/docker-compose.yml" ] || exit 0
S=$(pidof dockerd 2>/dev/null)
if [ -n "$S" ] && [ "$S" != "$(cat /tmp/reddrop-knoten.docker 2>/dev/null)" ]; then
  if ( cd "$Z" && timeout 300 docker compose up -d ) >/dev/null 2>&1; then printf '%s' "$S" > /tmp/reddrop-knoten.docker; fi
fi

[ -f "$P/reddrop-knoten-update" ] && bash "$P/reddrop-knoten-update" >/dev/null 2>&1
exit 0
WACHE
  bash -n "$UR_ORDNER/wache.neu" || { rm -f "$UR_ORDNER/wache.neu"; return 1; }
  mv -f "$UR_ORDNER/wache.neu" "$UR_ORDNER/wache.sh"
}

# Entfernt nur den eigenen, markierten Block. Der Rest der Datei bleibt Zeichen für Zeichen, wie er war.
ur_go_ohne_block() {
  [ -f "$UR_GO" ] || return 0
  grep -qxF "$UR_ANFANG" "$UR_GO" || return 0
  local t
  t=$(mktemp)
  awk -v a="$UR_ANFANG" -v e="$UR_ENDE" '$0 == a { weg = 1; next } weg && $0 == e { weg = 0; next } !weg { print }' "$UR_GO" > "$t" || { rm -f "$t"; return 1; }
  if [ -f "$UR_ORDNER/go-ohne-zeilenende" ]; then printf '%s' "$(cat "$t")" > "$UR_GO"; else cat "$t" > "$UR_GO"; fi
  rm -f "$t" "$UR_ORDNER/go-ohne-zeilenende"
}
ur_go_mit_block() {
  [ -f "$UR_GO" ] || return 1
  ur_go_ohne_block
  # Fehlt am Ende der Zeilenumbruch, hinge der Block sonst an der letzten Zeile.
  if [ -n "$(tail -c 1 "$UR_GO")" ]; then printf '\n' >> "$UR_GO"; : > "$UR_ORDNER/go-ohne-zeilenende"; fi
  printf '%s\n%s\n%s\n' "$UR_ANFANG" "[ -f $UR_ORDNER/wache.sh ] && bash $UR_ORDNER/wache.sh >/dev/null 2>&1 &" "$UR_ENDE" >> "$UR_GO"
}

# Unraid baut seinen Zeitplan beim Start aus den .cron-Dateien auf dem Stick. Dateien in /etc/cron.d führt es nicht aus.
ur_cron_drin() {
  local alle
  alle="$(cat /etc/cron.d/root 2>/dev/null || true)"
  case "$alle" in *plugins/reddrop-knoten/wache.sh*) return 0 ;; esac
  return 1
}
ur_cron_an() {
  local zeile="* * * * * bash $UR_ORDNER/wache.sh >/dev/null 2>&1" t
  mkdir -p "$(dirname "$UR_CRON")" || return 1
  printf '%s\n%s\n\n' '# RedDrop: Server im Verbund' "$zeile" > "$UR_CRON"
  if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
  if ! ur_cron_drin && [ -d /etc/cron.d ]; then
    t=$(mktemp)
    { cat /etc/cron.d/root 2>/dev/null || true; echo "$zeile"; } > "$t" && cat "$t" > /etc/cron.d/root
    rm -f "$t"
    crontab /etc/cron.d/root -c /etc/cron.d >/dev/null 2>&1 || true
  fi
  ur_cron_drin
}

# Aufruf mit dem Ordner, in dem die docker-compose.yml liegt.
ur_einrichten() {
  ist_unraid || return 0
  mkdir -p "$UR_ORDNER" || return 1
  printf '%s\n' "$1" > "$UR_ORDNER/ziel" || return 1
  ur_wache_schreiben || return 1
  ur_sichern
  ur_go_mit_block || return 1
  ur_cron_an || return 1
  # Für den laufenden Docker-Dienst ist schon alles gestartet oder startet gleich. Erst der nächste Docker-Start zählt.
  pidof dockerd 2>/dev/null | tr -d '\n' > /tmp/reddrop-knoten.docker
  echo "$UR_ORDNER"
}

ur_weg() {
  ist_unraid || return 0
  ur_go_ohne_block
  rm -f "$UR_CRON"
  if [ -f /etc/cron.d/root ]; then
    if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
    if ur_cron_drin; then
      sed -i '\#plugins/reddrop-knoten/wache\.sh#d' /etc/cron.d/root
      crontab /etc/cron.d/root -c /etc/cron.d >/dev/null 2>&1 || true
    fi
  fi
  # Das Plugin nur löschen, wenn es von hier stammt. Ein eigenes, etwa vom Compose Manager, liegt woanders und bleibt.
  if [ -f "$UR_ORDNER/docker-compose" ]; then rm -f /usr/local/lib/docker/cli-plugins/docker-compose; fi
  rm -rf "$UR_ORDNER"
  rm -f /tmp/reddrop-knoten.docker /tmp/reddrop-knoten.sperre /usr/local/bin/reddrop-knoten-update
}
