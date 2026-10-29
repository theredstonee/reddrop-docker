#!/usr/bin/env bash
# RedDrop — Installation auf einem Linux-Server (Debian/Ubuntu, auch RHEL-Verwandte).
# One-liner / Einzeiler (installs to /opt/reddrop, other folder: RD_DIR=/path):
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/install.sh | sudo bash
# Oder im Ordner mit den Dateien:  sudo bash install.sh
# Entfernen / Uninstall:  sudo bash /opt/reddrop/install.sh --uninstall
#
# Zwei Wege nach aussen, der Installer erkennt selbst, welcher passt:
#   Caddy  — Port 80/443 sind frei: eigener Caddy mit automatischem HTTPS (Let's Encrypt).
#   Port   — Port 80/443 sind schon belegt (nginx, Apache, Plesk …): die App bekommt einen freien
#            Port auf 127.0.0.1, dein Webserver bekommt einen Virtual Host fuer die Domain.
#
# Schalter (optional):  --lang en|de  --port 8080  --domain drop.firma.de  --email du@firma.de
#                       --caddy (Caddy erzwingen)  --no-vhost (keinen Virtual Host anlegen)
#                       --virenscan / --no-virenscan (ClamAV mitstarten, ~1,5 GB RAM; sonst fragt er)
#                       --uninstall / --deinstallieren (Container, Webserver-Eintraege, auf Wunsch alle Daten)
# Ein zweiter Aufruf aktualisiert nur (Image ziehen, neu starten) und fragt nichts mehr.
# Nur aktualisieren (nichts neu einrichten, keine Fragen):
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/update.sh | sudo bash
set -euo pipefail
QUELLE="${RD_QUELLE:-https://raw.githubusercontent.com/theredstonee/reddrop-docker/main}"   # RD_QUELLE nur fuer Tests
DATEIEN="docker-compose.yml compose.caddy.yml compose.port.yml compose.node.yml Caddyfile install.sh update.sh .env.example README.md version.json"
# Unraid: ausser /boot (USB-Stick) und /mnt (Array/Cache) liegt alles im Arbeitsspeicher — nach einem Neustart waeren
# Compose-Dateien und .env weg (die Datenbank im Docker-Volume bleibt, passt dann aber nicht mehr zu einer neuen .env).
# Darum gehoert die Installation dort nach /mnt/user/appdata/<Ordnername>: gleicher Name → gleicher Compose-Projektname
# → dieselben Volumes. unraid_ziel <ordner> gibt den dauerhaften Ordner aus, wenn <ordner> im Arbeitsspeicher liegt.
unraid_ziel() {
  [ -f /etc/unraid-version ] && [ -d /mnt/user ] || return 1
  case "$1" in /mnt/*|/boot/*) return 1 ;; esac
  printf '%s' "/mnt/user/appdata/$(basename "$1")"
}
# unraid_umziehen <alt> <neu> — Ordner kopieren, Dienst + Zeitplan auf den neuen Ordner umstellen, alten beiseitelegen.
# Die laufenden Container bleiben, bis sie aus dem neuen Ordner neu gestartet werden (Update/Installation tun das).
unraid_umziehen() {
  local alt="$1" neu="$2" a f
  [ -f "$alt/docker-compose.yml" ] || return 1
  if [ -e "$neu" ] && [ -n "$(ls -A "$neu" 2>/dev/null)" ]; then return 1; fi
  mkdir -p "$neu" && cp -a "$alt/." "$neu/" || { rm -rf "$neu"; return 1; }
  a=$(printf '%s' "$alt" | sed 's/[][\.*^$#]/\\&/g')
  for f in /usr/local/bin/reddrop-update /boot/config/plugins/reddrop/reddrop-update /boot/config/plugins/dynamix/reddrop-update.cron /etc/cron.d/root; do
    [ -f "$f" ] && sed -i "s#\\([=\"' ]\\)$a\\([/\"';]\\|\$\\)#\\1$neu\\2#g" "$f"
  done
  if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
  mv "$alt" "$alt.umgezogen-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  return 0
}
# inst_suchen — vorhandene RedDrop-Installation(en) finden, auch mit anderem Ordnernamen oder an ungewoehnlichem Ort.
# Docker Compose merkt sich den Ordner jeder Installation im Container-Label. Vorrang: laufende Installationen, dann
# gestoppte, erst danach Ordner auf der Platte mit einer docker-compose.yml fuer unser Image. Ein Ordner pro Zeile.
inst_ordner() { # inst_ordner <docker-ps-Schalter …> — Ordner der passenden App-Container
  local c d img
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)
    case "$img" in *theredstonee/reddrop:*|*theredstonee/reddrop) ;; *) continue ;; esac
    d=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)
    [ -n "$d" ] && [ -f "$d/docker-compose.yml" ] && [ -f "$d/.env" ] && printf '%s\n' "$d"
  done < <(docker ps "$@" -q --filter label=com.docker.compose.service=app 2>/dev/null)
}
inst_suchen() {
  local f d t
  t=$(inst_ordner | awk 'NF && !s[$0]++'); [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  t=$(inst_ordner -a | awk 'NF && !s[$0]++'); [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  while IFS= read -r f; do
    case "$f" in */.sicherung/*|*.umgezogen-*|*/.trash*) continue ;; esac
    grep -q 'theredstonee/reddrop:' "$f" 2>/dev/null || continue
    grep -q 'theredstonee/redclub:' "$f" 2>/dev/null && continue   # RedClub mit eingebautem RedDrop
    d=$(dirname "$f"); [ -f "$d/.env" ] && printf '%s\n' "$d"
  done < <(find /opt /srv /root /home /mnt/user/appdata /mnt/cache/appdata /docker /data -maxdepth 3 -name docker-compose.yml 2>/dev/null) | awk 'NF && !s[$0]++'
}
GEFUNDEN=""
if [ -z "${RD_DIR:-}" ] && ! { [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; }; then
  g_alle=$(inst_suchen 2>/dev/null || true)
  case "$(printf '%s\n' "$g_alle" | grep -c . || true)" in
    0) ;;
    1) GEFUNDEN="$g_alle"; echo "==> RedDrop: vorhandene Installation gefunden / existing installation found: $GEFUNDEN" ;;
    *) echo "==> Mehrere RedDrop-Installationen gefunden / several installations found:"; printf '      %s\n' $g_alle
       echo "    Bitte die richtige waehlen / please pick one: curl -fsSL $QUELLE/install.sh | sudo RD_DIR=/pfad bash"; exit 1 ;;
  esac
fi
UNRAID_ZIEL=""
if [ -z "${RD_DIR:-}" ] && [ -f /etc/unraid-version ] && [ -d /mnt/user ]; then
  UNRAID_ZIEL="/mnt/user/appdata/reddrop"
  u_hier=""; if [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; then u_hier="$(cd "$(dirname "$0")" && pwd)"; fi
  u_alt="${u_hier:-${GEFUNDEN:-/opt/reddrop}}"
  if u_neu=$(unraid_ziel "$u_alt") && [ -f "$u_alt/docker-compose.yml" ]; then
    if unraid_umziehen "$u_alt" "$u_neu"; then
      echo "==> Unraid: $u_alt -> $u_neu (übersteht Neustarts / survives reboots)"
      UNRAID_ZIEL="$u_neu"; [ -n "$GEFUNDEN" ] && GEFUNDEN="$u_neu"
      if [ -n "$u_hier" ]; then
        cd "$u_neu"
        if { true </dev/tty; } 2>/dev/null; then exec bash ./install.sh "$@" </dev/tty; else exec bash ./install.sh "$@"; fi
      fi
    else
      echo "==> Unraid: $u_alt liegt im Arbeitsspeicher, $u_neu ist schon belegt — bitte selbst umziehen / in RAM, $u_neu is taken — please move it yourself"
      UNRAID_ZIEL=""
    fi
  fi
fi
# Ueber curl | bash gestartet (oder Dateien fehlen): alles nach /opt/reddrop (Unraid: /mnt/user/appdata/reddrop) holen und dort weitermachen
if [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; then
  cd "$(dirname "$0")"
else
  ZIEL="${RD_DIR:-${GEFUNDEN:-${UNRAID_ZIEL:-/opt/reddrop}}}"
  echo "==> RedDrop: $ZIEL"
  mkdir -p "$ZIEL" && cd "$ZIEL"
  for f in $DATEIEN; do curl -fsSL -o "$f" "$QUELLE/$f" || { [ "$f" = "version.json" ] || { echo "ERROR: $f"; exit 1; }; }; done
  # Fragen brauchen das Terminal (stdin ist bei curl | bash die Leitung) — ohne Terminal gelten die Vorgaben
  # Rest des Skripts aus der curl-Leitung leer lesen: exec schliesst sie sonst, waehrend curl noch schreibt
  # (Meldung „curl: (23) Failure writing output to destination“ am Ende, obwohl alles geklappt hat)
  [ -t 0 ] || cat >/dev/null 2>&1 || true
  if { true </dev/tty; } 2>/dev/null; then exec bash ./install.sh "$@" </dev/tty; else exec bash ./install.sh "$@"; fi
fi

PORT=""; DOMAIN=""; EMAIL=""; MODUS=""; VHOST="ja"; WEG=""; SPR=""; VS=""; NUR_DIENST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) SPR="${2,,}"; shift 2 ;;
    --port) PORT="$2"; MODUS="port"; shift 2 ;;
    --domain) DOMAIN="${2,,}"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --caddy) MODUS="caddy"; shift ;;
    --no-vhost) VHOST="nein"; shift ;;
    --dienst) NUR_DIENST="ja"; shift ;;   # nur den Update-Dienst neu einrichten (ruft update.sh auf)
    --virenscan) VS="ja"; shift ;;
    --no-virenscan) VS="nein"; shift ;;
    --deinstallieren|--uninstall) WEG="ja"; shift ;;
    *) echo "Unknown option / Unbekannter Schalter: $1"; exit 1 ;;
  esac
done

