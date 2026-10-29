#!/usr/bin/env bash
# RedDrop — nur aktualisieren: nichts neu einrichten, keine Fragen. .env, Daten, Domain und Einstellungen bleiben.
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/update.sh | sudo bash
# Holt die neuesten Dateien (Compose, Caddyfile, install.sh …; alte Fassungen nach .sicherung/), startet mit dem
# neuen Image und bringt den Update-Dienst auf den neuesten Stand. Der Knopf „Jetzt aktualisieren“ im Panel ruft
# dieses Skript danach selbst auf — einmal von Hand reicht, alles Weitere geht per Knopf.
# Schalter: --dir /pfad   Installationsordner (sonst RD_DIR, der Ordner aus dem Update-Dienst oder /opt/reddrop)
#           --status <datei>  nur fuer den Update-Dienst: Fortschritt fuer das Panel
set -uo pipefail
# Alles in einem Block: bash liest so das ganze Skript ein, bevor es loslaeuft. Bei „curl … | bash“ wuerde sonst
# jeder Befehl, der von der Eingabe liest (z. B. docker compose exec), den Rest des Skripts aus der Leitung schlucken.
{
exec </dev/null
# RD_QUELLE nur fuer Tests (eigener Dateiserver statt GitHub)
QUELLE="${RD_QUELLE:-https://raw.githubusercontent.com/theredstonee/reddrop-docker/main}"
DATEIEN="docker-compose.yml compose.caddy.yml compose.port.yml compose.node.yml Caddyfile install.sh update.sh .env.example README.md version.json"
DIR="${RD_DIR:-}"; STATUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--status)
      [ $# -ge 2 ] || { echo "Missing value / Wert fehlt: $1"; exit 1; }
      if [ "$1" = "--dir" ]; then DIR="$2"; else STATUS="$2"; fi; shift 2 ;;
    *) echo "Unknown option / Unbekannter Schalter: $1"; exit 1 ;;
  esac
done
# Vom Update-Dienst als Kopie in /tmp gestartet: die Kopie wieder wegraeumen (bash hat sie schon offen)
case "$0" in /tmp/tmp.*) rm -f "$0" ;; esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  R=$'\033[38;2;232;48;48m'; G=$'\033[38;2;74;222;128m'; Y=$'\033[38;2;251;191;36m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else R=""; G=""; Y=""; D=""; B=""; N=""; fi
if locale charmap 2>/dev/null | grep -qi 'utf-\?8' || echo "${LANG:-}${LC_ALL:-}" | grep -qi 'utf-\?8'; then
  Z_SCHRITT="▸"; Z_OK="✔"; Z_FEHLER="✖"; Z_V="│"
