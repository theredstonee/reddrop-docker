# RedDrop

**Selbst gehostetes Datei- und Medien-Hosting**: Screenshots, Videos, Musik, Dokumente und Code hochladen und als Link teilen. RedDrop läuft als Docker-Paket auf deinem eigenen Server und holt das HTTPS-Zertifikat selbst.

By [TheRedStonee](https://www.theredstonee.de/) · kostenlos nutzbar, **Pro** für Teams und Firmen

> **English:** Self-hosted file and media hosting. Upload screenshots, videos, music, documents and code and share them as links — optionally end-to-end encrypted, as a gallery or as a paste with syntax highlighting. Passkeys, statistics, Discord/e-mail notifications, optional ClamAV virus scan. Works with ShareX and Flameshot. Move over from Zipline, XBackBone, Chibisafe, ShareX, Imgur or Google Photos. One `docker compose up`, automatic HTTPS via Let's Encrypt. German and English. Jump to [Quick start](#schnellstart).

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
- **Datenschutz:** Standort- und Kameradaten werden verlustfrei entfernt. Bilder lassen sich optional nach WebP oder AVIF umwandeln.
- **Ordner und Tags**, auch verschachtelt. Dazu Favoriten, Suche, Sammelaktionen und ein **Papierkorb** (30 Tage).
- **Statistik:** Aufrufe pro Tag, Herkunft (Discord, Reddit …) und Länder — gezählt ohne IP-Adressen.
- **Benachrichtigungen** per Discord-Webhook oder E-Mail: Datei-Anfragen, Speicher fast voll, Virenfund.
- **Virenscan** (optional): ClamAV prüft jede Datei, Funde kommen in Quarantäne.
- **Protokoll:** wer wann was gemacht hat — für jedes Konto, Admins sehen alles.
- **Datei-Anfragen:** Andere laden über einen Link Dateien zu dir hoch, auch ohne Konto.
- **Umzug aus anderen Diensten:** Zipline v3/v4, XBackBone, Chibisafe, ShareX-Verlauf, Imgur und Google Fotos (Takeout). Mit dabei sind:
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

Die Lizenz wird online geprüft. Ist der Lizenzserver einmal nicht erreichbar, läuft Pro 7 Tage weiter. Für Server ohne Internet gibt es eine Offline-Lizenzdatei. Alle Server einer Installation zählen als **eine** Installation.

## Voraussetzungen

| | Minimum | Empfohlen |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU (Videos) |
| RAM | 1 GB | 2 GB (mit Virenscan 3 GB) |
| Speicher | 5 GB + deine Dateien | je nach Bedarf — oder S3 (Pro) |

- Ein Linux-Server (Debian oder Ubuntu) mit Root-Zugriff.
- Port **80** und **443** von außen erreichbar, oder ein schon laufender nginx/Apache, hinter den sich RedDrop hängt.
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

## Umzug aus einem anderen Dienst

Seite **Import** im Panel. Es gibt drei Wege:
- **Verbindung:** Adresse und API-Schlüssel der alten Instanz.
- **Datei hochladen:** Export oder ZIP.
- **Server-Ordner:** den alten Upload-Ordner nach `./import` kopieren (im Container `/import`, nur lesend).

## Pro einrichten

1. **Lizenz:** Panel → **Pro & Lizenz** → Schlüssel eingeben. Ohne Internet: die Offline-Lizenzdatei im Kunden-Portal mit der angezeigten Geräte-ID erstellen und hineinziehen.
2. **S3:** Panel → **Speicher & Server** → S3 wählen, Zugang eintragen, **Verbindung testen**, speichern. Neue Dateien landen dann in S3; vorhandene ziehen per **Umzug** um.

   Der S3-Zugang lässt sich auch fest in der `.env` vorgeben (`RD_S3_ENDPOINT`, `RD_S3_REGION`, `RD_S3_BUCKET`, `RD_S3_ACCESS_KEY`, `RD_S3_SECRET_KEY`, `RD_S3_PATH_STYLE`, `RD_S3_PREFIX`). Er ist dann im Panel nur lesbar.

   Der Schlüssel braucht die Rechte Lesen, Schreiben, Löschen und Auflisten für den Bucket.
3. **Weitere Server:** siehe `compose.node.yml`. Die Server teilen sich die Datenbank des ersten Servers. Dateien liegen in S3 oder auf einem gemeinsamen Laufwerk (NFS). Im Lastverteiler die Sitzungsbindung einschalten.
4. **SSO:** Panel → **Anmeldung (SSO)** → Anbieter hinzufügen. Die angezeigte **Rücksprung-Adresse** beim Anbieter eintragen.
5. **Eigene Marke:** Panel → **Eigene Marke**. Name und Akzentfarbe stehen unter Einstellungen → Installation.

## Update

Am einfachsten im Panel: unten links in der Seitenleiste steht die Version — ein roter Punkt heißt „neue Version da“, Klick → **Jetzt aktualisieren**. Von Hand:

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