# Aussehen: Farben nur im Terminal (RD_FARBE=1 erzwingt sie, NO_COLOR/TERM=dumb schaltet sie ab), Zeichen nur mit UTF-8
if { [ -t 1 ] || [ -n "${RD_FARBE:-}" ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  R=$'\033[38;2;232;48;48m'; R2=$'\033[38;2;255;110;100m'; G=$'\033[38;2;74;222;128m'; Y=$'\033[38;2;251;191;36m'
  C=$'\033[38;2;125;211;252m'; D=$'\033[2m'; B=$'\033[1m'; U=$'\033[4m'; N=$'\033[0m'
else R=""; R2=""; G=""; Y=""; C=""; D=""; B=""; U=""; N=""; fi
if locale charmap 2>/dev/null | grep -qi 'utf-\?8' || echo "${LANG:-}${LC_ALL:-}" | grep -qi 'utf-\?8'; then
  Z_SCHRITT="▸"; Z_OK="✔"; Z_FEHLER="✖"; Z_FRAGE="?"; Z_PUNKT="·"; K_OL="╭"; K_OR="╮"; K_UL="╰"; K_UR="╯"; K_H="─"; K_V="│"; SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  Z_SCHRITT=">"; Z_OK="OK"; Z_FEHLER="X"; Z_FRAGE="?"; Z_PUNKT="-"; K_OL="+"; K_OR="+"; K_UL="+"; K_UR="+"; K_H="-"; K_V="|"; SPIN=('|' '/' '-' '\')
fi
VERSION_TXT=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' version.json 2>/dev/null | head -1 || true)
banner() {
  echo ""
  printf '%s\n' "${R}${B}   ██████╗ ███████╗██████╗ ${R2}██████╗ ██████╗  ██████╗ ██████╗ ${N}" \
                "${R}${B}   ██╔══██╗██╔════╝██╔══██╗${R2}██╔══██╗██╔══██╗██╔═══██╗██╔══██╗${N}" \
                "${R}${B}   ██████╔╝█████╗  ██║  ██║${R2}██║  ██║██████╔╝██║   ██║██████╔╝${N}" \
                "${R}${B}   ██╔══██╗██╔══╝  ██║  ██║${R2}██║  ██║██╔══██╗██║   ██║██╔═══╝ ${N}" \
                "${R}${B}   ██║  ██║███████╗██████╔╝${R2}██████╔╝██║  ██║╚██████╔╝██║     ${N}" \
                "${R}${B}   ╚═╝  ╚═╝╚══════╝╚═════╝ ${R2}╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝     ${N}"
  echo "   ${D}Selbst gehostetes Datei- und Medien-Hosting ${Z_PUNKT} self-hosted file & media hosting${N}"
  echo "   ${D}${VERSION_TXT:+v$VERSION_TXT  ${Z_PUNKT}  }by TheRedStonee ${Z_PUNKT} https://www.theredstonee.de/reddrop/${N}"
  echo ""
}
# Kasten um wichtige Werte (Setup-Code, Adresse): kasten FARBE "Zeile" ["Zeile" …]
kasten() {
  local farbe="$1"; shift
  local breit=0 z
  for z in "$@"; do [ ${#z} -gt $breit ] && breit=${#z}; done
  local linie; linie=$(printf "%$((breit + 4))s" "" | sed "s/ /${K_H}/g")
  echo "  ${farbe}${K_OL}${linie}${K_OR}${N}"
  # von Hand auffuellen: printf zaehlt Bytes, ${#z} Zeichen (Umlaute, „·“)
  for z in "$@"; do printf '  %s%s%s  %s%s%s%*s  %s%s%s\n' "$farbe" "$K_V" "$N" "$B" "$z" "$N" $((breit - ${#z})) "" "$farbe" "$K_V" "$N"; done
  echo "  ${farbe}${K_UL}${linie}${K_UR}${N}"
}
[ -n "${RD_KEIN_BANNER:-}" ] || banner

# Sprache: Schalter → .env → fragen (Standard Englisch)
[ -n "$SPR" ] || SPR=$(sed -n 's/^RD_LANG=//p' .env 2>/dev/null | tail -1 || true)
if [ "$SPR" != "de" ] && [ "$SPR" != "en" ]; then
  SPR="en"
  if [ -t 0 ]; then
    echo ""
    echo "  ${Y}${Z_FRAGE}${N} ${B}Language / Sprache:${N}   ${C}1${N}) English   ${C}2${N}) Deutsch"
    read -r -p "    [1] " wahl </dev/tty || true
    case "${wahl:-1}" in 2|de|d|deutsch|Deutsch) SPR="de" ;; esac
  fi
fi
s() { if [ "$SPR" = "de" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # s "deutsch" "english"
say() { # Meldung je Art einfaerben: „==> Fertig/Done“ gruen, „==> “ Schritt, FEHLER/ERROR rot, eingerueckt = Detail
  local m; m=$(s "$1" "$2")
  m=$(printf '%s' "$m" | sed -E "s#(https?://[^ )\"']+)#${C}${U}\1${N}#g")
  case "$m" in
    "==> Fertig"*|"==> Done"*) echo ""; echo "${G}${B}${Z_OK} ${m#==> }${N}" ;;
    "==> "*) echo "${R}${B}${Z_SCHRITT}${N} ${B}${m#==> }${N}" ;;
    FEHLER:*|ERROR:*) echo "${R}${B}${Z_FEHLER} ${m}${N}" ;;
    "    FEHLER"*|"    ERROR"*) echo "  ${R}${Z_FEHLER}${N} ${m#    }" ;;
    "    "*) echo "  ${D}${K_V}${N} ${m#    }" ;;
    *) echo "$m" ;;
  esac
}

# Zum Testen: RD_DRY_RUN=1 zeigt Aenderungen am Webserver nur an, statt sie auszufuehren.
tu() { if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $*"; else "$@"; fi; }
frage() { # frage "Text" "Vorgabe" -> Antwort (ohne Terminal: Vorgabe)
  local antwort=""
  local text="$1"; text="${text#==> }"; text="${text#    }"
  if [ -t 0 ]; then read -r -p "  ${Y}${Z_FRAGE}${N} ${text} ${D}[$2]${N} " antwort </dev/tty || true; fi
  echo "${antwort:-$2}"
}
ja() { # ja "Text" "j|n" -> 0 bei ja (akzeptiert j/ja/y/yes)
  local vorgabe="$2" a
  [ "$SPR" = "en" ] && { [ "$vorgabe" = "j" ] && vorgabe="y"; }
  a=$(frage "$1 ($(s j/n y/n))" "$vorgabe"); case "${a,,}" in j|ja|y|yes) return 0 ;; *) return 1 ;; esac
}
belegt() { # lauscht etwas auf dem Port?
  if command -v ss >/dev/null 2>&1; then ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}
wer_lauscht() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//'; }

# Deinstallieren: Container weg, Webserver-Eintraege weg (mit Backup), auf Wunsch auch alle Daten und der Ordner
if [ -n "$WEG" ]; then
  say "==> RedDrop entfernen (Ordner: $PWD)" "==> Removing RedDrop (folder: $PWD)"
  daten="nein"
  if ja "    $(s "Auch ALLE hochgeladenen Dateien und die Datenbank loeschen? Das laesst sich nicht rueckgaengig machen." "Also delete ALL uploaded files and the database? This cannot be undone.")" "n"; then
    wort=$(s loeschen delete)
    bestaetigt=$(frage "    $(s "Zur Bestaetigung bitte  $wort  eintippen" "To confirm, please type  $wort")" "")
    [ "$bestaetigt" = "$wort" ] && daten="ja" || say "    Nicht bestaetigt — Dateien und Datenbank bleiben erhalten." "    Not confirmed — files and database are kept."
  fi
  if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
    if [ "$daten" = "ja" ]; then docker compose down -v --remove-orphans || true; else docker compose down --remove-orphans || true; fi
    docker image rm ghcr.io/theredstonee/reddrop:latest >/dev/null 2>&1 || true
  fi
  # Update-Dienst
  rm -f /etc/cron.d/reddrop-update
  if [ -f /etc/systemd/system/reddrop-update.path ]; then
    systemctl disable --now reddrop-update.path >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/reddrop-update.path /etc/systemd/system/reddrop-update.service /usr/local/bin/reddrop-update
    systemctl daemon-reload || true
  fi
  # Unraid: Dienst + Zeitplan auf dem USB-Stick
  if [ -d /boot/config/plugins/reddrop ]; then
    rm -rf /boot/config/plugins/reddrop /boot/config/plugins/dynamix/reddrop-update.cron /usr/local/bin/reddrop-update
    [ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron >/dev/null 2>&1
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
    say "==> Webserver-Eintraege entfernt (Sicherung in /root/reddrop-backup)." "==> Web server entries removed (backup in /root/reddrop-backup)."
  fi
  dom=$(sed -n 's/^RD_PROXY_DOMAIN=//p' .env 2>/dev/null | tail -1 || true)
  if [ -n "$dom" ] && command -v certbot >/dev/null 2>&1 && certbot certificates 2>/dev/null | grep -q "Certificate Name: $dom$"; then
    ja "    $(s "Zertifikat fuer $dom auch loeschen?" "Also delete the certificate for $dom?")" "n" && certbot delete --cert-name "$dom" -n || true
  fi
  if [ "$daten" = "ja" ]; then
    ordner="$PWD"; cd /
    if ja "    $(s "Ordner $ordner auch loeschen (inkl. .env und import/)?" "Also delete the folder $ordner (incl. .env and import/)?")" "j"; then rm -rf "$ordner"; say "==> Ordner entfernt." "==> Folder removed."; fi
    say "==> RedDrop ist vollstaendig entfernt." "==> RedDrop has been removed completely."
  else
    say "==> Container gestoppt und entfernt. Dateien, Datenbank und dieser Ordner sind noch da —" "==> Containers stopped and removed. Files, database and this folder are still there —"
    say "    neu starten mit  sudo bash install.sh  (gleiches Datenbank-Passwort aus der .env)." "    start again with  sudo bash install.sh  (same database password from .env)."
  fi
  exit 0
fi

# 5b. Update-Dienst: der Knopf „Jetzt aktualisieren“ im Panel legt eine Anfrage-Datei in /data ab, ein
#     systemd-Pfad-Dienst auf dem Server zieht dann das neue Image und startet die App neu. So braucht
#     RedDrop selbst keinen Zugriff auf Docker.
updater_einrichten() {
  DIENST_GRUND=""
  local app daten
  app=$(docker compose ps -q app 2>/dev/null || true)
  [ -n "$app" ] || { DIENST_GRUND="$(s "Der App-Container laeuft nicht (docker compose ps app ist leer)." "The app container is not running (docker compose ps app is empty).")"; return 1; }
  daten=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$app" 2>/dev/null || true)
  # Docker als Snap: docker inspect nennt /var/lib/docker/…, auf dem Server liegt es unter /var/snap/docker/common/var-lib-docker/…
  if [ -n "$daten" ] && [ ! -d "$daten" ] && [ -d "/var/snap/docker/common/var-lib-docker${daten#/var/lib/docker}" ]; then daten="/var/snap/docker/common/var-lib-docker${daten#/var/lib/docker}"; fi
  [ -n "$daten" ] && [ -d "$daten" ] || { DIENST_GRUND="$(s "Der Datenordner der App ($daten) ist vom Server aus nicht lesbar (Docker rootless oder in einer VM?)." "The app data folder ($daten) is not readable from the server (rootless Docker or inside a VM?).")"; return 1; }
  cat > /usr/local/bin/reddrop-update.neu <<SKRIPT
#!/usr/bin/env bash
# RedDrop — Update auf Anfrage aus dem Panel (angelegt von install.sh, systemd: reddrop-update.path)
set -uo pipefail
# cron (z. B. Unraid) startet mit sehr kurzem PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-}"
DIR="$PWD"; DATEN="$daten"; QUELLE="$QUELLE"
[ -f "\$DATEN/.update-anfrage" ] || exit 0
aktion=\$(sed -n 's/.*"aktion":"\([a-z-]*\)".*/\1/p' "\$DATEN/.update-anfrage")
tok=\$(sed -n 's#.*"token":"\([A-Za-z0-9+/=_-]*\)".*#\1#p' "\$DATEN/.update-anfrage")
rm -f "\$DATEN/.update-anfrage"
status() { printf '{"status":"%s","zeit":"%s","meldung":"%s"}\n' "\$2" "\$(date -Is)" "\$3" > "\$DATEN/\$1"; chmod 644 "\$DATEN/\$1"; }
kurz() { echo "\$1" | tail -3 | tr '\n"\\\\' '   '; }
profil() { # profil an|aus [name] — Profil (Standard "virenscan") in COMPOSE_PROFILES der .env
  local n="\${2:-virenscan}" p; p=\$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -1 | tr ',' ' ')
  p=\$(echo " \$p " | sed "s/ \$n / /g" | xargs)
  [ "\$1" = "an" ] && p=\$(echo "\$p \$n" | xargs)
  sed -i '/^COMPOSE_PROFILES=/d' .env
  [ -z "\$p" ] || echo "COMPOSE_PROFILES=\$(echo "\$p" | tr ' ' ',')" >> .env
}
cd "\$DIR" || { status .update-status fehler "Ordner \$DIR fehlt"; exit 1; }
case "\${aktion:-update}" in
  virenscan-an)
    status .virenscan-status laeuft ""; profil an
    if out=\$(docker compose up -d 2>&1); then status .virenscan-status fertig ""; else status .virenscan-status fehler "\$(kurz "\$out")"; fi ;;
  virenscan-aus)
    # Erst stoppen (solange das Profil noch aktiv ist), dann aus der .env nehmen
    status .virenscan-status laeuft ""
    if out=\$(docker compose stop clamav 2>&1 && docker compose rm -f clamav 2>&1); then profil aus; status .virenscan-status fertig ""; else status .virenscan-status fehler "\$(kurz "\$out")"; fi ;;
  tunnel-an)
    status .tunnel-status laeuft ""
    [ -n "\$tok" ] || { status .tunnel-status fehler "Kein Tunnel-Token in der Anfrage"; exit 1; }
    sed -i '/^RD_TUNNEL_TOKEN=/d' .env; echo "RD_TUNNEL_TOKEN=\$tok" >> .env; chmod 600 .env
    profil an tunnel
    if out=\$(docker compose up -d cloudflared 2>&1); then status .tunnel-status fertig ""; else status .tunnel-status fehler "\$(kurz "\$out")"; fi ;;
  tunnel-aus)
    status .tunnel-status laeuft ""
    if out=\$(docker compose stop cloudflared 2>&1 && docker compose rm -f cloudflared 2>&1); then profil aus tunnel; sed -i '/^RD_TUNNEL_TOKEN=/d' .env; status .tunnel-status fertig ""
    else status .tunnel-status fehler "\$(kurz "\$out")"; fi ;;
  *)
    status .update-status laeuft ""
    # Erst das neueste update.sh holen: es bringt Dateien, Image und diesen Dienst selbst auf den neuesten Stand
    neu=\$(mktemp)
    if curl -fsSL --max-time 30 -o "\$neu" "\$QUELLE/update.sh?t=\$(date +%s)" 2>/dev/null && bash -n "\$neu" 2>/dev/null; then
      RD_QUELLE="\$QUELLE" exec bash "\$neu" --dir "\$DIR" --status "\$DATEN/.update-status"
    fi
    rm -f "\$neu"
    # GitHub nicht erreichbar: wie bisher nur die Images
    dienste="app"; grep -q '^COMPOSE_PROFILES=.*virenscan' .env && dienste="\$dienste clamav"; grep -q '^COMPOSE_PROFILES=.*tunnel' .env && dienste="\$dienste cloudflared"
    if out=\$(docker compose pull \$dienste 2>&1 && docker compose up -d \$dienste 2>&1); then status .update-status fertig ""
    else status .update-status fehler "\$(kurz "\$out")"; fi ;;
