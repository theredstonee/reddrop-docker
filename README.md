# RedDrop

**Selbst gehostetes Datei- und Medien-Hosting**: Screenshots, Videos, Musik, Dokumente und Code hochladen und als Link teilen. RedDrop läuft als Docker-Paket auf deinem eigenen Server und holt das HTTPS-Zertifikat selbst.

By [TheRedStonee](https://www.theredstonee.de/) · kostenlos nutzbar, **Pro** für Teams und Firmen

> **English:** Self-hosted file and media hosting. Upload screenshots, videos, music, documents and code and share them as links — optionally end-to-end encrypted, as a gallery or as a paste with syntax highlighting. Passkeys, statistics, Discord/e-mail notifications, optional ClamAV virus scan, REST API with webhooks, automatic storage rules, CDN features (image resizing via URL, hotlink protection). Works with ShareX and Flameshot. HEIC photos and Live Photos from the iPhone just work. Move over from Zipline, XBackBone, Chibisafe, ShareX, Imgur, Google Photos, iCloud (data export, shared links or Apple ID sign-in) or Tiny File Manager. One `docker compose up`, automatic HTTPS via Let's Encrypt. German and English. Jump to [Quick start](#schnellstart).

---

## Was es kann

- **Hochladen, wie es passt:** Dateien ins Fenster ziehen, mit Strg + V einfügen oder über ShareX, Flameshot und curl senden. Große Dateien gehen in Stücken und setzen nach einem Abbruch fort.
- **Jede Datei hat eine eigene Seite** mit Vorschau für Bilder, Videos, Audio, Text und Code. Dazu gibt es einen Direktlink (nur die Datei, wie bei einem Bild-Hoster), einen Download-Link und einen Raw-Link.
- **Teilen mit Grenzen:** Ablaufdatum, Passwort, Höchstzahl an Aufrufen, eigener Linkname. Linknamen gibt es in sechs Stilen: Zufall, Wörter, Datum, Dateiname, UUID oder unsichtbar.
- **Ende-zu-Ende-Verschlüsselung:** ein Schalter beim Hochladen. Verschlüsselt wird im Browser, der Schlüssel steckt nur im Link — der Server sieht nie den Inhalt.
- **Text & Code:** einfügen, Sprache wählen oder erkennen lassen, mit Syntax-Hervorhebung teilen — auch mit Ablauf und „nach dem Lesen löschen“.
- **Galerien:** ein Ordner als öffentliche Seite mit Großansicht, Diashow und „Alles als ZIP“.
- **Embed-Designer:** So sieht dein Link in Discord, Telegram und WhatsApp aus (Titel, Text, Farbe, Bild).
- **Medien:**
  - Video-Player mit Vorschau-Streifen beim Spulen und Audio-Player mit Wellenform
  - Vorschaubilder für alle Bilder und Videos
  - Bilder im Browser bearbeiten
  - **iPhone-Fotos:** HEIC bleibt im Original, Vorschau, Direktlink und Galerie zeigen ein JPEG. **Live Photos** sind ein Eintrag — das kurze Video spielt beim Drüberfahren.
- **Datenschutz:** Standort- und Kameradaten werden verlustfrei entfernt. Bilder lassen sich optional nach WebP oder AVIF umwandeln.
- **Ordner und Tags**, auch verschachtelt. Dazu Favoriten, Suche, Sammelaktionen und ein **Papierkorb** (30 Tage).
- **Statistik:** Aufrufe pro Tag, Herkunft (Discord, Reddit …) und Länder — gezählt ohne IP-Adressen.
- **Benachrichtigungen** per Discord-Webhook oder E-Mail: Datei-Anfragen, Speicher fast voll, Virenfund.
- **Virenscan** (optional): ClamAV prüft jede Datei, Funde kommen in Quarantäne.
- **Protokoll:** wer wann was gemacht hat — für jedes Konto, Admins sehen alles.
- **API und Webhooks:** eine dokumentierte REST-API (`/api/v1`, OpenAPI unter `/api/v1/openapi.json`) mit Token-Rechten (Hochladen, Lesen, Verwalten) und signierte Webhooks mit Wiederholung — für n8n, Zapier, Make oder eigene Skripte.
- **Als CDN (beides standardmäßig aus):**
  - **Bilder per URL anpassen:** `…/r/bild.png?w=800&h=600&fit=cover&format=webp&q=80` — Größe, Zuschnitt, Format (WebP, AVIF, JPEG, PNG oder `auto` = bestes, das der Browser kann) und Qualität. Jede Variante entsteht einmal und wird zwischengespeichert.
  - **Hotlink-Schutz:** Direktlinks und Vorschaubilder nur auf erlaubten Websites einbinden; die eigene Domain ist immer erlaubt, Downloads bleiben offen.
- **Speicher-Regeln:** alte oder lange nicht angesehene Dateien räumen sich von selbst auf — in den Papierkorb, endgültig oder (mit S3) ausgelagert. Mit Vorschau, wie viele Dateien eine Regel trifft.
- **Datei-Anfragen:** Andere laden über einen Link Dateien zu dir hoch, auch ohne Konto.
- **Umzug aus anderen Diensten:** Zipline v3/v4, XBackBone, Chibisafe, ShareX-Verlauf, Imgur, Google Fotos (Takeout), iCloud (Fotos und Drive) und Tiny File Manager (Webordner samt Konten aus der `config.php`). Mit dabei sind:
  - Konten samt Passwörtern, Ordner und Tags
  - alte Linknamen; alte Pfade wie `/u/abc.png` leiten auf die neue Datei weiter
- **Mehrere Konten** mit Speicher-Kontingent, Zwei-Faktor-Anmeldung mit Notfall-Codes und **Passkeys** (Fingerabdruck, Face ID, Sicherheitsschlüssel).
- **Hell und dunkel, Deutsch und Englisch.** Dazu ein Einrichtungs-Assistent mit Domain-Prüfung und automatischem HTTPS.

### Pro

Pro wird mit einem Lizenzschlüssel freigeschaltet. Alles oben bleibt ohne Lizenz voll nutzbar.

- **Mehrere Server:** Weitere RedDrop-Container teilen sich eine Datenbank. Vorschaubilder, Importe und Aufräumen verteilen sich von selbst, nichts läuft doppelt. Fällt ein Server aus, übernimmt ein anderer.
- **S3-Speicher:** AWS, Cloudflare R2, Backblaze B2, Wasabi, Hetzner, MinIO oder Garage. Der Umzug aller Dateien geht per Klick und in beide Richtungen; Links bleiben gleich und Videos spulen weiter direkt.
- **Teams und Rollen:**
  - Team-Ordner, in denen alle Mitglieder die Dateien sehen und hochladen; die Team-Leitung verwaltet alles darin.
  - Eigene Rollen mit Rechten (Hochladen, Anfragen, Import) und Grenzen (Dateigröße, Speicher, automatisches Löschen).
- **Anmeldung über SSO:** OpenID Connect (Authentik, Keycloak, Authelia, Zitadel, Okta …), Google, Microsoft, GitHub und Discord.
  - Neue Konten auf Wunsch automatisch, mit Rolle und Team.
  - Nur bestimmte E-Mail-Domains zulassen, Gruppe → Admin.
  - Passwort-Anmeldung abschaltbar.
- **Eigene Marke:** eigenes Logo und Browser-Symbol, eigener Text auf der Anmeldeseite, eigene Fußzeile und kein „Mit RedDrop geteilt“.
- **Sicherung per Knopf:** die ganze Installation als eine ZIP-Datei — Datenbank und jede Datei, lokal wie aus S3. Auf jedem RedDrop-Server wieder einspielbar, Links bleiben gleich.
- **Traffic & Grenzen:** ausgelieferte Datenmenge pro Tag und Datei (bei Teil-Abrufen nur das übertragene Stück), Übersicht für alle Konten, monatliche Grenze pro Konto oder Rolle mit Warnung bei 80 % und 100 %.
- **Monitoring:** Systemseite mit Verläufen (Anfragen, Fehler, Antwortzeit, CPU, Arbeitsspeicher), Prometheus-Endpunkt `/metrics`, fertiges Grafana-Dashboard und Warnungen bei voller Platte, vielen Fehlern oder ausgefallenem Server.

Die Lizenz wird online geprüft. Ist der Lizenzserver einmal nicht erreichbar, läuft Pro 7 Tage weiter. Für Server ohne Internet gibt es eine Offline-Lizenzdatei. Alle Server einer Installation zählen als **eine** Installation.

## Voraussetzungen

| | Minimum | Empfohlen |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU (Videos) |
| RAM | 1 GB | 2 GB (mit Virenscan 3 GB) |
| Speicher | 5 GB + deine Dateien | je nach Bedarf — oder S3 (Pro) |

- Ein Linux-Server (Debian oder Ubuntu) mit Root-Zugriff.
- Port **80** und **443** von außen erreichbar, ein schon laufender nginx/Apache, hinter den sich RedDrop hängt — oder ein [Cloudflare Tunnel](#cloudflare-tunnel-ohne-offene-ports), dann muss gar kein Port offen sein.
- Für HTTPS eine (Sub-)Domain, deren DNS-A-Eintrag auf den Server zeigt.

## Schnellstart

```bash
curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/install.sh | sudo bash
```

Das Skript erledigt Folgendes:
- legt alles nach **`/opt/reddrop`** (anderer Ordner: `curl … | sudo RD_DIR=/srv/reddrop bash`)
- installiert Docker, falls nötig
- erzeugt ein Datenbank-Passwort und startet alles
- zeigt am Ende die Adresse und den **Setup-Code**

Öffne die Adresse im Browser und folge dem Assistenten.

<details>
<summary>Lieber von Hand?</summary>

```bash
mkdir reddrop && cd reddrop
for f in docker-compose.yml compose.caddy.yml compose.port.yml Caddyfile .env.example; do curl -fsSLO "https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/$f"; done
cp .env.example .env
nano .env                # DB_PASSWORD setzen (lang und zufällig)
mkdir -p import
docker compose up -d
docker compose logs app | grep Setup-Code
```

Danach `http://<IP-deines-Servers>` im Browser öffnen.
</details>

### Domain und HTTPS

Im Assistenten gibst du deine Domain ein. Er zeigt die erkannte Server-IP und den nötigen DNS-Eintrag, prüft ihn und holt das Zertifikat.

- Lege einen **A-Eintrag** auf die IP deines Servers an.
- Bei **Cloudflare** den Proxy ausschalten (graue Wolke), sonst kann das Zertifikat nicht ausgestellt werden.

### Hinter deinem eigenen Webserver

Läuft auf dem Server schon nginx, Apache oder ein Panel wie Plesk auf Port 80/443, merkt `install.sh` das und richtet RedDrop **ohne eigenen Caddy** ein:
- Die App bekommt einen freien Port auf `127.0.0.1`.
- Auf Nachfrage legt das Skript für deine Domain den Virtual Host an und holt per `certbot` das Zertifikat.
- Noch keine Domain? Dann ist RedDrop **nur für die Einrichtung** unter `http://<Server-IP>` erreichbar: ein eigener Eintrag nur für die IP, geschützt durch den Setup-Code. Nach dem Assistenten entfernt das Skript ihn wieder und richtet für die Domain aus dem Assistenten Virtual Host und Zertifikat ein.

Wichtig für große Uploads: im Webserver keine Größengrenze setzen (nginx: `client_max_body_size 0;`).

Ohne Nachfragen geht es mit Schaltern:

```bash
sudo bash install.sh --port 8080 --domain drop.deinefirma.de --email du@deinefirma.de
```

`--no-vhost` lässt den Webserver unangetastet, `--caddy` erzwingt den eigenen Caddy, `--virenscan` / `--no-virenscan` beantwortet die Frage nach ClamAV.

### Cloudflare Tunnel (ohne offene Ports)

Für Heimserver oder Server hinter einer Firewall: RedDrop baut über einen eigenen `cloudflared`-Container die Verbindung zu Cloudflare auf, Cloudflare liefert deine Domain samt HTTPS aus — Port 80/443 müssen nicht offen sein. Einrichten gleich im **Einrichtungs-Assistenten** (Schritt „Adresse & HTTPS“ → „Cloudflare Tunnel“) oder später im Panel unter **Einstellungen → Installation → Cloudflare Tunnel**, auf zwei Wegen:

- **Tunnel-Token:** Tunnel im Cloudflare-Dashboard anlegen (Zero Trust → Networks → Tunnels), als Public Hostname deine Domain mit Service `HTTP` → `app:3000`, dann den Token im Panel einfügen.
- **Automatisch:** ein Cloudflare-API-Token mit den Rechten „Account → Cloudflare Tunnel → Edit“ und „Zone → DNS → Edit“ einfügen — RedDrop legt Tunnel, Weiterleitung und DNS-Eintrag selbst an und räumt sie auf Wunsch wieder ab.

Der Schalter braucht den Update-Dienst auf dem Server (einmal `sudo bash install.sh` bei älteren Installationen).

### Virenscan

Der Installer fragt einmal, ob ClamAV mitlaufen soll (eigener Container, etwa 1,5 GB Arbeitsspeicher). Später schaltest du ihn unter **Einstellungen → Installation** an und aus; der Update-Dienst auf dem Server startet bzw. stoppt den Container dann selbst. Geprüft wird jede Datei bis 100 MB, beim Einschalten auch alle vorhandenen. Ende-zu-Ende-verschlüsselte Dateien kann kein Virenscanner lesen, sie werden übersprungen.

Von Hand: `COMPOSE_PROFILES=virenscan` in die `.env` schreiben und `docker compose up -d`.

## Upload-Werkzeuge

Im Panel unter **Upload-Werkzeuge** gibt es fertige Konfigurationen für **ShareX** (`.sxcu`), **Flameshot** (Skript) und **curl**. Hochgeladen wird über `POST /api/upload` mit einem Upload-Token. Optionen lassen sich als Header mitgeben:

| Header | Bedeutung |
|---|---|
| `x-rd-expires` | Ablauf, z. B. `7d`, `12h` oder ein Datum |
| `x-rd-max-views` | höchstens so viele Aufrufe |
| `x-rd-password` | Passwort für die Datei |
| `x-rd-name-style` | `zufall`, `woerter`, `datum`, `original`, `uuid`, `unsichtbar` |
| `x-rd-folder` | Ordner-ID |

## API und Webhooks

- **Token:** Panel → **Upload-Werkzeuge** → Token mit den Rechten anlegen, die das Skript braucht (Hochladen, Lesen, Verwalten).
- **Doku:** Panel → **API-Doku** — jeder Endpunkt mit curl-Beispiel für deine Adresse. Für Postman, Insomnia oder Code-Generatoren: `https://<deine-domain>/api/v1/openapi.json`.
- **Webhooks:** Panel → **Webhooks**. Jede Zustellung trägt `X-RedDrop-Signature: t=<zeit>,v1=<HMAC-SHA256>`; Prüf-Code für Node.js, Python und PHP steht in der API-Doku. Ziele im eigenen Netz (192.168.x.x …) sind gesperrt, bis der Inhaber sie freigibt.

```bash
curl -H "Authorization: Bearer rd_…" https://drop.deinefirma.de/api/v1/files?per_page=10
```

## Monitoring (Pro)

Panel → **System** → **Zugang einrichten** erzeugt ein Token für Prometheus:

```yaml
scrape_configs:
  - job_name: reddrop
    scheme: https
    metrics_path: /metrics
    authorization:
      credentials: rdm_…
    static_configs:
      - targets: ['drop.deinefirma.de']
```

Laufen mehrere Server, jeden einzeln abfragen (jeder zählt seine eigenen Anfragen). Das Grafana-Dashboard gibt es auf derselben Seite zum Herunterladen.

## Umzug aus einem anderen Dienst

Seite **Import** im Panel. Es gibt drei Wege:
- **Verbindung:** Adresse und API-Schlüssel der alten Instanz.
- **Datei hochladen:** Export oder ZIP.
- **Server-Ordner:** den alten Upload-Ordner nach `./import` kopieren (im Container `/import`, nur lesend).

**iCloud** hat vier Wege:
- **Apple-Export:** auf [privacy.apple.com](https://privacy.apple.com/) eine Kopie der Daten anfordern („iCloud Fotos“ und/oder „iCloud Drive“) und alle ZIP-Teile hochladen. Datum, Favoriten, Alben, ausgeblendete Fotos und Live Photos kommen mit.
- **Link:** geteilte Alben (`icloud.com/sharedalbum/…`) und Freigaben einzelner Drive-Dateien. Ältere geteilte Alben enthalten bei Apple nur verkleinerte Fassungen.
- **Apple-ID:** anmelden und den Code vom iPhone eingeben — dann kommt die ganze Fotos-Mediathek im Original (samt geteilter Mediathek und Alben) und auf Wunsch iCloud Drive. Das Passwort geht nur an Apple und wird nicht gespeichert; die Anmeldung gilt nur für diesen Import. Mit „Erweitertem Datenschutz“ muss am iPhone „Zugriff auf iCloud-Daten im Web“ eingeschaltet sein.
- **Server-Ordner:** die Export-ZIPs nach `./import` legen.

## Pro einrichten

1. **Lizenz:** Panel → **Pro & Lizenz** → Schlüssel eingeben. Ohne Internet: die Offline-Lizenzdatei im Kunden-Portal mit der angezeigten Geräte-ID erstellen und hineinziehen.
2. **S3:** Panel → **Speicher & Server** → S3 wählen, Zugang eintragen, **Verbindung testen**, speichern. Neue Dateien landen dann in S3; vorhandene ziehen per **Umzug** um.

   Der S3-Zugang lässt sich auch fest in der `.env` vorgeben (`RD_S3_ENDPOINT`, `RD_S3_REGION`, `RD_S3_BUCKET`, `RD_S3_ACCESS_KEY`, `RD_S3_SECRET_KEY`, `RD_S3_PATH_STYLE`, `RD_S3_PREFIX`). Er ist dann im Panel nur lesbar.

   Der Schlüssel braucht die Rechte Lesen, Schreiben, Löschen und Auflisten für den Bucket.
3. **Weitere Server:** siehe `compose.node.yml`. Die Server teilen sich die Datenbank des ersten Servers. Dateien liegen in S3 oder auf einem gemeinsamen Laufwerk (NFS). Im Lastverteiler die Sitzungsbindung einschalten.
4. **SSO:** Panel → **Anmeldung (SSO)** → Anbieter hinzufügen. Die angezeigte **Rücksprung-Adresse** beim Anbieter eintragen.
5. **Eigene Marke:** Panel → **Eigene Marke**. Name und Akzentfarbe stehen unter Einstellungen → Installation.

## Update

Am einfachsten im Panel: unten links in der Seitenleiste steht die Version — ein roter Punkt heißt „neue Version da“, Klick → **Jetzt aktualisieren**. Das holt das neue Image, die aktuellen Compose-Dateien und bringt auch den Update-Dienst selbst auf den neuesten Stand.

Auf dem Server geht dasselbe mit einem Befehl — er richtet **nichts neu ein**, fragt nichts und lässt `.env`, Daten und Domain, wie sie sind (alte Dateien landen in `.sicherung/`):

```bash
curl -fsSL https://raw.githubusercontent.com/theredstonee/reddrop-docker/main/update.sh | sudo bash
```

Installationen von vor diesem Befehl brauchen ihn **einmal** — danach aktualisiert der Knopf im Panel auch den Dienst. Ganz von Hand, nur das Image:

```bash
cd /opt/reddrop
docker compose pull && docker compose up -d
```

Die Datenbank wird beim Start automatisch nachgezogen. Ein zweiter Aufruf von `sudo bash install.sh` macht dasselbe und bringt auch den Update-Dienst auf den neuesten Stand (nötig, damit der Virenscan-Schalter im Panel den Container steuern kann).

## Entfernen

```bash
sudo bash /opt/reddrop/install.sh --deinstallieren
```

Stoppt und entfernt die Container und die Webserver-Einträge von RedDrop (gesichert nach `/root/reddrop-backup`). Dateien, Datenbank und Ordner werden nur nach einer Rückfrage und dem Eintippen von `loeschen` gelöscht; sonst bleiben sie für einen Neustart erhalten.

## Sicherung

**Mit Pro:** Panel → **Sicherung** → **Jetzt sichern** lädt eine ZIP-Datei mit allem herunter. Einspielen geht auf derselben Seite (hochladen oder, bei sehr großen Sicherungen, die ZIP in den Ordner `import/` legen). Das ersetzt alles auf dem Server; schlägt etwas fehl, bleibt der alte Stand.

**Ohne Pro, von Hand:**
- **Datenbank:** `docker compose exec db pg_dump -U reddrop reddrop > reddrop.sql`
- **Dateien:** das Volume `dateien` (im Container `/data`), bei S3 der Bucket.

## Hilfe

- **Zwei-Faktor-Gerät verloren und keine Notfall-Codes:** den Container einmal mit `RD_RESET_2FA=<benutzername>` in der `.env` starten (`docker compose up -d`), danach die Zeile wieder entfernen.
- **Setup-Code nicht mehr da:** `docker compose logs app | grep Setup-Code`
- **Logs:** `docker compose logs -f app`

---

RedDrop ist ein Produkt von [TheRedStonee](https://www.theredstonee.de/). Der Quelltext ist nicht öffentlich; dieses Repository enthält die Installationsdateien für das Docker-Image `ghcr.io/theredstonee/reddrop`.