else Z_SCHRITT=">"; Z_OK="OK"; Z_FEHLER="X"; Z_V="|"; fi
SPR="de"
s() { if [ "$SPR" = "de" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
kurz() { printf '%s' "$1" | tail -3 | tr '\n"\\' '   ' | cut -c1-400; }
status() { # status laeuft|fertig|fehler "Meldung" — nur mit --status (Panel)
  [ -n "$STATUS" ] || return 0
  printf '{"status":"%s","zeit":"%s","meldung":"%s"}\n' "$1" "$(date -Is)" "$(kurz "$2")" > "$STATUS" && chmod 644 "$STATUS"
}
# Vom Update-Dienst gestartet (--status): Live-Protokoll fuers Panel neben der Status-Datei (.update.log, je Lauf neu)
LOG=""
if [ -n "$STATUS" ]; then LOG="$(dirname "$STATUS")/.update.log"; { : > "$LOG" && chmod 644 "$LOG"; } 2>/dev/null || LOG=""; fi
protokoll() { [ -n "$LOG" ] && printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"; return 0; }
# Im Terminal: Schritte mit Nummer und ein Spinner mit laufenden Sekunden, damit man sieht, dass etwas passiert.
# Die Docker-Ausgabe landet in einer Datei (letzte Zeile klein neben dem Spinner); bei einem Fehler erscheinen die
# letzten 30 Zeilen rot. Ohne Terminal (Dienst, Umleitung in eine Datei) bleibt es bei einfachen Zeilen.
ANSICHT=0; [ -t 1 ] && [ -z "$STATUS" ] && ANSICHT=1
SCHRITTE=5; SCHRITT_NR=0
AUSG=$(mktemp 2>/dev/null || echo "/tmp/upd-ausgabe.$$"); : > "$AUSG"
SPIN_PID=""; SPIN_TXT="$AUSG.txt"; SPIN_T0=0
if [ "$Z_V" = "│" ]; then SPIN_Z=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); else SPIN_Z=('|' '/' '-' '\'); fi
BREITE=$(tput cols 2>/dev/null || echo 80); case "$BREITE" in ''|*[!0-9]*) BREITE=80 ;; esac
trap 'warte_ende; rm -f "$AUSG" "$AUSG.app" "$SPIN_TXT"' EXIT
# warte "Text" "text": Spinner an — endet mit dem naechsten warte/info/schritt (gruener Haken) oder abbruch (rotes X)
warte() {
  protokoll "    $(s "$1" "$2") …"
  if [ "$ANSICHT" != 1 ]; then echo "  ${D}${Z_V}${N} $(s "$1" "$2") …"; return 0; fi
  warte_ende ok
  printf '%s' "$(s "$1" "$2")" > "$SPIN_TXT"; SPIN_T0=$SECONDS
  (
    trap 'exit 0' TERM
    i=0; zeile=""
    while :; do
      txt=""; IFS= read -r txt < "$SPIN_TXT" 2>/dev/null || true
      [ "${#txt}" -gt $((BREITE - 16)) ] && txt="${txt:0:$((BREITE - 17))}…"
      if [ $((i % 5)) -eq 0 ]; then
        platz=$((BREITE - ${#txt} - 18))
        zeile=""; [ "$platz" -gt 8 ] && zeile=$(tail -n 1 "$AUSG" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[[:space:]]*//' | cut -c1-"$platz")
      fi
      printf '\r\033[K  %s%s%s %s %s%s s%s%s' "$R" "${SPIN_Z[i % ${#SPIN_Z[@]}]}" "$N" "$txt" "$D" "$((SECONDS - SPIN_T0))" "${zeile:+   $zeile}" "$N"
      i=$((i + 1)); sleep 0.1 2>/dev/null || sleep 1
    done
  ) &
  SPIN_PID=$!
}
# Text am laufenden Spinner aendern (z. B. Zustand im Selbsttest)
warte_text() { [ "$ANSICHT" = 1 ] && [ -n "$SPIN_PID" ] && printf '%s' "$(s "$1" "$2")" > "$SPIN_TXT"; return 0; }
# warte_ende [ok|fehler]: Spinner aus, Zeile mit Haken bzw. X und Dauer stehen lassen (ohne Angabe: nur wegwischen)
warte_ende() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=""
  local txt=""; IFS= read -r txt < "$SPIN_TXT" 2>/dev/null || true
  printf '\r\033[K'
  case "${1:-}" in
    ok) echo "  ${G}${Z_OK}${N} $txt ${D}$((SECONDS - SPIN_T0)) s${N}" ;;
    fehler) echo "  ${R}${Z_FEHLER}${N} $txt ${D}$((SECONDS - SPIN_T0)) s${N}" ;;
  esac
  return 0
}
schritt() {
  warte_ende ok; : > "$AUSG"; SCHRITT_NR=$((SCHRITT_NR + 1))
  echo "${R}${B}${Z_SCHRITT}${N} ${D}[${SCHRITT_NR}/${SCHRITTE}]${N} ${B}$(s "$1" "$2")${N}"; protokoll "==> [${SCHRITT_NR}/${SCHRITTE}] $(s "$1" "$2")"
}
info() { warte_ende ok; echo "  ${D}${Z_V}${N} $(s "$1" "$2")"; protokoll "    $(s "$1" "$2")"; }
# Fehler: rotes X am Spinner, die letzten 30 Zeilen der Ausgabe dieses Schritts, dann die Meldung (auch fuers Panel)
abbruch() {
  warte_ende fehler
  if [ "$ANSICHT" = 1 ] && [ -s "$AUSG" ]; then
    echo "  ${D}$(s "Letzte Zeilen der Ausgabe:" "Last lines of the output:")${N}" >&2
    tail -n 30 "$AUSG" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | while IFS= read -r z; do echo "  ${R}${Z_V}${N} ${R}${z}${N}" >&2; done
  fi
  echo "${R}${B}${Z_FEHLER} $(s "$1" "$2")${N}" >&2; protokoll "Fehler: $(s "$1" "$2")"; status fehler "$(s "$1" "$2")"; exit 1
}
# Befehl ausfuehren: Ausgabe in $AUSG (und ins Live-Protokoll fuers Panel), Ende davon in $AUSGABE fuer Meldungen
AUSGABE=""
lauf() {
  local rc=0
  : > "$AUSG"
  if [ -n "$STATUS" ] && [ -n "$LOG" ]; then "$@" 2>&1 | tee -a "$LOG" > "$AUSG"; rc=${PIPESTATUS[0]}
  elif [ -n "$STATUS" ] || [ "$ANSICHT" = 1 ]; then "$@" > "$AUSG" 2>&1; rc=$?
  else "$@" 2>&1 | tee "$AUSG"; rc=${PIPESTATUS[0]}; fi
  AUSGABE=$(tail -c 4000 "$AUSG"); return "$rc"
}

[ "$(id -u)" -eq 0 ] || abbruch "Bitte mit sudo starten: curl -fsSL $QUELLE/update.sh | sudo bash" "Please run with sudo: curl -fsSL $QUELLE/update.sh | sudo bash"

# Installationsordner finden: --dir → RD_DIR → Ordner aus dem Update-Dienst → /opt/reddrop → aktueller Ordner
for d in /usr/local/bin/reddrop-update /boot/config/plugins/reddrop/reddrop-update; do
  [ -z "$DIR" ] && [ -f "$d" ] && DIR=$(sed -n 's/^DIR="\([^"]*\)".*/\1/p' "$d" | head -1)
done
for k in "$DIR" /opt/reddrop "$PWD"; do
  if [ -n "$k" ] && [ -f "$k/docker-compose.yml" ] && [ -f "$k/.env" ]; then DIR="$k"; break; fi
done
if [ -z "$DIR" ] || [ ! -f "$DIR/.env" ] || [ ! -f "$DIR/docker-compose.yml" ]; then
  abbruch "Keine RedDrop-Installation gefunden (gesucht in /opt/reddrop). Ordner mit --dir angeben — oder neu installieren: curl -fsSL $QUELLE/install.sh | sudo bash" \
          "No RedDrop installation found (looked in /opt/reddrop). Pass the folder with --dir — or install fresh: curl -fsSL $QUELLE/install.sh | sudo bash"
fi
cd "$DIR" || abbruch "Ordner $DIR nicht lesbar" "Cannot open $DIR"
l=$(sed -n 's/^RD_LANG=//p' .env | tail -1); [ "$l" = "en" ] && SPR="en"
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || abbruch "Docker mit „docker compose“ fehlt auf diesem Server." "Docker with “docker compose” is missing on this server."
alt=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' version.json 2>/dev/null | head -1)
echo ""
echo "${R}${B}RedDrop${N} ${D}— $(s "Aktualisieren" "Update") $(s "in" "in") $DIR${N}"
sich=".sicherung/$(date +%Y%m%d-%H%M%S)"

# 0. Vorab pruefen: genug Platz fuer das neue Image, Datenbank sichern — sonst wird nichts angefasst
schritt "Vorab pruefen und sichern" "Checking and backing up first"
status laeuft "$(s "Vorab-Pruefung" "Pre-check")"
wurzel=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null); [ -d "$wurzel" ] || wurzel=/var/lib/docker; [ -d "$wurzel" ] || wurzel=/
frei=$(df -Pk "$wurzel" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
if [ -n "$frei" ] && [ "$frei" -lt 1024 ]; then
  abbruch "Nur noch ${frei} MB frei (${wurzel}) — fuer das Update braucht es mindestens 1 GB. Nichts wurde geaendert. Platz schaffen, z. B. mit: docker image prune" \
          "Only ${frei} MB free (${wurzel}) — the update needs at least 1 GB. Nothing was changed. Free up space, e.g. with: docker image prune"
fi
info "Freier Platz: ${frei:-?} MB" "Free space: ${frei:-?} MB"
mkdir -p "$sich" && chmod 700 .sicherung
if [ -n "$(docker compose ps -q db 2>/dev/null)" ]; then
  # pg_dump im Datenbank-Container (Benutzer/Name aus dessen Umgebung) — gepackt, nur fuer root lesbar
  warte "Datenbank wird gesichert" "Backing up the database"
  if docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' 2>>"$AUSG" | gzip > "$sich/datenbank.sql.gz" && [ "$(wc -c < "$sich/datenbank.sql.gz")" -gt 200 ]; then
    chmod 600 "$sich/datenbank.sql.gz"
    info "Datenbank gesichert: $sich/datenbank.sql.gz ($(du -h "$sich/datenbank.sql.gz" | cut -f1))" "Database backed up: $sich/datenbank.sql.gz ($(du -h "$sich/datenbank.sql.gz" | cut -f1))"
  else
    rm -f "$sich/datenbank.sql.gz"
    abbruch "Die Datenbank liess sich nicht sichern — Update abgebrochen, nichts wurde geaendert." "The database could not be backed up — update cancelled, nothing was changed."
  fi
else
  info "${Y}Datenbank laeuft gerade nicht — ohne Sicherung weiter.${N}" "${Y}Database is not running — continuing without a backup.${N}"
fi
# fuer den Ruecksprung: welches Image laeuft gerade?
app_alt=$(docker compose ps -q app 2>/dev/null | head -1)
bild_alt=""; bild_name=""
if [ -n "$app_alt" ]; then bild_alt=$(docker inspect -f '{{.Image}}' "$app_alt" 2>/dev/null); bild_name=$(docker inspect -f '{{.Config.Image}}' "$app_alt" 2>/dev/null); fi
# Das alte Image unter eigenem Namen festhalten: Docker mit containerd-Speicher loescht es sonst, sobald das neue
# den Namen uebernimmt und der alte Container ersetzt ist — dann gaebe es beim Ruecksprung nichts mehr zum Starten
SICHER_BILD="ruecksprung/reddrop:vorher"
if [ -n "$bild_alt" ]; then docker tag "$bild_alt" "$SICHER_BILD" >/dev/null 2>&1 || SICHER_BILD=""; else SICHER_BILD=""; fi

# 1. Neueste Dateien holen und pruefen, bevor irgendetwas ersetzt wird
schritt "Neueste Dateien holen" "Fetching the latest files"
status laeuft "$(s "Dateien werden geladen" "Downloading files")"
warte "Dateien werden geladen" "Downloading files"
tmp=$(mktemp -d); trap 'warte_ende; rm -rf "$tmp" "$AUSG" "$AUSG.app" "$SPIN_TXT"' EXIT
t=$(date +%s); geladen=1
for f in $DATEIEN; do
  warte_text "Dateien werden geladen: $f" "Downloading files: $f"
  if ! curl -fsSL --max-time 30 -o "$tmp/$f" "$QUELLE/$f?t=$t" 2>/dev/null; then
    rm -f "$tmp/$f"
    case "$f" in version.json|.env.example|README.md) ;; *) geladen=0; break ;; esac
  fi
done
if [ "$geladen" = 1 ]; then
  for f in install.sh update.sh; do { [ -s "$tmp/$f" ] && bash -n "$tmp/$f" 2>/dev/null; } || geladen=0; done
  grep -q '^services:' "$tmp/docker-compose.yml" 2>/dev/null || geladen=0
fi
geaendert=""
if [ "$geladen" = 1 ]; then
  for f in $DATEIEN; do
    [ -f "$tmp/$f" ] || continue
    cmp -s "$tmp/$f" "$f" 2>/dev/null && continue
    [ ! -f "$f" ] || cp -a "$f" "$sich/"
    # neue Datei daneben anlegen und umbenennen: ein laufendes Skript liest so seine alte Fassung weiter
    cp "$tmp/$f" "$f.neu" && mv -f "$f.neu" "$f" && geaendert="$geaendert $f"
  done
  chmod 755 install.sh update.sh 2>/dev/null || true
  if [ -n "$geaendert" ] && ! docker compose config -q >/dev/null 2>&1; then
    # Neue Compose-Fassung passt nicht zu dieser .env: alles zurueck, mit den alten Dateien weiter
    for f in $geaendert; do if [ -f "$sich/$f" ]; then cp -a "$sich/$f" "$f"; else rm -f "$f"; fi; done
    info "${Y}Die neuen Compose-Dateien passen nicht zu dieser .env — die bisherigen bleiben.${N}" "${Y}The new compose files do not fit this .env — keeping the current ones.${N}"
    geaendert=""
  fi
  if [ -n "$geaendert" ]; then info "Aktualisiert:$geaendert (vorher: $sich)" "Updated:$geaendert (before: $sich)"; else info "Dateien sind schon aktuell" "Files are up to date"; fi
else
  info "${Y}GitHub ist gerade nicht erreichbar — es wird nur das Image aktualisiert.${N}" "${Y}GitHub is not reachable right now — only the image is updated.${N}"
fi
# nur die fuenf neuesten Sicherungen behalten
ls -1d .sicherung/*/ 2>/dev/null | sort -r | tail -n +6 | xargs -r rm -rf

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

# 2. Neues Image laden und neu starten (alle Dienste der .env: App, Datenbank, Caddy, Tunnel …)
schritt "Neues Image laden und neu starten" "Pulling the new image and restarting"
status laeuft "$(s "Image wird geladen" "Pulling the image")"
if [ -d .output ]; then
  warte "Image wird gebaut und gestartet" "Building and starting the image"
  lauf docker compose up -d --build || abbruch "Neustart fehlgeschlagen: $(kurz "$AUSGABE")" "Restart failed: $(kurz "$AUSGABE")"
else
  warte "Neues Image wird geladen" "Pulling the new image"
  lauf docker compose pull --ignore-buildable || lauf docker compose pull || abbruch "Image konnte nicht geladen werden: $(kurz "$AUSGABE")" "Could not pull the image: $(kurz "$AUSGABE")"
  warte "Container werden neu gestartet" "Restarting the containers"
  lauf docker compose up -d || abbruch "Neustart fehlgeschlagen: $(kurz "$AUSGABE")" "Restart failed: $(kurz "$AUSGABE")"
fi
warte "Datenbank-Zugang wird geprüft" "Checking database access"
db_rc=0; db_passwort_angleichen || db_rc=$?
case "$db_rc" in
  2) info "${Y}Das Datenbank-Passwort passte nicht zur .env — angeglichen (Daten bleiben), App neu gestartet.${N}" "${Y}The database password did not match .env — fixed (data kept), app restarted.${N}" ;;
  1) info "${Y}Das Datenbank-Passwort passt nicht zur .env und liess sich nicht angleichen.${N}" "${Y}The database password does not match .env and could not be fixed.${N}" ;;
  *) warte_ende ok ;;
esac

# 3. Selbsttest: meldet sich die App gesund? Sonst zurueck auf die vorherige Fassung (Image + Dateien)
schritt "Selbsttest" "Self-test"
status laeuft "$(s "Selbsttest" "Self-test")"
zustand=""
warte "Selbsttest läuft" "Self-test running"
for i in $(seq 1 90); do
  c=$(docker compose ps -q app 2>/dev/null | head -1)
  zustand=$( [ -n "$c" ] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null )
  case "$zustand" in
    healthy) break ;;
    unhealthy|exited|dead) break ;;
    running) [ "$i" -ge 15 ] && break ;;   # Image ohne Gesundheitspruefung: 30 s durchgelaufen reicht
  esac
  [ $((i % 5)) -eq 0 ] && protokoll "    Selbsttest: $((i * 2)) s, Zustand ${zustand:-startet} …"
  warte_text "Selbsttest läuft — Zustand: ${zustand:-startet}" "Self-test running — state: ${zustand:-starting}"
  sleep 2
done
if [ "$zustand" = "healthy" ] || [ "$zustand" = "running" ]; then
  warte_text "Selbsttest bestanden — App läuft ($zustand)" "Self-test passed — app is running ($zustand)"; warte_ende ok; protokoll "    Selbsttest bestanden ($zustand)"
  [ -n "$SICHER_BILD" ] && docker rmi "$SICHER_BILD" >/dev/null 2>&1 || true
else
  warte_text "Selbsttest fehlgeschlagen — Zustand: ${zustand:-kein Container}" "Self-test failed — state: ${zustand:-no container}"; warte_ende fehler
  docker compose logs --no-color --tail 30 app > "$AUSG.app" 2>&1 || true
  while IFS= read -r z; do protokoll "    $z"; done < "$AUSG.app"
  info "${Y}Die neue Fassung meldet sich nicht gesund (${zustand:-kein Container}) — zurueck auf die vorherige.${N}" "${Y}The new version does not report healthy (${zustand:-no container}) — rolling back.${N}"
  for f in $geaendert; do if [ -f "$sich/$f" ]; then cp -a "$sich/$f" "$f"; else rm -f "$f"; fi; done
  if [ -n "$SICHER_BILD" ] && [ -n "$bild_name" ]; then docker tag "$SICHER_BILD" "$bild_name" >/dev/null 2>&1 || true
  elif [ -n "$bild_alt" ] && [ -n "$bild_name" ]; then docker tag "$bild_alt" "$bild_name" >/dev/null 2>&1 || true; fi
  warte "Vorherige Fassung wird wieder gestartet" "Starting the previous version again"
  lauf docker compose up -d || true
  db_passwort_angleichen >/dev/null 2>&1 || true
  warte_ende ok; cp -f "$AUSG.app" "$AUSG" 2>/dev/null || true
  sd=""; se=""; if [ -f "$sich/datenbank.sql.gz" ]; then sd=" Sicherung der Datenbank: $DIR/$sich/datenbank.sql.gz —"; se=" Database backup: $DIR/$sich/datenbank.sql.gz —"; fi
  abbruch "Update zurueckgenommen: die vorherige Fassung wurde wieder gestartet.$sd Protokoll: docker compose logs app" \
          "Update rolled back: the previous version was started again.$se log: docker compose logs app"
fi

# 4. Update-Dienst neu einrichten (ohne Fragen) — so kommen neue Aktionen fuer das Panel mit
schritt "Update-Dienst auf den neuesten Stand bringen" "Updating the update service"
dienst_hinweis=""
warte "Update-Dienst wird eingerichtet" "Setting up the update service"
if grep -q -- 'DIENST_GRUND' install.sh 2>/dev/null; then
  if out=$(RD_KEIN_BANNER=1 RD_QUELLE="$QUELLE" bash install.sh --dienst </dev/null 2>&1); then
    info "Update-Dienst ist eingerichtet: $(printf '%s' "$out" | grep -o '(systemd\|(cron (Unraid)\|(cron' | head -1 | sed 's/^(//')" "Update service is set up: $(printf '%s' "$out" | grep -o '(systemd\|(cron (Unraid)\|(cron' | head -1 | sed 's/^(//')"
  else
    warte_ende fehler
    dienst_hinweis=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FEHLER|ERROR' | tail -1 | sed 's/^[^A-Z]*//')
    info "${Y}${dienst_hinweis:-$(kurz "$out")}${N}" "${Y}${dienst_hinweis:-$(kurz "$out")}${N}"
  fi
else
  info "${Y}install.sh ist noch eine alte Fassung — beim naechsten Mal klappt es.${N}" "${Y}install.sh is still an old version — it will work next time.${N}"
fi

warte_ende ok
neu=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' version.json 2>/dev/null | head -1)
status fertig "$dienst_hinweis"
echo ""
ver="$neu"; [ -n "$alt" ] && [ -n "$neu" ] && [ "$alt" != "$neu" ] && ver="$alt → $neu"
echo "${G}${B}${Z_OK} $(s "Fertig" "Done")${N} ${D}($(s "nach" "after") ${SECONDS} s)${N}${ver:+ ${D}— RedDrop $ver${N}}"
if [ -z "$dienst_hinweis" ]; then
  info "Ab jetzt reicht im Panel unten links „Jetzt aktualisieren“ — auch dieser Dienst aktualisiert sich dann selbst." "From now on “Update now” at the bottom left of the panel is enough — the service then updates itself too."
else
  info "Das Update selbst ist durch. Der Knopf im Panel geht erst, wenn der Grund oben behoben ist — bis dahin einfach diesen Befehl erneut ausfuehren." "The update itself is done. The panel button only works once the reason above is fixed — until then simply run this command again."
fi
exit 0
}