esac
SKRIPT
  # erst fertig schreiben, dann umbenennen: ein gerade laufender Dienst liest so seine alte Fassung zu Ende
  chmod 755 /usr/local/bin/reddrop-update.neu && mv -f /usr/local/bin/reddrop-update.neu /usr/local/bin/reddrop-update
  local ausloeser=""
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    printf '%s\n' "[Unit]" "Description=RedDrop: Update-Anfrage aus dem Panel" "[Path]" "PathExists=$daten/.update-anfrage" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/reddrop-update.path
    printf '%s\n' "[Unit]" "Description=RedDrop aktualisieren" "[Service]" "Type=oneshot" "ExecStart=/usr/local/bin/reddrop-update" > /etc/systemd/system/reddrop-update.service
    if systemctl daemon-reload && systemctl enable --now reddrop-update.path >/dev/null 2>&1; then ausloeser="systemd"; rm -f /etc/cron.d/reddrop-update; fi
  fi
  # Unraid: kein systemd, /etc und /usr/local liegen im Arbeitsspeicher (nach dem Neustart weg), und cron liest
  # /etc/cron.d als Crontabs je Benutzer (Datei „root“, ohne Benutzerfeld) — eine eigene Datei dort laeuft nie.
  # update_cron baut die root-Crontab aus /boot/config/plugins/dynamix/*.cron (+ Ordner installierter Plugins mit .plg)
  # — bei jedem Start und jeder Zeitplan-Aenderung. Darum: Dienst auf den USB-Stick, Zeitplan nach dynamix/.
  if [ -z "$ausloeser" ] && [ -f /etc/unraid-version ] && [ -d /boot/config ]; then
    mkdir -p /boot/config/plugins/reddrop /boot/config/plugins/dynamix
    cp -f /usr/local/bin/reddrop-update /boot/config/plugins/reddrop/reddrop-update
    local zeile="* * * * * [ -f \"$daten/.update-anfrage\" ] && bash /boot/config/plugins/reddrop/reddrop-update >/dev/null 2>&1"
    printf '%s\n' "# RedDrop: Update-Anfrage aus dem Panel (angelegt von install.sh)" "$zeile" "" > /boot/config/plugins/dynamix/reddrop-update.cron
    rm -f /etc/cron.d/reddrop-update
    # steht der Eintrag in der Crontab, die Unraid-cron liest? (ohne Pipe: install.sh laeuft mit pipefail)
    rd_cron_drin() { local alle; alle="$(cat /etc/cron.d/root 2>/dev/null || true)"; case "$alle" in *plugins/reddrop/reddrop-update*) return 0 ;; esac; return 1; }
    # 1. Unraid-Weg
    if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
    # 2. update_cron fehlt oder liest dynamix/ nicht: direkt in die root-Crontab und cron neu laden lassen
    if ! rd_cron_drin && [ -d /etc/cron.d ]; then
      { cat /etc/cron.d/root 2>/dev/null || true; echo "$zeile"; } > /tmp/reddrop-cron.$$ && cat /tmp/reddrop-cron.$$ > /etc/cron.d/root
      rm -f /tmp/reddrop-cron.$$; crontab /etc/cron.d/root -c /etc/cron.d >/dev/null 2>&1 || true
    fi
    if rd_cron_drin; then ausloeser="cron (Unraid)"
    else
      DIENST_GRUND="$(s "Unraid: der Zeitplan liess sich nicht eintragen" "Unraid: the schedule could not be added") (Unraid $(cat /etc/unraid-version 2>/dev/null | tr -dc '0-9.' | head -c 12), update_cron: $([ -x /usr/local/sbin/update_cron ] && echo ja || echo nein), /etc/cron.d: $(ls /etc/cron.d 2>/dev/null | tr '\n' ' '), crond: $(pgrep -x crond >/dev/null 2>&1 && echo laeuft || echo aus))."
      return 1
    fi
  fi
  # Ohne systemd (z. B. Container-Server, Alpine): cron schaut jede Minute nach einer Anfrage
  if [ -z "$ausloeser" ] && [ -d /etc/cron.d ] && { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }; then
    printf '%s\n' "# RedDrop: Update-Anfrage aus dem Panel (angelegt von install.sh, ohne systemd)" "* * * * * root [ -f \"$daten/.update-anfrage\" ] && /usr/local/bin/reddrop-update >/dev/null 2>&1" > /etc/cron.d/reddrop-update
    chmod 644 /etc/cron.d/reddrop-update; ausloeser="cron"
  fi
  [ -n "$ausloeser" ] || { DIENST_GRUND="$(s "Weder systemd noch cron laufen auf diesem Server – ohne einen davon kann der Knopf im Panel nichts ausloesen." "Neither systemd nor cron is running on this server – without one the panel button cannot trigger anything.")"; return 1; }
  printf '%s\naktionen=update virenscan tunnel\nstand=2\n' "$PWD" > "$daten/.updater"; chmod 644 "$daten/.updater"
  say "==> Update-Dienst eingerichtet ($ausloeser; Panel → Version unten links → „Jetzt aktualisieren“)" "==> Update service set up ($ausloeser; panel → version at the bottom left → “Update now”)"
}


# Nur den Update-Dienst neu einrichten (update.sh ruft das nach jedem Update auf) — ohne Fragen, sonst bleibt alles
if [ -n "$NUR_DIENST" ]; then
  mkdir -p import && chmod 755 import
  updater_einrichten || { say "FEHLER: Update-Dienst nicht eingerichtet: $DIENST_GRUND" "ERROR: update service not set up: $DIENST_GRUND"; exit 1; }
  exit 0
fi

say "==> RedDrop wird eingerichtet" "==> Setting up RedDrop"

# 1. Docker (falls noch nicht da)
if ! command -v docker >/dev/null 2>&1; then
  say "==> Docker wird installiert …" "==> Installing Docker …"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { say "FEHLER: 'docker compose' fehlt. Bitte Docker aktualisieren." "ERROR: 'docker compose' is missing. Please update Docker."; exit 1; }
for f in docker-compose.yml compose.caddy.yml compose.port.yml Caddyfile; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$QUELLE/$f" || { say "FEHLER: $f fehlt neben install.sh und konnte nicht geladen werden." "ERROR: $f is missing next to install.sh and could not be downloaded."; exit 1; }
done

# 2. Bei wenig Arbeitsspeicher eine Auslagerungsdatei anlegen (unter 1,5 GB RAM, noch kein Swap)
ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$ram_mb" -lt 1500 ] && [ "$(swapon --noheadings 2>/dev/null | wc -l)" -eq 0 ] && [ ! -f /swapfile ]; then
  say "==> Nur ${ram_mb} MB RAM: lege 1 GB Auslagerungsdatei an …" "==> Only ${ram_mb} MB RAM: creating a 1 GB swap file …"
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. .env: Datenbank-Passwort nur beim ersten Mal (sonst passt es nicht mehr zur Datenbank)
# 3a. .env fehlt, aber die Container dieser Installation gibt es noch (z. B. Unraid nach einem Neustart: Ordner im RAM weg,
#     Docker-Volumes noch da): Datenbank-Passwort von dort — ein neu gewuerfeltes passte nicht mehr zur Datenbank.
#     Eine NEU angelegte .env wird bei einem Abbruch (Strg+C) vor Schritt 4 wieder entfernt — sonst fehlte spaeter der Weg nach aussen.
ENV_NEU=0; WEG_FERTIG=0
if [ ! -f .env ]; then
  env_db=$(docker ps -aq --filter "label=com.docker.compose.project=$(basename "$PWD")" --filter label=com.docker.compose.service=db 2>/dev/null || true)
  env_db=${env_db%%$'\n'*}
  env_pw=""
  [ -n "$env_db" ] && env_pw=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$env_db" 2>/dev/null | sed -n 's/^POSTGRES_PASSWORD=//p' || true)
  if [ -n "$env_pw" ]; then
    printf 'DB_PASSWORD=%s\nTZ=Europe/Berlin\n' "$env_pw" > .env && chmod 600 .env
    say "==> .env fehlte — Datenbank-Passwort aus dem vorhandenen Datenbank-Container übernommen" "==> .env was missing — database password taken from the existing database container"
  else
    ENV_NEU=1
  fi
fi
trap 'if [ "${ENV_NEU:-0}" = 1 ] && [ "${WEG_FERTIG:-0}" != 1 ]; then rm -f "$PWD/.env"; fi' EXIT
if [ ! -f .env ]; then
  printf 'DB_PASSWORD=%s\nTZ=Europe/Berlin\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > .env
  chmod 600 .env
  say "==> .env mit zufaelligem Datenbank-Passwort angelegt" "==> Created .env with a random database password"
fi
# Sprache merken — gilt auch fuer den Einrichtungs-Assistenten
if grep -q '^RD_LANG=' .env; then sed -i "s/^RD_LANG=.*/RD_LANG=$SPR/" .env; else echo "RD_LANG=$SPR" >> .env; fi

# Weg nach aussen sichern: kennt die .env keinen (z. B. nach einer abgebrochenen Einrichtung), wuerde ein Neustart den
# freigegebenen Port bzw. Caddy verlieren — dann vom laufenden Container uebernehmen, sonst aus der letzten Sicherung.
weg_retten() {
  WEG_GERETTET=""
  if grep -q '^COMPOSE_FILE=' .env 2>/dev/null; then return 0; fi
  local proj c port ip alt
  proj=$(basename "$PWD")
  c=$(docker ps -q --filter "label=com.docker.compose.project=$proj" --filter label=com.docker.compose.service=caddy 2>/dev/null || true)
  if [ -n "$c" ]; then
    echo "COMPOSE_FILE=docker-compose.yml:compose.caddy.yml" >> .env; WEG_GERETTET="Caddy"; return 0
  fi
  c=$(docker ps -q --filter "label=com.docker.compose.project=$proj" --filter label=com.docker.compose.service=app 2>/dev/null || true)
  c=${c%%$'\n'*}
  port=""; ip=""
  if [ -n "$c" ]; then
    port=$(docker inspect -f '{{with index .HostConfig.PortBindings "3000/tcp"}}{{(index . 0).HostPort}}{{end}}' "$c" 2>/dev/null || true)
    ip=$(docker inspect -f '{{with index .HostConfig.PortBindings "3000/tcp"}}{{(index . 0).HostIp}}{{end}}' "$c" 2>/dev/null || true)
  fi
  if [ -n "$port" ]; then
    # leere HostIp heisst: auf allen Adressen (so war es bisher erreichbar)
    printf 'COMPOSE_FILE=docker-compose.yml:compose.port.yml\nRD_PORT=%s\nRD_BIND=%s\n' "$port" "${ip:-0.0.0.0}" >> .env
    WEG_GERETTET="Port ${ip:-0.0.0.0}:$port"; return 0
  fi
  for alt in $(ls -1d .sicherung/*/ 2>/dev/null | sort -r); do
    if grep -q '^COMPOSE_FILE=' "${alt}.env" 2>/dev/null; then
      grep -E '^(COMPOSE_FILE|RD_PORT|RD_BIND|RD_PROXY_DOMAIN)=' "${alt}.env" >> .env || true
      WEG_GERETTET="Sicherung ${alt%/}"; return 0
    fi
  done
  return 0
}
weg_retten
[ -n "$WEG_GERETTET" ] && say "==> Die .env kannte keinen Weg nach außen — vom laufenden RedDrop übernommen ($WEG_GERETTET)" "==> .env had no way in — taken over from the running RedDrop ($WEG_GERETTET)"

# 4. Weg nach aussen festlegen — nur, solange die .env noch keinen kennt
if ! grep -q '^COMPOSE_FILE=' .env; then
  # Bestehende Installation mit altem Compose (Caddy stand noch in docker-compose.yml): Caddy behalten.
  if [ -z "$MODUS" ] && docker ps --filter "label=com.docker.compose.service=caddy" --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | grep -qx "$PWD"; then
    MODUS="caddy"
  fi
  if [ -z "$MODUS" ]; then
    if belegt 80 || belegt 443; then
      server=$(wer_lauscht 80 || true); [ -n "$server" ] || server=$(wer_lauscht 443 || true)
      echo ""
      say "==> Port 80/443 sind schon belegt (${server:-unbekannter Dienst})." "==> Port 80/443 are already in use (${server:-unknown service})."
      say "    RedDrop bekommt dann einen eigenen Port auf 127.0.0.1, und dein Webserver" "    RedDrop then gets its own port on 127.0.0.1, and your web server"
      say "    leitet die Domain dorthin weiter (Virtual Host, HTTPS ueber deinen Webserver)." "    forwards the domain to it (virtual host, HTTPS via your web server)."
      if ja "    $(s "So einrichten? Bei Nein versucht Caddy, Port 80/443 selbst zu belegen." "Set it up this way? If not, Caddy tries to take port 80/443 itself.")" "j"; then MODUS="port"; else MODUS="caddy"; fi
    else
      MODUS="caddy"
    fi
  fi

  if [ "$MODUS" = "port" ]; then
    if [ -z "$PORT" ]; then
      for p in 8080 8081 8082 8088 8090 8100 8180 8280 3100 3200 9080; do belegt "$p" || { PORT=$p; break; }; done
      [ -n "$PORT" ] || { say "FEHLER: kein freier Port gefunden. Bitte mit --port angeben." "ERROR: no free port found. Please pass one with --port."; exit 1; }
      PORT=$(frage "    $(s "Port fuer RedDrop (frei)" "Port for RedDrop (free)")" "$PORT")
    fi
    belegt "$PORT" && { say "FEHLER: Port $PORT ist belegt." "ERROR: port $PORT is in use."; exit 1; }
    [ -n "$DOMAIN" ] || DOMAIN=$(frage "    $(s "Domain, unter der das Panel laufen soll (leer = spaeter)" "Domain for the panel (empty = later)")" "")
    DOMAIN="${DOMAIN,,}"
    {
      echo "COMPOSE_FILE=docker-compose.yml:compose.port.yml"
      echo "RD_PORT=$PORT"
      echo "RD_BIND=127.0.0.1"
      echo "RD_PROXY_DOMAIN=$DOMAIN"
    } >> .env
    say "==> App hoert auf 127.0.0.1:$PORT (ohne eigenen Caddy)" "==> App listens on 127.0.0.1:$PORT (without its own Caddy)"
  else
    echo "COMPOSE_FILE=docker-compose.yml:compose.caddy.yml" >> .env
    say "==> Caddy uebernimmt Port 80/443 und holt das Zertifikat selbst" "==> Caddy takes port 80/443 and gets the certificate by itself"
  fi
fi
WEG_FERTIG=1
# 4b. Virenscan (ClamAV als eigener Container) — einmal fragen, danach im Panel umschaltbar
profil_setzen() { # profil_setzen an|aus  → COMPOSE_PROFILES in der .env um "virenscan" ergaenzen/kuerzen
  local p; p=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -1 | tr ',' ' ')
  p=$(echo " $p " | sed 's/ virenscan / /g' | xargs)
  [ "$1" = "an" ] && p=$(echo "$p virenscan" | xargs)
  sed -i '/^COMPOSE_PROFILES=/d' .env
  [ -z "$p" ] || echo "COMPOSE_PROFILES=$(echo "$p" | tr ' ' ',')" >> .env
}
if [ -n "$VS" ]; then
  profil_setzen "$([ "$VS" = "ja" ] && echo an || echo aus)"; grep -q '^RD_VIRENSCAN_GEFRAGT=' .env || echo "RD_VIRENSCAN_GEFRAGT=1" >> .env
elif ! grep -q '^RD_VIRENSCAN_GEFRAGT=' .env; then
  echo ""
  say "==> Virenscan: ClamAV prueft jede hochgeladene Datei, Funde kommen in Quarantaene." "==> Virus scan: ClamAV checks every uploaded file, findings are quarantined."
  say "    Braucht etwa 1,5 GB Arbeitsspeicher (dieser Server: ${ram_mb} MB). Spaeter im Panel umschaltbar." "    Needs about 1.5 GB of RAM (this server: ${ram_mb} MB). Can be switched later in the panel."
  if [ "$ram_mb" -ge 3000 ]; then vs_vorgabe="j"; else vs_vorgabe="n"; fi
  if ja "    $(s "Virenscan einschalten?" "Turn on the virus scan?")" "$vs_vorgabe"; then profil_setzen an; else profil_setzen aus; fi
  echo "RD_VIRENSCAN_GEFRAGT=1" >> .env
fi

# Werte aus der .env (auch bei einem zweiten Aufruf)
PORT=$(sed -n 's/^RD_PORT=//p' .env | tail -1)
[ -n "$DOMAIN" ] || DOMAIN=$(sed -n 's/^RD_PROXY_DOMAIN=//p' .env | tail -1)
grep -q 'compose.port.yml' .env && MODUS="port" || MODUS="caddy"
# --domain beim zweiten Aufruf: in der .env nachtragen, damit der Assistent sie vorwaehlt
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ]; then
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || { say "FEHLER: ungueltige Domain: $DOMAIN" "ERROR: invalid domain: $DOMAIN"; exit 1; }
  if grep -q '^RD_PROXY_DOMAIN=' .env; then sed -i "s|^RD_PROXY_DOMAIN=.*|RD_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RD_PROXY_DOMAIN=$DOMAIN" >> .env; fi
fi

# Passt das Datenbank-Passwort der .env nicht mehr zur Datenbank (.env neu angelegt, das Daten-Volume ist aber das
# alte — etwa nach einem Unraid-Neustart oder einer zweiten Installation), kommt die App nie an ihre Daten (502).
# Im Datenbank-Container geht der lokale Socket ohne Passwort: darueber das Passwort der .env setzen, Daten bleiben.
# Geprueft wird ueber die Netz-Adresse des Containers (wie die App) — 127.0.0.1 ist dort ohne Passwort erlaubt.
# Rueckgabe: 0 = passt, 2 = angeglichen (App neu gestartet), 1 = liess sich nicht angleichen
db_passwort_angleichen() {
  local i
  [ -n "$(docker compose ps -q db 2>/dev/null)" ] || return 0
  for i in $(seq 1 30); do docker compose exec -T db pg_isready -q >/dev/null 2>&1 && break; sleep 1; done
  docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$(hostname -i 2>/dev/null | cut -d" " -f1)" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1 && return 0
  printf '%s\n' "ALTER USER CURRENT_USER PASSWORD :'pw';" | docker compose exec -T db sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -v pw="$POSTGRES_PASSWORD"' >/dev/null 2>&1 || return 1
  docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$(hostname -i 2>/dev/null | cut -d" " -f1)" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1 || return 1
  docker compose restart app >/dev/null 2>&1 || true
  return 2
}

# 5. Starten
# Ordner fuer Importe (Seite „Import“ → Server-Ordner), lesbar fuer den App-Nutzer (uid 1000)
mkdir -p import && chmod 755 import
if [ -d .output ]; then docker compose up -d --build; else docker compose pull && docker compose up -d; fi
db_rc=0; db_passwort_angleichen || db_rc=$?
if [ "$db_rc" = 2 ]; then say "    Das Datenbank-Passwort passte nicht zur .env — angeglichen (Daten bleiben)." "    The database password did not match .env — fixed (data kept)."
elif [ "$db_rc" = 1 ]; then say "    FEHLER: Das Datenbank-Passwort passt nicht zur .env und liess sich nicht angleichen." "    ERROR: The database password does not match .env and could not be fixed."; fi

# 5b. Update-Dienst einrichten (Funktion steht oben)
updater_einrichten || say "    Update-Dienst nicht eingerichtet: $DIENST_GRUND" "    Update service not set up: $DIENST_GRUND"

# 6. Virtual Host fuer die Domain in deinem Webserver (nur im Port-Modus, nur mit Domain).
#    Als Funktion: laeuft auch nach der Einrichtung ueber den Kurzzeit-Link (Schritt 9) mit der dort gewaehlten Domain.
vhost_angelegt=""; fremd=""
vhost_einrichten() {
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ] && [ "$VHOST" = "ja" ]; then
  webserver=""
  if command -v nginx >/dev/null 2>&1; then webserver="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then webserver="apache2"
  elif command -v httpd >/dev/null 2>&1; then webserver="httpd"
  fi
  # Gibt es fuer die Domain schon einen fremden Eintrag (z. B. das alte Zipline)? Dann nichts anfassen — umstellen
  # ist ein bewusster Schritt (siehe Umzug unten), sonst stritten sich zwei Eintraege um die Domain.
  fremd=$(grep -RlsE "^[[:space:]]*(server_name|ServerName|ServerAlias)[[:space:]]+(.*[[:space:]])?${DOMAIN//./\\.}([[:space:];]|$)" /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null | grep -v 'reddrop' | head -1 || true)
  # Zeigt der Eintrag schon auf RedDrop (z. B. nach dem Umzug von Zipline)? Dann ist alles erledigt.
  if [ -n "$fremd" ] && grep -qE "(proxy_pass|ProxyPass[[:space:]]+/)[[:space:]]+http://(127\.0\.0\.1|localhost):${PORT}(/|;|[[:space:]]|$)" "$fremd"; then
    say "==> $DOMAIN zeigt schon auf RedDrop ($fremd)." "==> $DOMAIN already points to RedDrop ($fremd)."
    fremd=""; webserver=""; vhost_angelegt="vorhanden"; https_ok=1
  fi
  if [ -n "$fremd" ]; then
    say "==> Fuer $DOMAIN gibt es schon einen Eintrag: $fremd — den fasse ich nicht an." "==> There is already an entry for $DOMAIN: $fremd — I will not touch it."
    webserver=""
  fi
  if [ -n "$webserver" ] && ja "==> $(s "Virtual Host fuer $DOMAIN in $webserver anlegen (Backup vorhandener Dateien, Konfigtest, Neuladen)?" "Create a virtual host for $DOMAIN in $webserver (backup of existing files, config test, reload)?")" "j"; then
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
      if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      [ -n "$link" ] && tu ln -sf "$datei" "$link"
      if tu nginx -t; then tu systemctl reload nginx 2>/dev/null || tu nginx -s reload; vhost_angelegt="$webserver"
      else say "    FEHLER: nginx -t schlaegt fehl — Datei $datei bitte pruefen (Backup: $datei.bak-$stempel)." "    ERROR: nginx -t fails — please check $datei (backup: $datei.bak-$stempel)."; fi
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
      if [ "${RD_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      if [ "$webserver" = "apache2" ]; then
        tu a2enmod -q proxy proxy_http headers
        tu a2ensite -q reddrop.conf
        if tu apache2ctl configtest; then tu systemctl reload apache2; vhost_angelegt="$webserver"; else say "    FEHLER: Apache-Konfigtest schlaegt fehl — $datei bitte pruefen." "    ERROR: Apache config test fails — please check $datei."; fi
      else
        if tu httpd -t; then tu systemctl reload httpd; vhost_angelegt="$webserver"; else say "    FEHLER: httpd -t schlaegt fehl — $datei bitte pruefen." "    ERROR: httpd -t fails — please check $datei."; fi
      fi
    fi
  elif [ -z "$webserver" ] && [ -z "$fremd" ] && [ "$vhost_angelegt" != "vorhanden" ]; then
    say "==> Keinen nginx/Apache gefunden — die Vorlage fuer deinen Webserver steht unten." "==> No nginx/Apache found — the template for your web server is shown below."
  fi

  # 7. Zertifikat per certbot (HTTP-01 ueber den gerade angelegten Virtual Host)
  if [ -n "$vhost_angelegt" ] && [ "$vhost_angelegt" != "vorhanden" ]; then
    plugin="nginx"; [ "$vhost_angelegt" = "nginx" ] || plugin="apache"
    meine_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    domain_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$meine_ip" ] && [ "$domain_ip" != "$meine_ip" ]; then
      say "==> $DOMAIN zeigt auf '${domain_ip:-nichts}', dieser Server hat $meine_ip — Zertifikat spaeter holen:" "==> $DOMAIN points to '${domain_ip:-nothing}', this server has $meine_ip — get the certificate later:"
      echo "    certbot --$plugin -d $DOMAIN --redirect"
    elif ja "==> $(s "HTTPS-Zertifikat fuer $DOMAIN mit certbot holen (Let's Encrypt)?" "Get an HTTPS certificate for $DOMAIN with certbot (Let's Encrypt)?")" "j"; then
      if ! command -v certbot >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then tu apt-get install -y -qq certbot "python3-certbot-$plugin"
        elif command -v dnf >/dev/null 2>&1; then tu dnf install -y -q certbot "python3-certbot-$plugin"
        else say "    certbot fehlt und konnte nicht installiert werden — bitte von Hand: certbot --$plugin -d $DOMAIN --redirect" "    certbot is missing and could not be installed — please run by hand: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
      if command -v certbot >/dev/null 2>&1 || [ "${RD_DRY_RUN:-}" = "1" ]; then
        [ -n "$EMAIL" ] || EMAIL=$(frage "    $(s "E-Mail fuer Ablauf-Hinweise von Let's Encrypt (leer = keine)" "Email for Let's Encrypt expiry notices (empty = none)")" "")
        if [ -n "$EMAIL" ]; then mail_arg=(-m "$EMAIL"); else mail_arg=(--register-unsafely-without-email); fi
        if tu certbot "--$plugin" -d "$DOMAIN" --redirect -n --agree-tos "${mail_arg[@]}"; then https_ok=1
        else say "    certbot hat nicht geklappt (Ausgabe oben). Spaeter nochmal: certbot --$plugin -d $DOMAIN --redirect" "    certbot did not work (output above). Try again later: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
    fi
  fi
fi
}
vhost_einrichten

# 8. Auf die App warten und den Setup-Code zeigen
say "==> Warte auf den Start …" "==> Waiting for the start …"
for n in $(seq 1 60); do
  if docker compose logs app 2>/dev/null | grep -q 'Setup-Code\|bereit\|ready'; then break; fi
  for k in 0 1 2 3 4 5 6 7; do [ -t 1 ] && printf '\r  %s%s%s %s' "$R" "${SPIN[$(( (n * 8 + k) % ${#SPIN[@]} ))]}" "$N" "$(s "RedDrop startet" "RedDrop is starting") ($((n * 2)) s)"; sleep 0.25; done
done
[ -t 1 ] && printf '\r\033[K'
# IP fuer Links und Kurzzeit-Eintrag: die oeffentliche nur, wenn sie auf dem Server selbst liegt (VPS).
# Sonst steht der Server hinter einem Router (Heimnetz) — dann die IP, ueber die er ins Netz geht.
ip_pub=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
ip_lan=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)
[ -n "$ip_lan" ] || ip_lan=$(hostname -I 2>/dev/null | awk '{print $1}')
hinter_router=""
if [ -n "$ip_pub" ] && ip -4 addr 2>/dev/null | grep -qF "inet ${ip_pub}/"; then ip="$ip_pub"
elif [ -n "$ip_lan" ]; then ip="$ip_lan"; [ -n "$ip_pub" ] && [ "$ip_pub" != "$ip_lan" ] && hinter_router="ja"
else ip="$ip_pub"; fi
code=$(docker compose logs app 2>/dev/null | grep -o 'Setup-Code: *[A-F0-9]\{4\}-[A-F0-9]\{4\}' | tail -1 | sed 's/.*: *//' || true)
echo ""
if [ -n "$code" ]; then
  kasten "$R" "$(s "Setup-Code" "Setup code"):  $code" "$(s "Brauchst du gleich im Browser." "You need it in the browser in a moment.")"
else
  docker compose logs app 2>/dev/null | grep -A1 -B2 'Setup-Code' | tail -5 || true
fi
echo ""

# 9. Kurzzeit-Link: Port-Modus ohne Domain → die Einrichtung voruebergehend ueber http://<Server-IP> erlauben.
#    Ein eigener Eintrag NUR fuer die IP (andere Domains im Webserver bleiben unberuehrt), geschuetzt durch
#    den Setup-Code; nach der Einrichtung (oder bei Abbruch) wird er wieder entfernt. Wurde im Assistenten
#    eine Domain eingetragen, bekommt sie danach ihren Virtual Host und das Zertifikat.
setup_wert() { docker compose exec -T db psql -U reddrop -d reddrop -tAc "SELECT coalesce(value->>'$2', '') FROM settings WHERE key = '$1'" 2>/dev/null | tr -d '[:space:]'; }
setup_fertig() { [ "$(setup_wert setup done)" = "true" ]; }
kurz_datei=""; kurz_link=""; kurz_web=""; direkt_url=""
direkt_freigeben() { # App direkt im Netz erreichbar: Port auf allen Schnittstellen statt nur 127.0.0.1
  if grep -q '^RD_BIND=' .env; then sed -i 's|^RD_BIND=.*|RD_BIND=0.0.0.0|' .env; else echo "RD_BIND=0.0.0.0" >> .env; fi
  tu docker compose up -d app >/dev/null 2>&1 || true
  direkt_url="http://${ip}:${PORT}"
  echo ""
  say "==> RedDrop ist jetzt direkt erreichbar:  ${direkt_url}" "==> RedDrop is now directly reachable:  ${direkt_url}"
  say "    Gib dort den Setup-Code von oben ein und waehle „Nur ueber die IP“. Eine Domain geht spaeter:  sudo bash install.sh --domain drop.deinefirma.de" "    Enter the setup code from above there and choose “IP address only”. A domain works later:  sudo bash install.sh --domain drop.example.com"
  say "    Firewall: Port ${PORT}/tcp muss erreichbar sein." "    Firewall: port ${PORT}/tcp must be reachable."
  [ -n "$hinter_router" ] && say "    Von ausserhalb deines Netzes nur mit Portweiterleitung im Router (${ip_pub}:${PORT} → ${ip}:${PORT}) — oder per Cloudflare Tunnel im Panel." "    From outside your network only with port forwarding in your router (${ip_pub}:${PORT} → ${ip}:${PORT}) — or via Cloudflare Tunnel in the panel."
  return 0
}
kurz_weg() {
  [ -n "$kurz_datei" ] || return 0
  if [ "$kurz_web" = "apache2" ]; then a2dissite -q reddrop-setup.conf >/dev/null 2>&1 || true; fi
  rm -f "$kurz_datei" ${kurz_link:+"$kurz_link"}
  case "$kurz_web" in nginx) nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || nginx -s reload; } ;; apache2) systemctl reload apache2 ;; httpd) systemctl reload httpd ;; esac
  say "==> Kurzzeit-Eintrag fuer http://${ip} wieder entfernt." "==> Temporary entry for http://${ip} removed again."
  kurz_datei=""
}
# 10. Umzug: Unter der Domain laeuft schon ein anderer Dienst (eigener Eintrag im Webserver, z. B. Zipline).
#     Zipline wird komplett uebernommen — Konten mit Passwoertern, Ordner, Tags, Linknamen, alte /u/-Links,
#     auch passwortgeschuetzte Dateien —, solange es noch laeuft. Erst danach zeigt die Domain auf RedDrop
#     (der alte Eintrag wird vorher gesichert; ein Zurueck ist jederzeit moeglich).
umzug_schl=""; umzug_ordner=""; umzug_netz=""; umzug_app=""
umzug_api() { # umzug_api '<json>' → Antwort der internen Installer-Schnittstelle von RedDrop
  docker compose exec -T app wget -qO- --header "x-rd-installer: $umzug_schl" --header "content-type: application/json" --post-data "$1" http://127.0.0.1:3000/api/internal/installer 2>/dev/null || true
}
json_wert() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" | head -1; }
umzug_aufraeumen() {
  [ -n "$umzug_schl" ] && docker compose exec -T app rm -f /data/.installer-schluessel >/dev/null 2>&1 || true
  # Nur Hardlinks und der Export (mit Geheimnissen der alten Instanz) — Ziplines eigene Dateien bleiben unberuehrt
  [ -n "$umzug_ordner" ] && rm -rf "./import/$umzug_ordner"
  [ -n "$umzug_netz" ] && docker network disconnect "$umzug_netz" "$umzug_app" >/dev/null 2>&1 || true
  umzug_ordner=""; umzug_netz=""
}
umzug_lauf() { # umzug_lauf <json-fuer-aktion-zipline> → importiert und wartet, bis alles da ist
  local antwort id st
  antwort=$(umzug_api "$1")
  id=$(echo "$antwort" | json_wert id)
  [ -n "$id" ] || { say "    FEHLER: Import liess sich nicht anlegen: $antwort" "    ERROR: could not create the import: $antwort"; return 1; }
  echo -n "    $(s "Lese Zipline" "Reading Zipline") "
  for _ in $(seq 1 360); do st=$(umzug_api "{\"aktion\":\"stand\",\"id\":$id}" | json_wert status); [ "$st" = "analyse" ] || break; echo -n "."; sleep 5; done
  echo ""
  if [ "$st" != "bereit" ]; then say "    FEHLER: $(umzug_api "{\"aktion\":\"stand\",\"id\":$id}" | json_wert meldung)" "    ERROR: $(umzug_api "{\"aktion\":\"stand\",\"id\":$id}" | json_wert meldung)"; return 1; fi
  antwort=$(umzug_api "{\"aktion\":\"stand\",\"id\":$id}")
  say "    Gefunden: $(echo "$antwort" | json_wert gesamt) Dateien, $(echo "$antwort" | json_wert nutzer) Konten — wird uebertragen …" "    Found: $(echo "$antwort" | json_wert gesamt) files, $(echo "$antwort" | json_wert nutzer) accounts — transferring …"
  umzug_api "{\"aktion\":\"starten\",\"id\":$id}" >/dev/null
  for _ in $(seq 1 4320); do
    antwort=$(umzug_api "{\"aktion\":\"stand\",\"id\":$id}"); st=$(echo "$antwort" | json_wert status)
    printf "\r    %s / %s $(s "Dateien (schon da %s, Fehler %s)" "files (already there %s, errors %s)")   " "$(echo "$antwort" | json_wert erledigt)" "$(echo "$antwort" | json_wert gesamt)" "$(echo "$antwort" | json_wert uebersprungen)" "$(echo "$antwort" | json_wert fehler)"
    case "$st" in laeuft|pausiert) sleep 3 ;; *) break ;; esac
  done
  echo ""
  [ "$st" = "fertig" ] || { say "    Import endete mit Status: $st" "    Import ended with status: $st"; return 1; }
}
# Einen Durchgang vorbereiten und ausfuehren: Server-Export + Hardlinks der Dateien (kein Extra-Platz) —
# oder, wenn Zipline seine Dateien nicht lokal hat (S3), direkt ueber Ziplines eigenes Docker-Netz.
zipline_durchgang() { # zipline_durchgang <ziel-url> <container> <token>
  local quelle stempel exp
  stempel=$(date +%Y%m%d-%H%M%S)
  quelle=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/zipline/uploads"}}{{.Source}}{{end}}{{end}}' "$2" 2>/dev/null || true)
  if [ -n "$quelle" ] && [ -d "$quelle" ] && [ -n "$(ls -A "$quelle" 2>/dev/null)" ]; then
    umzug_ordner="zipline-umzug-$stempel"
    mkdir -p "./import/$umzug_ordner"
    exp="./import/$umzug_ordner/zipline4_export_$stempel.json"
    if ! curl -fsS --max-time 300 -H "authorization: $3" "$1/api/server/export?nometrics=true" -o "$exp" || ! grep -q '"export":"4"' "$exp"; then
      say "    FEHLER: Zipline gibt keinen Server-Export heraus — ist das der Token eines Super-Admins?" "    ERROR: Zipline does not hand out a server export — is this a super admin's token?"; umzug_aufraeumen; return 1
    fi
    chown 1000:1000 "$exp"; chmod 600 "$exp"
    if [ "$(stat -c %d "$quelle")" = "$(stat -c %d ./import)" ]; then cp -al "$quelle/." "./import/$umzug_ordner/"
    else say "    Ziplines Dateien liegen auf einem anderen Laufwerk — kopiere sie (braucht einmal so viel Platz) …" "    Zipline's files are on another drive — copying them (needs the same space once) …"; cp -a "$quelle/." "./import/$umzug_ordner/"; fi
    umzug_lauf "{\"aktion\":\"zipline\",\"ordner\":\"$umzug_ordner\"}" || { umzug_aufraeumen; return 1; }
  else
    local zport
    umzug_app=$(docker compose ps -q app)
    umzug_netz=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$2" | awk '{print $1}')
    zport=$(docker inspect -f '{{range $p, $v := .Config.ExposedPorts}}{{$p}} {{end}}' "$2" | grep -oE '^[0-9]+' | head -1)
    docker network connect "$umzug_netz" "$umzug_app" 2>/dev/null || true
    umzug_lauf "{\"aktion\":\"zipline\",\"url\":\"http://$2:${zport:-3000}\",\"token\":\"$3\"}" || { umzug_aufraeumen; return 1; }
  fi
  umzug_aufraeumen
}
umzug_anbieten() {
  local ziel port zc zbild token stempel sicher datei projekt ok=""
  datei=$(readlink -f "$fremd")
  ziel=$(grep -oE '(proxy_pass|ProxyPass[[:space:]]+/)[[:space:]]+https?://[^;[:space:]]+' "$datei" | head -1 | awk '{print $NF}' | sed 's#/$##')
  port=$(echo "$ziel" | sed -nE 's#^https?://[^/]+:([0-9]+).*#\1#p')
  zc=""; zbild=""
  if [ -n "$port" ]; then
    zc=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E ":${port}->" | awk '{print $1}' | head -1 || true)
    [ -n "$zc" ] && zbild=$(docker inspect -f '{{.Config.Image}}' "$zc" 2>/dev/null || true)
  fi
  echo ""
  say "==> $DOMAIN zeigt bisher auf ${ziel:-einen anderen Dienst}${zc:+ (Container $zc, $zbild)}." "==> $DOMAIN currently points to ${ziel:-another service}${zc:+ (container $zc, $zbild)}."
  if echo "$zbild" | grep -qi zipline; then
    ja "    $(s "Zipline komplett nach RedDrop uebernehmen (Konten mit Passwoertern, Ordner, Tags, Linknamen, alte /u/-Links) und danach $DOMAIN umstellen?" "Move Zipline to RedDrop completely (accounts with passwords, folders, tags, link names, old /u/ links) and then switch $DOMAIN?")" "j" || return 1
    say "    Dafuer brauche ich deinen Zipline-Token: in Zipline oben rechts → Einstellungen (Settings) → Token kopieren." "    For this I need your Zipline token: in Zipline top right → Settings → copy token."
    say "    Es muss ein Super-Admin sein (sonst kommen nicht alle Konten mit). Der Token wird nicht angezeigt und nirgends gespeichert." "    It must be a super admin (otherwise not all accounts come along). The token is not shown and not stored anywhere."
    token=""
    if [ -t 0 ]; then read -r -s -p "    Zipline-Token: " token </dev/tty || true; echo ""; fi
    [[ "$token" =~ ^[A-Za-z0-9._=+/-]{10,2000}$ ]] || { say "    Kein gueltiger Token — Umzug uebersprungen. Spaeter einfach nochmal: sudo bash install.sh" "    No valid token — move skipped. Simply run again later: sudo bash install.sh"; return 1; }
    umzug_schl=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    docker compose exec -T app sh -c "umask 077; printf %s '$umzug_schl' > /data/.installer-schluessel"
    trap 'umzug_aufraeumen' EXIT
    trap 'echo; umzug_aufraeumen; exit 130' INT TERM
    say "==> Uebertrage Zipline (laeuft dabei normal weiter) …" "==> Transferring Zipline (it keeps running normally) …"
    if ! zipline_durchgang "$ziel" "$zc" "$token"; then say "    $DOMAIN bleibt bei Zipline. Erneut versuchen: sudo bash install.sh" "    $DOMAIN stays with Zipline. Try again: sudo bash install.sh"; return 1; fi
  else
    ja "    $(s "$DOMAIN auf RedDrop umstellen? (Der bisherige Dienst ist unter dieser Domain dann nicht mehr erreichbar.)" "Switch $DOMAIN to RedDrop? (The previous service is then no longer reachable under this domain.)")" "n" || return 1
  fi
  # Domain umstellen: im vorhandenen Eintrag nur das Ziel tauschen — Zertifikat und alles andere bleibt
  stempel=$(date +%Y%m%d-%H%M%S); mkdir -p /root/reddrop-backup
  sicher="/root/reddrop-backup/$(basename "$datei").bak-$stempel"
  cp -a "$datei" "$sicher"
  sed -i -E "s#(proxy_pass[[:space:]]+)https?://[^;[:space:]]+#\1http://127.0.0.1:${PORT}#; s#(ProxyPass(Reverse)?[[:space:]]+/[[:space:]]+)https?://[^[:space:]]+#\1http://127.0.0.1:${PORT}/#" "$datei"
  if grep -q 'proxy_pass' "$datei" && ! grep -q 'proxy_set_header[[:space:]]\+Host' "$datei"; then
    sed -i -E "s#^([[:space:]]*)(proxy_pass[[:space:]]+http://127\.0\.0\.1:${PORT};)#\1\2\n\1proxy_set_header Host \$host;\n\1proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n\1proxy_set_header X-Forwarded-Proto \$scheme;#" "$datei"
  fi
  if grep -q 'proxy_pass' "$datei" && ! grep -q 'client_max_body_size' "$datei"; then
    sed -i -E "s#^([[:space:]]*)(proxy_pass[[:space:]]+http://127\.0\.0\.1:${PORT};)#\1\2\n\1client_max_body_size 0;#" "$datei"
  fi
  if grep -q 'proxy_pass' "$datei"; then nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || nginx -s reload; ok=1; }
  elif command -v apache2ctl >/dev/null 2>&1; then apache2ctl configtest >/dev/null 2>&1 && { systemctl reload apache2; ok=1; }
  elif command -v httpd >/dev/null 2>&1; then httpd -t >/dev/null 2>&1 && { systemctl reload httpd; ok=1; }
  fi
  if [ -z "$ok" ]; then
    cp -a "$sicher" "$datei"
    say "    FEHLER: Konfigtest nach dem Umstellen fehlgeschlagen — alter Stand wiederhergestellt ($sicher)." "    ERROR: config test failed after switching — previous state restored ($sicher)."; return 1
  fi
  say "==> $DOMAIN zeigt jetzt auf RedDrop (alter Eintrag gesichert: $sicher)." "==> $DOMAIN now points to RedDrop (old entry saved: $sicher)."
  if [ -n "${token:-}" ]; then
    say "==> Hole nach, was waehrend der Uebertragung noch in Zipline hochgeladen wurde …" "==> Catching up on anything uploaded to Zipline during the transfer …"
    zipline_durchgang "$ziel" "$zc" "$token" || true
    docker compose exec -T app rm -f /data/.installer-schluessel >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    token=""
    projekt=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$zc" 2>/dev/null || true)
    if ja "    $(s "Zipline jetzt stoppen? (Daten und Container bleiben fuer ein Zurueck erhalten)" "Stop Zipline now? (data and containers are kept so you can go back)")" "j"; then
      if [ -n "$projekt" ]; then docker ps -q --filter "label=com.docker.compose.project=$projekt" | xargs -r docker stop >/dev/null; else docker stop "$zc" >/dev/null; fi
      say "    Zipline gestoppt." "    Zipline stopped."
    fi
    echo ""
    say "    Zurueck zu Zipline, falls noetig:" "    Back to Zipline, if needed:"
    echo "      cp $sicher $datei && systemctl reload nginx"
    echo "      docker start \$(docker ps -aq --filter label=com.docker.compose.project=${projekt:-zipline})"
  fi
  echo ""
  say "==> Fertig. RedDrop laeuft unter  https://${DOMAIN}" "==> Done. RedDrop runs at  https://${DOMAIN}"
  say "    Die uebernommenen Zipline-Konten melden sich mit ihren bisherigen Passwoertern an." "    The moved Zipline accounts sign in with their previous passwords."
  return 0
}

# Schon eingerichtet und die Domain gehoert noch einem anderen Dienst? Dann gleich den Umzug anbieten.
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ] && [ -n "$fremd" ] && [ "${RD_DRY_RUN:-}" != "1" ] && setup_fertig; then
  umzug_anbieten && exit 0
fi

# Kurzzeit-Link auch dann, wenn die Domain noch auf den alten Dienst zeigt (Einrichtung erst, dann Umzug)
if [ "$MODUS" = "port" ] && [ -z "$vhost_angelegt" ] && { [ -z "$DOMAIN" ] || [ -n "$fremd" ]; } && [ "$VHOST" = "ja" ] && [[ "${ip:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "${RD_DRY_RUN:-}" != "1" ] && ! setup_fertig; then
  if command -v nginx >/dev/null 2>&1; then kurz_web="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then kurz_web="apache2"
  elif command -v httpd >/dev/null 2>&1; then kurz_web="httpd"
  fi
  if [ -n "$kurz_web" ] && ja "==> $(s "Fuer die Einrichtung voruebergehend unter http://${ip} erreichbar machen? (eigener Eintrag nur fuer die IP, wird danach entfernt — bei Nein direkt unter http://${ip}:${PORT})" "Make it reachable at http://${ip} temporarily for the setup? (own entry for the IP only, removed afterwards — if no, directly at http://${ip}:${PORT})")" "j"; then
    if [ "$kurz_web" = "nginx" ]; then
      if [ -d /etc/nginx/sites-enabled ]; then kurz_datei=/etc/nginx/sites-available/reddrop-setup.conf; kurz_link=/etc/nginx/sites-enabled/reddrop-setup.conf
      else kurz_datei=/etc/nginx/conf.d/reddrop-setup.conf; fi
      printf '%s\n' "# RedDrop — nur fuer die Einrichtung, entfernt install.sh wieder" "server {" "    listen 80;" "    server_name ${ip}${hinter_router:+ $ip_pub};" "    client_max_body_size 0;" \
        "    location / {" "        proxy_pass http://127.0.0.1:${PORT};" "        proxy_set_header Host \$host;" "        proxy_set_header X-Real-IP \$remote_addr;" \
        "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" "        proxy_set_header X-Forwarded-Proto \$scheme;" "    }" "}" > "$kurz_datei"
      [ -n "$kurz_link" ] && ln -sf "$kurz_datei" "$kurz_link"
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload; else say "    nginx -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    nginx -t fails — temporary entry removed again."; kurz_weg; fi
    else
      if [ "$kurz_web" = "apache2" ]; then kurz_datei=/etc/apache2/sites-available/reddrop-setup.conf; else kurz_datei=/etc/httpd/conf.d/reddrop-setup.conf; fi
      printf '%s\n' "# RedDrop — nur fuer die Einrichtung, entfernt install.sh wieder" "<VirtualHost *:80>" "    ServerName ${ip}" ${hinter_router:+"    ServerAlias ${ip_pub}"} "    ProxyPreserveHost On" \
        "    ProxyPass / http://127.0.0.1:${PORT}/" "    ProxyPassReverse / http://127.0.0.1:${PORT}/" "</VirtualHost>" > "$kurz_datei"
      if [ "$kurz_web" = "apache2" ]; then a2enmod -q proxy proxy_http >/dev/null; a2ensite -q reddrop-setup.conf >/dev/null; apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || { say "    Apache-Konfigtest schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    Apache config test fails — temporary entry removed again."; kurz_weg; }
      else httpd -t >/dev/null 2>&1 && systemctl reload httpd || { say "    httpd -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    httpd -t fails — temporary entry removed again."; kurz_weg; }; fi
    fi
    if [ -n "$kurz_datei" ]; then
      trap 'echo; kurz_weg; exit 130' INT TERM
      trap 'kurz_weg' EXIT
      echo ""
      say "==> Oeffne jetzt im Browser:  http://${ip}   und gib den Setup-Code von oben ein." "==> Now open in your browser:  http://${ip}   and enter the setup code from above."
      say "    Waehle im Assistenten „Hinter eigenem Webserver“ und trage deine Domain ein — der Installer" "    In the wizard choose “Behind your web server” and enter your domain — the installer"
      say "    legt danach den Virtual Host und das Zertifikat dafuer an. (Strg+C bricht ab.)" "    then creates the virtual host and the certificate for it. (Ctrl+C cancels.)"
      [ -n "$fremd" ] && say "    Hinweis: $DOMAIN zeigt noch auf den alten Dienst — nach der Einrichtung geht es hier im Terminal mit dem Umzug weiter." "    Note: $DOMAIN still points to the old service — after the setup the move continues here in the terminal."
      echo -n "    $(s "Warte auf die Einrichtung" "Waiting for the setup") "
      for _ in $(seq 1 720); do setup_fertig && break; echo -n "."; sleep 10; done
      echo ""
      kurz_weg
      trap - INT TERM EXIT
      if setup_fertig; then
        neu=$(setup_wert net domain | tr 'A-Z' 'a-z' || true)
        if [[ "$neu" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
          DOMAIN="$neu"
          if grep -q '^RD_PROXY_DOMAIN=' .env; then sed -i "s|^RD_PROXY_DOMAIN=.*|RD_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RD_PROXY_DOMAIN=$DOMAIN" >> .env; fi
          say "==> Einrichtung abgeschlossen. Domain aus dem Assistenten: $DOMAIN" "==> Setup complete. Domain from the wizard: $DOMAIN"
          vhost_einrichten
          if [ -n "$fremd" ]; then umzug_anbieten || true; exit 0; fi
          if [ -n "$vhost_angelegt" ]; then
            if [ -n "${https_ok:-}" ]; then say "==> Fertig. RedDrop laeuft unter  https://${DOMAIN}" "==> Done. RedDrop runs at  https://${DOMAIN}"; else say "==> Fertig. RedDrop laeuft unter  http://${DOMAIN}  (HTTPS: certbot --nginx -d ${DOMAIN} --redirect)" "==> Done. RedDrop runs at  http://${DOMAIN}  (HTTPS: certbot --nginx -d ${DOMAIN} --redirect)"; fi
            exit 0
          fi
        else
          say "==> Einrichtung abgeschlossen, aber ohne Domain. Spaeter:  sudo bash install.sh --domain drop.deinefirma.de" "==> Setup complete, but without a domain. Later:  sudo bash install.sh --domain drop.example.com"
          exit 0
        fi
      else
        say "==> Zeit abgelaufen. Einfach nochmal:  sudo bash install.sh" "==> Time is up. Simply run again:  sudo bash install.sh"
        exit 0
      fi
    fi
  else
    direkt_freigeben   # „Nein“ oder kein Webserver: einfach die IP mit dem gewaehlten Port
  fi
fi
if [ -n "$direkt_url" ]; then
  say "==> Fertig. Oeffne im Browser:  ${direkt_url}" "==> Done. Open in your browser:  ${direkt_url}"
elif [ "$MODUS" = "port" ]; then
  if [ -n "$vhost_angelegt" ]; then
    if [ -n "${https_ok:-}" ]; then say "==> Fertig. Oeffne im Browser:  https://${DOMAIN}" "==> Done. Open in your browser:  https://${DOMAIN}"; else say "==> Fertig. Oeffne im Browser:  http://${DOMAIN}" "==> Done. Open in your browser:  http://${DOMAIN}"; fi
  else
    say "==> Fertig. Die App hoert auf 127.0.0.1:${PORT}. Trage in deinem Webserver einen Virtual Host ein:" "==> Done. The app listens on 127.0.0.1:${PORT}. Add a virtual host to your web server:"
    echo ""
    echo "    nginx:                                                 Apache:"
    echo "    server {                                               <VirtualHost *:80>"
    echo "        listen 80;                                             ServerName ${DOMAIN:-drop.example.com}"
    echo "        server_name ${DOMAIN:-drop.example.com};          ProxyPreserveHost On"
    echo "        location / {                                           ProxyPass / http://127.0.0.1:${PORT}/"
    echo "            proxy_pass http://127.0.0.1:${PORT};               ProxyPassReverse / http://127.0.0.1:${PORT}/"
    echo "            proxy_set_header Host \$host;                       RequestHeader set X-Forwarded-Proto \"expr=%{REQUEST_SCHEME}\""
    echo "            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;   </VirtualHost>"
    echo "            proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        }"
    echo "    }"
    echo ""
    say "    HTTPS danach z. B. mit:  certbot --nginx -d ${DOMAIN:-drop.example.com} --redirect" "    HTTPS afterwards e.g. with:  certbot --nginx -d ${DOMAIN:-drop.example.com} --redirect"
    say "    Zum Ausprobieren ohne Domain:  ssh -L ${PORT}:127.0.0.1:${PORT} root@${ip}  und dann  http://127.0.0.1:${PORT}" "    To try it without a domain:  ssh -L ${PORT}:127.0.0.1:${PORT} root@${ip}  and then  http://127.0.0.1:${PORT}"
  fi
  say "    Im Assistenten ist „Hinter eigenem Webserver“ mit deiner Domain schon vorgewaehlt." "    In the wizard, “Behind your web server” with your domain is already preselected."
else
  say "==> Fertig. Oeffne im Browser:  http://${ip}" "==> Done. Open in your browser:  http://${ip}"
  say "    Firewall: Port 80 und 443 muessen von aussen erreichbar sein." "    Firewall: port 80 and 443 must be reachable from outside."
fi
say "    Den Setup-Code siehst du oben (oder: docker compose logs app | grep Setup-Code)." "    You can see the setup code above (or: docker compose logs app | grep Setup-Code)."
# Abschluss: Adresse noch einmal gross
ziel_url=""
if [ -n "$direkt_url" ]; then ziel_url="$direkt_url"
elif [ "$MODUS" = "port" ] && [ -n "${vhost_angelegt:-}" ] && [ -n "${DOMAIN:-}" ]; then ziel_url="$([ -n "${https_ok:-}" ] && echo https || echo http)://${DOMAIN}"
elif [ "$MODUS" != "port" ]; then ziel_url="http://${ip}"; fi
if [ -n "$ziel_url" ]; then echo ""; kasten "$G" "RedDrop  ${Z_PUNKT}  $ziel_url"; fi
echo ""
