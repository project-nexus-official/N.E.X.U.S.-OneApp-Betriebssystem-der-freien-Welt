# N.E.X.U.S. OneApp — Feature-Spezifikation v0.1.7-alpha

Stand: 2026-04-09  
Generiert aus: 71612c0  
Version: 0.1.7+1 (pubspec.yaml)

---

## 1. Identität & Onboarding

### 1.1 Erster Start — Neues Konto

Beim ersten Start öffnet sich automatisch der Onboarding-Flow (Route `/onboarding`). Der Nutzer hat zwei Optionen:

- **Neue Identität erstellen** — startet den mehrstufigen Erstellungsprozess
- **Identität wiederherstellen** — navigiert zu `/onboarding/restore`

#### Schritte für neue Identität:

**Schritt 1 — Willkommen**  
Anzeige des N.E.X.U.S.-Logos (goldener Kreis mit "N"). Auswahl: "Neue Identität erstellen" oder "Identität wiederherstellen".

**Schritt 2 — Seed Phrase anzeigen**  
Das System generiert automatisch eine BIP-39-Mnemonic mit **12 Wörtern** (englischsprachig). Die Wörter werden nummeriert in einer Liste angezeigt. Der Nutzer muss diese Wörter sicher verwahren — sie sind der einzige Weg zur Wiederherstellung der Identität.

**Schritt 3 — Seed Phrase verifizieren**  
Das System wählt zufällig **3 der 12 Wörter** aus (nach Position) und fordert den Nutzer auf, diese korrekt einzutippen. Nur bei korrekter Eingabe aller 3 Wörter wird fortgefahren. Falsche Eingabe zeigt eine Fehlermeldung mit der Positionsnummer des falschen Wortes.

**Schritt 4 — Pseudonym wählen**  
Ein zufälliges Pseudonym wird vorgeschlagen (generiert durch `PseudonymGenerator`). Der Nutzer kann es übernehmen oder ein eigenes eingeben. Das Pseudonym ist der angezeigte Name innerhalb der App.

**Schritt 5 — Fertig**  
Identität wird erstellt. Die App navigiert zu `/home`. Der Router leitet bei nicht gesehenen Grundsätzen automatisch nach `/principles/intro` weiter, danach nach `/backup-setup`.

#### Was wird gespeichert:
- **Seed Phrase**: Im Gerätespeicher (Android Keystore / SecureStorage), nie exportiert
- **DID (Dezentrale Identität)**: Format `did:key:z6Mk...` — abgeleitet aus dem Ed25519-Schlüsselpaar, das aus der Seed Phrase generiert wird
- **Profil**: In der verschlüsselten SQLite-Datenbank (POD)
- **Nostr-Schlüssel**: Ed25519-basiert, ebenfalls aus der Seed Phrase abgeleitet
- **X25519-Schlüssel**: Für E2E-Verschlüsselung, abgeleitet aus dem Ed25519-Seed via HKDF-SHA256

### 1.2 Identität wiederherstellen

Route: `/onboarding/restore`

Der Nutzer gibt seine 12-Wörter-Seed-Phrase ein. Bei korrekter Eingabe wird die Identität (DID, Schlüsselpaare) rekonstruiert. Nach Wiederherstellung: Router leitet nach `/onboarding/restore-backup` weiter.

### 1.3 Grundsätze-Flow (Principles)

Nach erstmaliger Identitätserstellung oder nach App-Update (wenn Grundsätze noch nicht gesehen wurden), wird der Nutzer automatisch zu `/principles/intro` weitergeleitet.

**Screen 1 — Einführung** (`/principles/intro`):  
Ruhiger Eingangsscreen mit Fade-In-Animation (1 Sekunde). Goldener Button "Ich bin bereit" → weiter zu Screen 2.

**Screen 2 — Inhalte** (`/principles/content`):  
PageView mit 4 Seiten:
- Seite 1: Titel & Einleitung + Säule 1 (Do No Harm)
- Seite 2: Säulen 2 (Transparenz) + 3 (Subsidiarität) als goldene Karten
- Seite 3: 5 unveräußerliche Rechte als goldene Bullet-Points
- Seite 4: Bekenntnis + Pakt

Fortschrittsanzeige: 4 Punkte, aktiver Punkt gold. Zurück-Pfeil ab Seite 2. Im `readOnly=true`-Modus (Einstellungen-Aufruf) heißt der letzte Button "Schließen" statt "Weiter".

**Screen 3 — Bekenntnis** (`/principles/commitment`):  
Zwei Checkboxen (animiert, goldener Akzent). Der Button "Ich trete ein" wird nur aktiv, wenn **beide** Checkboxen gesetzt sind. Pulsiert einmal beim Aktivwerden.

- "Ich trete ein" → `accept()` + Navigation zu `/home`
- "Später zurückkehren" → `skip()` + Navigation zu `/home` (Dashboard zeigt Erinnerungs-Banner)

#### Erinnerungs-Banner auf dem Dashboard:
Erscheint wenn Grundsätze noch nicht bestätigt (`!isAccepted && !_principlesReminderDismissed`). Goldener Rahmen, X-Button zum Verbergen (nur für diese Sitzung). "Jetzt lesen"-Button → `/principles/intro`.

### 1.4 Backup-Einrichtung

Route: `/backup-setup`

Erscheint automatisch nach dem Grundsätze-Flow (einmalig). Erklärt das Backup-System und fragt, ob automatische Backups aktiviert werden sollen.

**Was gesichert wird:**
- Kontakte & Vertrauensstufen
- Kanal-Mitgliedschaften
- Zellen-Mitgliedschaften
- Profildaten
- Grundsätze-Status
- Benachrichtigungseinstellungen

**Was NICHT gesichert wird:**
- Seed Phrase / Private Keys (niemals)
- Nachrichten
- Bilder und Sprachnachrichten

**Speicherort:** Android → `getExternalStorageDirectory()/nexus_backups/`; Windows/andere → `Dokumente/nexus_backups/`  
**Dateiname:** `nexus_backup_YYYYMMDD_HHMMSS.enc`  
**Verschlüsselung:** AES-256-GCM mit SHA-256(seed64 + "nexus-backup-v1") als Schlüssel  
**Rotation:** Maximal 3 Backups, älteste werden automatisch gelöscht  
**Intervall:** Automatisch alle 24 Stunden (nur wenn sich Daten geändert haben — Hash-Vergleich)

### 1.5 Backup wiederherstellen

Route: `/onboarding/restore-backup`

Erscheint automatisch nach Seed-Phrase-Wiederherstellung. Die App sucht Backup-Dateien im Backup-Verzeichnis. Bei gefundenen Backups: Auswahl und Wiederherstellung. **Merge-Logik:** Bestehende Kontakte/Kanäle/Zellen werden nicht überschrieben — nur fehlende Daten werden ergänzt.

---

## 2. Hauptnavigation

### 2.1 Bottom-Navigation (ShellRoute)

Die App verwendet eine 5-Tab Bottom-Navigation. Alle Tabs innerhalb des ShellRoute zeigen die Bottom-Navigation:

| Index | Label | Icon | Route |
|-------|-------|------|-------|
| 0 | Home | house | `/home` |
| 1 | Chat | chat_bubble | `/chat` |
| 2 | Dorfplatz | people / forum | `/dorfplatz` |
| 3 | Entdecken | explore | `/discover` |
| 4 | Profil | person | `/profile` |

Der `/wallet`-Tab ist im ShellRoute vorhanden, erscheint aber **nicht** in der Bottom-Navigation (für zukünftige Nutzung in Phase 1c reserviert).

### 2.2 Screens ohne Bottom-Navigation (außerhalb ShellRoute)

Diese Screens erscheinen vollbildschirmig ohne die Bottom-Navigation:

| Route | Screen |
|-------|--------|
| `/onboarding` | Onboarding (neues Konto) |
| `/onboarding/restore` | Seed-Phrase-Wiederherstellung |
| `/onboarding/restore-backup` | Backup-Wiederherstellung |
| `/backup-setup` | Backup-Einrichtung (einmalig) |
| `/principles/intro` | Grundsätze-Einführung |
| `/principles/content` | Grundsätze-Inhalt |
| `/principles/commitment` | Grundsätze-Bekenntnis |
| `/governance` | Agora — Politik & Demokratie |
| `/cell-hub` | Zellen-Hub ("Meine Zelle") |
| `/settings` | Einstellungen |
| `/contacts` | Kontakte |
| `/qr-scanner` | QR-Code-Scanner |
| `/contact-requests` | Eingehende Kontaktanfragen |
| `/contact-requests/sent` | Gesendete Kontaktanfragen |
| `/invite` | Einladungen |
| `/invite/redeem?c=CODE` | Einladungscode einlösen |

### 2.3 Router-Weiterleitungen

- Keine Identität → automatisch nach `/onboarding`
- Identität vorhanden, aber Onboarding geöffnet → nach `/home` oder `/principles/intro`
- Grundsätze noch nicht gesehen → nach `/principles/intro` (auch für bestehende Nutzer)
- Backup-Setup noch nicht gesehen (nach Grundsätzen) → nach `/backup-setup`

---

## 3. Kontakte & Vertrauen

### 3.1 Wege, einen Kontakt hinzuzufügen

**Weg 1 — QR-Code scannen:**  
`Kontakte-Screen` → FAB → "QR-Code scannen" oder `Profil-Screen` → "Kontakt scannen". Öffnet `QrScannerScreen` (Route `/qr-scanner`). Nach Scan: Bottom Sheet mit Identicon, Pseudonym, DID und Aktionen. Kontakt wird direkt auf Stufe "Kontakt" (TrustLevel.contact) gesetzt — Face-to-Face = volle Vertrauensstufe.

**Weg 2 — Kontaktanfrage senden:**  
Über Chat-Einstiegsschirm wenn Peer nur "Entdeckt"-Status hat. Formular mit optionalem Vorstellungstext (max. 500 Zeichen). Nach Versand: "Ausstehend"-Ansicht. Annahme/Ablehnung durch den Empfänger (stilll, kein Feedback bei Ablehnung/Ignorieren).

**Weg 3 — Radar / Peers in der Nähe:**  
Im Chat-FAB → "Peers in der Nähe" oder über den Radar-Screen. Entdeckte BLE/LAN-Peers erscheinen und können als Kontakt hinzugefügt werden.

**Weg 4 — Einladungslink einlösen:**  
Einladung eines bestehenden Mitglieds (`/invite/redeem`). Nach Einlösung wird der Einlader automatisch als Kontakt hinzugefügt.

### 3.2 Vertrauensstufen

| Stufe | Name | sortWeight | Beschreibung |
|-------|------|-----------|--------------|
| 0 | Entdeckt | 0 | Automatisch erkannte Peers (BLE/LAN/Nostr); noch kein Kontakt |
| 1 | Kontakt | 1 | Manuell hinzugefügt oder Kontaktanfrage angenommen |
| 2 | Vertrauensperson | 2 | Erhöhtes Vertrauen, kann mehr Profilinformationen sehen |
| 3 | Bürge | 3 | Höchstes Vertrauen; Bürgschaftsverhältnis |

Die Vertrauensstufe steuert, welche Profilfelder sichtbar sind (`allowedVisibility`). Beispiel: Profilbild mit Sichtbarkeit "contacts" ist nur für Kontakte und darüber sichtbar.

Vertrauensstufe kann in `ContactDetailScreen` geändert werden (über ein Dropdown-Menü oder Auswahloptionen).

### 3.3 Trust-Badges in der UI

Trust-Badges erscheinen in:
- Gesprächsliste-Tiles (neben dem Kontaktnamen)
- Chat-Header (AppBar beim Direktgespräch)
- Radar-Screen (neben dem Pseudonym)
- Kontaktliste (`ContactsScreen`)

| Badge | Stufe |
|-------|-------|
| Kein Badge | Entdeckt |
| Bronze-Ring | Kontakt |
| Silber-Ring | Vertrauensperson |
| Gold-Ring | Bürge |

### 3.4 Kontaktanfragen-Workflow

**Senden:**  
Beim Öffnen eines Chats mit einem "Entdeckt"-Peer erscheint `_ContactRequestGateScreen`. Eingabe einer Vorstellungsnachricht (optional, max. 500 Zeichen). Versand über ChatProvider.

**Rate-Limit:** Max. 10 Anfragen pro Tag (via SharedPreferences). 30-Tage-Cooldown nach Ablehnung oder Ignorieren durch denselben Peer.

**Empfangen:**  
Eingehende Anfragen erscheinen in `ContactRequestsScreen` (`/contact-requests`) — erreichbar über Badge-Icon in der Kontakte-AppBar und Dashboard-Karte. Aktionen: "Annehmen" (grün), "Ablehnen" (rot), Swipe-to-Dismiss (Ignorieren).

**Gesendete Anfragen:**  
`SentRequestsScreen` (`/contact-requests/sent`) — zeigt gesendete Anfragen mit Status-Chip: "Angenommen" oder "Ausstehend". Abgelehnte/ignorierte Anfragen werden **nicht** angezeigt. Ausstehende Anfragen können abgebrochen werden.

### 3.5 Kontaktanfragen-Gate im Chat

Wenn ein Gesprächspartner nur den Status "Entdeckt" hat, zeigt der Chat-Screen einen Gate-Screen statt des Nachrichtenfelds. Nach Versand der Anfrage wechselt die Ansicht zu "Ausstehend" mit Cancel-Button. Reagiert live auf Status-Änderungen über StreamBuilder.

### 3.6 Blockieren von Kontakten

- Stilles Blockieren: kein Feedback an den Sender
- Blockierte Peers werden aus Gesprächsliste und Radar gefiltert
- Nachrichten von Blockierten werden in ChatProvider verworfen
- Verwaltung: `Einstellungen → Kontakte → Blockierte Kontakte`
- Auch in `ContactDetailScreen` blockierbar

### 3.7 Kontakt-Export

`Einstellungen → Kontakte → Kontakte exportieren`  
Speichert alle Kontakte als JSON-Datei im Dokumente-Verzeichnis.

### 3.8 Profilbild-Sichtbarkeit

Das Profilbild hat eine eigene Sichtbarkeitseinstellung (`VisibilityLevel`):
- Alle
- Kontakte (Standard für neue Nutzer)
- Vertrauenspersonen
- Bürgen
- Privat

Einstellbar in `EditProfileScreen` direkt unter dem Avatar-Bild. Wird in Nostr Kind-0 (`nexus_profile`-Block) gespeichert. Wenn Sichtbarkeit `public` ist, wird das Profilbild auch im `picture`-Feld von Kind-0 veröffentlicht.

---

## 4. Chat & Direktnachrichten

### 4.1 Chat starten

**Wege:**
- `Chat-Tab` → FAB → "Peers in der Nähe" (Radar) oder "Kontakte anzeigen"
- `Chat-Tab` → FAB → "QR-Code scannen"
- Kontaktliste → Kontakt antippen
- Radar-Screen → Peer antippen

### 4.2 Gesprächsliste (ConversationsScreen)

Zwei Tabs (mit `TabController(length: 2)`):

**Tab "Chats":**
- #mesh-Kanal oben angepinnt
- Darunter alle Direktgespräche (`!conv.isGroup`), sortiert nach letzter Nachricht

**Tab "Kanäle":**
- #nexus-global oben angepinnt
- Alle beigetretenen Gruppenkanäle (`conv.isGroup`)
- Ungelesen-Badge im Tab zeigt Summe aller ungelesenen Kanalnachrichten

Swipe zwischen Tabs via `TabBarView`. Goldener Tab-Indikator.

**Kontext-abhängiger FAB:**
- Chats-Tab: "Neue Konversation" (QR, Radar, Kontakte)
- Kanäle-Tab: "Kanal erstellen" + "Kanäle entdecken"

### 4.3 Nachrichtentypen

| Typ | Beschreibung |
|-----|-------------|
| Text | Einfache Textnachricht |
| Bild | JPEG, max. 1024px, Thumbnail-Vorschau |
| Sprachnachricht | AAC 16kHz 32kbps (Android), WAV (Desktop); max. 5 Minuten |
| Broadcast | Öffentliche Nachricht an #mesh oder benannte Kanäle |

### 4.4 Antworten / Zitieren (Reply)

- **Swipe-to-Reply** (nach rechts wischen, >80px) auf eigene und fremde Nachrichten
- **Long-Press-Kontextmenü**: Antworten, Kopieren, Weiterleiten (UI), Löschen
- **Antwort-Banner** über Eingabefeld: goldene Vertikallinie, Absender, Vorschautext, X-Button zum Abbrechen
- **Zitat-Block** in Chat-Bubble: goldene Linie, Absender, Vorschautext, Bild-Platzhalter
- Tippen auf Zitat → scrollt zur Originalnachricht mit Goldflash (1 Sekunde)
- Toast wenn Originalnachricht nicht mehr verfügbar
- Bei Antworten auf Sprachnachrichten: Mikrofon-Icon + "Sprachnachricht" im Zitat-Block

### 4.5 E2E-Verschlüsselung

- **Algorithmen:** X25519 (Schlüsselaustausch) + AES-256-GCM (Nachrichtenverschlüsselung) + HKDF-SHA256
- **Schlüsselaustausch:** Über Nostr Presence (Kind 30078) und Nachrichten-Metadata
- **UI-Indikatoren:**
  - Schloss-Icon in jeder verschlüsselten Nachrichts-Bubble
  - Schloss-Icon in der Gesprächsliste
  - "Ende-zu-Ende verschlüsselt"-Banner in der Chat-AppBar
- **Schlüssel-Verifizierung:** QR-Code + 8×4-Hex-Fingerprint (Signal-Style)
- **Schlüsselwechsel-Warnung:** Erscheint im Chat bei geändertem Public Key des Peers
- **Fallback:** Unverschlüsselt wenn Peer keinen Key hat (mit Warnung)
- Broadcasts bleiben unverschlüsselt (öffentlich by design)

### 4.6 Sprachnachrichten

**Aufnahme:**
- Mikrofon-Button erscheint wenn Eingabefeld leer (wie WhatsApp). Senden-Pfeil wenn Text vorhanden.
- Gedrückt halten auf Mikrofon → Aufnahme startet
- Pulsierender roter Punkt + Zeitanzeige während Aufnahme
- Wischen nach links (>80px) → Aufnahme abbrechen
- Loslassen → Sprachnachricht wird gesendet
- Haptisches Feedback bei Aufnahmestart/-abbruch
- Mikrofon-Berechtigung wird beim ersten Mal angefragt
- BLE-Only-Verbindungen: Sprachnachrichten deaktiviert (Toast-Hinweis)

**Wiedergabe:**
- Sprachnachrichten-Bubble: Play/Pause-Button, 28-Balken-Waveform (deterministisch aus Nachrichten-ID), Dauer, Geschwindigkeitsumschalter 1×/1.5×/2×
- Fortschrittsanzeige: goldene Füllung der Balken
- Nur eine Sprachnachricht gleichzeitig abspielbar (`VoicePlayer`-Singleton)
- E2E-Verschlüsselung: Audio-Base64 wird mit X25519/AES-256-GCM verschlüsselt

### 4.7 Nachrichtensuche

**Globale Suche** — erreichbar über Lupen-Icon in der Gesprächsliste-AppBar:
- Sucht in allen Konversationen (Entschlüsselung in Dart + Filterung auf Klartext)
- Ergebnis zeigt: Absender-Pseudonym (fett), hervorgehobener Suchbegriff (gold), Datum/Uhrzeit, Konversationsname
- Tippen → öffnet Konversation, scrollt zur Nachricht (Goldflash)
- Paginierung: initial 50 Ergebnisse, "Mehr laden"-Button
- Debounce: 300ms nach letzter Tastatureingabe

**In-Chat-Suche** — Lupen-Icon in der Chat-AppBar:
- AppBar wird zum Suchfeld
- Pfeile ↑/↓ zwischen Treffern, "X/N"-Zähler
- Aktueller Treffer: stärkeres Gold-Highlight; andere Treffer: dezentes Gold

### 4.8 #mesh und Broadcast

- `#mesh` ist der automatisch angepinnte lokale BLE/LAN-Broadcast-Kanal
- Nachrichten an `#mesh` sind immer unverschlüsselt (öffentlich)
- Reichweite: nur direkte BLE/LAN-Peers (kein Nostr)

---

## 5. Zellen

Zellen sind die primäre Gemeinschafts- und Governance-Einheit in N.E.X.U.S. Jede Zelle kann maximal **150 Mitglieder** haben (Dunbar-Zahl).

Navigation: `Entdecken-Tab → "Meine Zelle"`-Kachel → `CellHubScreen` (Route: `/cell-hub`)  
Alternative: `Dashboard → Agora-Karte` (wenn noch in keiner Zelle)

### 5.1 Zell-Typen

| Typ | Beschreibung |
|-----|-------------|
| LOCAL (lokal) | Geographisch gebunden; Standort via GPS-Geohash |
| THEMATIC (thematisch) | Interessenbasiert; Kategorie aus festgelegter Liste |

Thematische Kategorien: Umwelt, Technik, Bildung, Tiergerechtigkeit, Ernährung, Gesundheit, Wohnen, Kultur, Wirtschaft, Sonstiges

### 5.2 Beitritts-Modi

| Modus | Beschreibung |
|-------|-------------|
| APPROVAL_REQUIRED | Beitrittsanfrage muss von Gründer/Moderator bestätigt werden |
| INVITE_ONLY | Nur durch direkte Einladung (noch nicht implementiert als separater Flow) |

### 5.3 Mindest-Vertrauensstufe

Beim Erstellen einer Zelle kann der Gründer eine Mindest-Vertrauensstufe für Bewerber festlegen:
- `none` — Keine Anforderung
- `contact` — Bewerber muss Kontakt eines Mitglieds sein
- `trusted` — Bewerber muss Vertrauensperson eines Mitglieds sein

### 5.4 Zell-Rollen (MemberRole)

| Rolle | Beschreibung |
|-------|-------------|
| `founder` (Gründer) | Ersteller der Zelle; höchste Rechte; kann Moderatoren ernennen |
| `moderator` (Moderator) | Kann Beitrittsanfragen verwalten; kann Nachrichten löschen |
| `member` (Mitglied) | Bestätigtes Mitglied |
| `pending` (Ausstehend) | Beitrittsanfrage eingereicht, noch nicht bestätigt |

`isConfirmed` gilt für founder, moderator und member (nicht für pending).  
`canManageRequests` gilt für founder und moderator.

### 5.5 Zelle erstellen

`CellHubScreen` → FAB → `CreateCellScreen`

**Formular-Felder:**
- Name der Zelle (Pflichtfeld)
- Beschreibung (optional)
- Typ: Lokal oder Thematisch
  - Lokal: Standortname, GPS-Geohash (automatisch via Geolocator)
  - Thematisch: Thema, Kategorie (aus Dropdown-Liste)
- Beitrittsmodus: APPROVAL_REQUIRED
- Mindest-Vertrauensstufe: keine / Kontakt / Vertrauensperson
- Wartezeit für Anträge (Tage, Standard: 0)
- Max. Mitglieder (Standard und Maximum: 150)

**Einschränkung:** Zellen können nur von System-Admins und Superadmins erstellt werden (seit Commit 51d4f95).

### 5.6 Zelle beitreten

Im `CellHubScreen` werden entdeckte Zellen angezeigt. Kategorie-Chips filtern die Discovery-Liste. Antippen einer Zelle öffnet ein Info-Popup mit Beschreibung und Mitgliederzahl. "Beitreten"-Button sendet eine Beitrittsanfrage.

### 5.7 Beitrittsanfragen-Workflow

**Einreichen:** Nutzer tippt auf "Beitreten" in der Zell-Übersicht → optionale Nachricht → Versand der Anfrage via Nostr an Gründer/Moderatoren.

**Verwalten** (Gründer/Moderator): `CellScreen → Mitglieder-Tab` oder `CellRequestsScreen` — zeigt eingehende Anfragen mit Pseudonym, Vertrauenskontext und Zellen-Mitgliedschaften des Anfragenden. Aktionen: "Bestätigen" oder "Ablehnen".

### 5.8 Zellen-Innenansicht (CellScreen)

4 Tabs (TabController length: 4):
- **Pinnwand** — angeheftete Informationen
- **Diskussion** — Kanal-ähnlicher Chat für Zellenmitglieder
- **Agora** — Anträge dieser Zelle (leitet weiter zu GovernanceScreen)
- **Mitglieder** — Liste aller bestätigten Mitglieder

### 5.9 Zelle verlassen

`CellScreen` → Drei-Punkte-Menü → "Zelle verlassen"

**Gründer:** Muss zuerst die Gründer-Rolle auf ein anderes bestätigtes Mitglied übertragen. Wenn Gründer das einzige Mitglied ist, kann die Zelle nicht verlassen, sondern nur gelöscht werden.  
**Moderator/Mitglied:** Direktes Verlassen mit Bestätigungsdialog.

Beim Verlassen wird ein Nostr-Event publiziert, das andere Mitglieder informiert. Die Zelle wird lokal in die Tombstone-Liste aufgenommen (erscheint nie wieder in der Discovery).

### 5.10 Zelle löschen

Nur Gründer (und System-Admins/Superadmin) können eine Zelle auflösen. Die Auflösung wird via Nostr an alle Mitglieder propagiert. Aufgelöste Zellen werden dauerhaft tombstoned — auch nach Nostr-Replay-Ereignissen.

### 5.11 Discovery via Nostr

Zellen werden über Nostr Kind-Events (Cell-Announce) veröffentlicht. Der Zellen-Hub zeigt entdeckte Zellen in einer Liste. Die GPS-Position des Nutzers wird genutzt, um lokale Zellen in der Nähe vorzuschlagen (Geohash-Vergleich). Nach dem Verlassen oder dem Auflösen einer Zelle erscheint diese nie wieder in der Discovery-Liste (Tombstone-Mechanismus).

---

## 6. Dorfplatz (Social Feed)

Navigation: `Dorfplatz-Tab` (Index 2 in der Bottom-Navigation, Route `/dorfplatz`)

### 6.1 Drei-Tab-Layout

| Tab | Inhalt |
|-----|--------|
| Kontakte | Beiträge von Kontakten (TrustLevel ≥ contact) |
| Meine Zelle | Beiträge von Zellenmitgliedern |
| Entdecken | Öffentliche Beiträge aller NEXUS-Nutzer |

### 6.2 Beitrag erstellen

`Dorfplatz-Tab` → FAB → `CreatePostScreen`

**Eingabe-Möglichkeiten:**
- Freitext (Pflicht, wenn keine anderen Inhalte vorhanden)
- Bilder (max. 4, JPEG-Komprimierung 1024px / 75%)
- Umfrage (2-6 Optionen, optional Mehrfachauswahl, optionales Ablaufdatum)
- Repost (Verweis auf einen anderen Beitrag)

**Sichtbarkeit** (Auswahl über Bottom Sheet):
- `contacts` — Nur Kontakte
- `cell` — Alle Zellenmitglieder
- `public` — Alle NEXUS-Nutzer

"Posten"-Button ist deaktiviert (ausgegraut) wenn Textfeld leer und keine anderen Inhalte vorhanden.

### 6.3 FeedPostCard — Aufbau

- **Header:** Identicon, Pseudonym, Zeitstempel, Sichtbarkeits-Icon, Drei-Punkte-Menü
- **Repost-Indikator:** Anzeige wenn Beitrag ein Repost ist
- **Textinhalt:** Expandierbar (max. 5 Zeilen eingeklappt)
- **Bild-Grid:** 1 Bild (Vollbreite), 2 Bilder (nebeneinander), 4+ Bilder (Raster)
- **Umfrage-Widget:** Abstimmung + Ergebnis-Balken nach Abstimmung
- **Link-Vorschau:** Automatisch bei URLs
- **Footer:** Emoji-Picker, Reaktions-Badges mit Zähler, Kommentar-Zähler

### 6.4 Reaktionen

- Emoji-Picker im Footer jedes Beitrags
- Reaktionen werden als Emoji-Badge mit Zähler angezeigt
- Eigene Reaktion wird hervorgehoben
- Nochmaliges Tippen = Reaktion entfernen (Toggle)

### 6.5 Kommentare

`PostDetailScreen` — Vollständiger Beitrag + Kommentarbaum (max. 3 Ebenen, goldene Einrücklinie). Fixiertes Kommentar-Eingabefeld unten. Eigene Kommentare können gelöscht werden.

### 6.6 Post-Menü (Drei-Punkte-Menü)

Eigene Beiträge:
- Bearbeiten (nur innerhalb 24 Stunden)
- Sichtbarkeit ändern
- Löschen
- Reposten

Fremde Beiträge:
- Reposten
- Autor stummschalten

### 6.7 Nostr-Integration

| Aktion | Nostr Kind |
|--------|-----------|
| Text-Beitrag | Kind-1 |
| Repost | Kind-6 (NIP-18) |
| Reaktion | Kind-7 (NIP-25) |
| Löschen | Kind-5 (NIP-09) |

Feed-Subscription über `#nexus-dorfplatz`-Tag.

### 6.8 Dorfplatz auf dem Dashboard

Die Dashboard-Karte "Dorfplatz" zeigt:
- Gesamt-Beitragszahl
- Vorschau des neuesten Beitrags
- Reagiert live auf `FeedService.stream`

---

## 7. Kanäle

### 7.1 Grundlagen

Benannte Gruppenkanäle nach NIP-28:
- Kind-40: Kanal erstellen
- Kind-42: Kanalnachricht senden

Auto-Join: `#nexus-global` wird beim ersten Start automatisch beigetreten.

### 7.2 Kanal erstellen

`Chat-Tab → Kanäle-Tab` → FAB → "Kanal erstellen" → `CreateChannelScreen`

**Felder:** Name (beginnt mit #), Beschreibung, Kanal-Modus

**Kanal-Modi** (nur für System-Admins / Superadmin sichtbar):
- `discussion` — Alle Mitglieder können posten (Standard)
- `announcement` — Nur Admins können posten; anderen Nutzern wird das Eingabefeld ausgegraut mit "Nur Admins können hier posten"

### 7.3 Kanal beitreten / entdecken

`Chat-Tab → Kanäle-Tab` → FAB → "Kanäle entdecken" → `JoinChannelScreen`

Über Entdecken-Hub: "Kanäle"-Kachel → `JoinChannelScreen`

### 7.4 Kanal-Tabs in ConversationsScreen

Tab "Kanäle":
- `#nexus-global` immer oben angepinnt
- Weitere Kanäle nach letzter Nachricht sortiert
- Ungelesen-Badge im Tab

### 7.5 Announcement-Kanäle

In Announcement-Kanälen:
- Megafon-Icon + "Ankündigung"-Badge im Kanal-Header
- Eingabefeld für nicht-berechtigte Nutzer ausgegraut ("Nur Admins können hier posten")
- Nur `CHANNEL_ADMIN`, `SYSTEM_ADMIN` und `SUPERADMIN` dürfen posten

### 7.6 Rollen-Badges in Kanalnachrichten

Neben dem Absendernamen in Kanal-Nachrichten werden Rollen-Badges angezeigt:
- Superadmin: Schild + Stern-Icon
- System-Admin: Schild-Icon
- Kanal-Admin: manage_accounts-Icon
- Kanal-Moderator: verified_user-Icon

---

## 8. Anträge & Demokratie (G2 — Liquid Democracy)

### 8.1 Navigation zu Anträgen

**Zugang:**
- `Dashboard → Agora-Karte` (Tipp → `GovernanceScreen`) — nur wenn in mindestens einer Zelle
- `Dashboard → Agora-Karte` → `CellHubScreen` — wenn noch in keiner Zelle
- `Entdecken-Tab → Sphären-Sektion → Agora` → `GovernanceScreen`
- `CellScreen → Agora-Tab`

**Voraussetzung:** Der Nutzer muss bestätigtes Mitglied (MEMBER, MODERATOR oder FOUNDER) in mindestens einer Zelle sein. Andernfalls wird ein Leerzustand mit "Zelle finden"-Button angezeigt.

### 8.2 GovernanceScreen (Agora)

AppBar-Titel: "Agora — Politik & Demokratie"

**Zell-Selektor:** Bei mehreren Zellen erscheint ein Dropdown in der AppBar zum Wechsel zwischen Zellen.

**Drei Tabs:**
- **Aktiv** — Anträge in Status DISCUSSION, VOTING, VOTING_ENDED
- **Abgeschlossen** — Anträge in Status DECIDED, ARCHIVED, WITHDRAWN
- **Meine** — Alle Anträge, die der aktuelle Nutzer erstellt hat

Jeder Antrag in der Liste zeigt: Titel, Status-Badge, Ersteller, Datum, Stimm-Ergebnis (bei DECIDED).

### 8.3 Antrag erstellen

`GovernanceScreen` → FAB (nur sichtbar wenn Zelle ausgewählt) → `CreateProposalScreen`

**Felder:**
- **Titel** (Pflichtfeld)
- **Beschreibung** (Pflichtfeld)
- **Kategorie** (optional, Dropdown):
  - Keine Kategorie
  - Umwelt
  - Finanzen
  - IT
  - Soziales
  - Gesundheit
  - Bildung
  - Sonstiges

Nach "Speichern" wird der Antrag als **ENTWURF (DRAFT)** gespeichert und die Detailansicht öffnet sich direkt.

**Hinweis:** `ProposalType` (SACHFRAGE / VERFASSUNGSFRAGE) existiert im Datenmodell, ist aber im `CreateProposalScreen` noch nicht als UI-Auswahl implementiert — Standardwert ist SACHFRAGE.

### 8.4 Antragstypen (ProposalType)

| Typ | Beschreibung |
|-----|-------------|
| `SACHFRAGE` | Sachliche/faktische Fragestellung (Standard) |
| `VERFASSUNGSFRAGE` | Grundsatz-/Verfassungsfrage |

### 8.5 Antragsstatus und Übergänge

```
DRAFT → DISCUSSION → VOTING → VOTING_ENDED → DECIDED → ARCHIVED
         ↓                                              (nach 30 Tagen)
      WITHDRAWN
```

| Status | Deutsch | Beschreibung |
|--------|---------|-------------|
| `DRAFT` | Entwurf | Nur für Ersteller sichtbar; editierbar |
| `DISCUSSION` | Diskussion | Für alle Zellenmitglieder sichtbar; Diskussions-Posts möglich |
| `VOTING` | Abstimmung | Abstimmung läuft; Abstimmungsende in 7 Tagen |
| `VOTING_ENDED` | Abstimmung beendet | Abstimmungsfrist abgelaufen; Grace Period läuft |
| `DECIDED` | Entschieden | Ergebnis liegt vor; DecisionRecord erstellt |
| `ARCHIVED` | Archiviert | 30 Tage nach Entscheidung automatisch archiviert |
| `WITHDRAWN` | Zurückgezogen | Vom Ersteller zurückgezogen (nur im DRAFT oder DISCUSSION) |

**Übergänge via ProposalScheduler** (alle 5 Minuten + bei App-Resume):
- `VOTING → VOTING_ENDED`: wenn `votingEndsAt` überschritten
- `VOTING_ENDED → DECIDED`: wenn Grace Period abgelaufen (`gracePeriodHours` nach `votingEndsAt`)
- `DECIDED → ARCHIVED`: nach 30 Tagen

### 8.6 Antrag-Detailansicht (ProposalDetailScreen)

Drei Tabs:
- **Details** — Hauptansicht mit Status, Beschreibung, Abstimmungs-Widget (wenn VOTING/VOTING_ENDED), Ergebnis (wenn DECIDED)
- **Diskussion** — `_DiskussionTab` mit Diskussions-Posts
- **Historie** — `_HistorieTab` mit Bearbeitungsverlauf (ProposalEdits)

**Aktionen im Drei-Punkte-Menü (kontextabhängig):**

| Aktion | Verfügbar für | Status-Voraussetzung |
|--------|--------------|---------------------|
| Zur Diskussion stellen | Ersteller | DRAFT |
| Entwurf verwerfen | Ersteller | DRAFT |
| Antrag zurückziehen | Ersteller | DRAFT oder DISCUSSION |
| Abstimmung starten | Ersteller oder Moderator/Gründer | DISCUSSION |
| Archivieren | Alle | DECIDED |

**Bearbeiten-Button (Stift-Icon in AppBar):**  
Sichtbar für Ersteller wenn Status DRAFT oder DISCUSSION.

### 8.7 Abstimmen

**Abstimmungsoptionen (VoteChoice):**
- `YES` (Ja)
- `NO` (Nein)
- `ABSTAIN` (Enthaltung)

**Abstimmungs-Widget im Details-Tab:**
- Drei Buttons: Ja / Nein / Enthaltung
- Optionales Begründungsfeld (Freitext)
- "Stimme abgeben"-Button
- Stimme kann während VOTING geändert werden (neue Stimme ersetzt alte)
- `_myExistingVote` wird aus DB geladen; bei bereits abgestimmten wird vorherige Wahl vorausgefüllt

**Abstimmungsdauer:** 7 Tage ab Start (fest kodiert: `Duration(days: 7)`)

**Grace Period:**  
Standard: `gracePeriodHours = 12` Stunden nach `votingEndsAt`. Während der Grace Period können noch Stimmen abgegeben werden (als VOTE_LATE_ACCEPTED oder VOTE_LATE_REJECTED im Audit-Log).

**Quorum:**  
Standard: `quorumRequired = 0.5` (50% der Zellenmitglieder müssen abgestimmt haben).  
Berechnung: `(ja + nein + enthaltung) / totalMembers`

**Ergebnis-Berechnung (finalizeProposal):**
- `participation < quorumRequired` → `result = "invalid"` (Quorum nicht erreicht)
- `yes > no` → `result = "approved"`
- `no >= yes` → `result = "rejected"` (Gleichstand = Status quo = Nein)

### 8.8 Decision Record

Nach Finalisierung wird ein unveränderlicher `DecisionRecord` erstellt und lokal gespeichert sowie als Nostr Kind-30001 publiziert.

**Inhalt des DecisionRecord:**
- `recordId`, `proposalId`, `cellId`
- `finalTitle`, `finalDescription` (Snapshot des Antragstexts zum Zeitpunkt der Entscheidung)
- `result`: "approved" / "rejected" / "invalid"
- `yesVotes`, `noVotes`, `abstainVotes`
- `participation` (als Dezimalzahl, z.B. 0.75 = 75%)
- `decidedAt` (Zeitstempel)
- `allVotes` (alle Einzelstimmen mit Pseudonym, Wahl, Begründung, Zeitstempel)
- `contentHash` (SHA-256-Hash des Inhalts für Tamper-Evidenz)
- `previousDecisionHash` (Hash des vorherigen DecisionRecord dieser Zelle — Hash-Kette)
- `nostrEventId`

### 8.9 Bearbeitungshistorie (Edit History)

Anträge im Status DISCUSSION können vom Ersteller bearbeitet werden (`ProposalEditScreen`).

Jede Bearbeitung wird als `ProposalEdit` gespeichert mit:
- `editId`, `proposalId`
- `editorDid`, `editorPseudonym`
- `oldTitle`, `newTitle`
- `oldDescription`, `newDescription`
- `editedAt`
- `editReason` (optional)
- `versionBefore`, `versionAfter` (Versionsnummer)

Verlauf einsehbar im Tab "Historie" des `ProposalDetailScreen` → öffnet `EditHistoryScreen`.

**Einschränkung:** Bearbeitung ist nur möglich im Status DRAFT oder DISCUSSION. Nach Abstimmungsstart (`VOTING`) ist keine Bearbeitung mehr möglich.

### 8.10 Audit-Log

Jedes governance-relevante Ereignis wird als `AuditLogEntry` protokolliert.

**Ereignistypen (AuditEventType):**

| Typ | Auslöser |
|-----|---------|
| `PROPOSAL_CREATED` | Antrag wird zu DISCUSSION gestellt |
| `PROPOSAL_EDITED` | Antrag während Diskussion bearbeitet |
| `PROPOSAL_STATUS_CHANGED` | Statusübergang (DISCUSSION→VOTING, VOTING→VOTING_ENDED) |
| `PROPOSAL_WITHDRAWN` | Antrag zurückgezogen |
| `VOTE_CAST` | Neue Stimme abgegeben |
| `VOTE_CHANGED` | Bestehende Stimme geändert |
| `VOTE_LATE_ACCEPTED` | Stimme in Grace Period akzeptiert |
| `VOTE_LATE_REJECTED` | Stimme in Grace Period abgelehnt (nach Finalisierung) |
| `RESULT_CALCULATED` | Ergebnis berechnet, DecisionRecord erstellt |
| `PROPOSAL_ARCHIVED` | Antrag archiviert |

Jeder Eintrag enthält: `entryId`, `proposalId`, `cellId`, `eventType`, `actorDid`, `actorPseudonym`, `timestamp`, `payload` (JSON mit Kontext), optionale `nostrEventId`.

Einsehbar für: alle Mitglieder der Zelle im "Historie"-Tab.

### 8.11 Diskussions-Posts zu Anträgen

Im Tab "Diskussion" des `ProposalDetailScreen` können Zellenmitglieder `ProposalDiscussionMessage`-Posts verfassen. Diese sind Antrag-spezifisch (kein allgemeiner Zellen-Kanal).

### 8.12 Nostr-Synchronisation

| Ereignis | Nostr Kind |
|----------|-----------|
| Antrag erstellen / aktualisieren | Kind-31010 |
| Stimme abgeben | Kind-31011 |
| Decision Record | Kind-31013 |

Retry-Queue für fehlgeschlagene Publizierungen. Wiederholung beim nächsten App-Start oder Netzwerk-Reconnect.

**Hinweis Liquid Democracy / Delegation:** Das Datenmodell (`Vote.isDelegated`, `Vote.delegatedFrom`) enthält Felder für delegierte Stimmen. Diese sind im UI und in der Abstimmungslogik dieser Version noch nicht aktiv implementiert.

### 8.13 Abstimmungs-Berechtigungen nach Rolle

| Aktion | MEMBER | MODERATOR | FOUNDER | SYSTEM_ADMIN | SUPERADMIN |
|--------|--------|-----------|---------|--------------|------------|
| Antrag erstellen | Nein* | Nein* | Nein* | Ja | Ja |
| Antrag bearbeiten | Nur eigene | Nur eigene | Nur eigene | Ja | Ja |
| Antrag zurückziehen | Nur eigene | Nur eigene | Nur eigene | Ja | Ja |
| Abstimmung starten | Nein | Ja (fremde) | Ja (fremde) | Ja | Ja |
| Abstimmen | Ja | Ja | Ja | Ja | Ja |
| Archivieren | Ja | Ja | Ja | Ja | Ja |

*Derzeit können nur System-Admins und Superadmins neue Anträge erstellen (via `CreateProposalScreen` — nur über `GovernanceScreen` erreichbar, der nur Zellenmitgliedern zugänglich ist; Erstellen-Button ist für reguläre Mitglieder deaktiviert — dies ist die aktuelle Implementierungsstand).

---

## 9. Einstellungen

Navigation: `Profil-Tab → Einstellungen` oder direkter Aufruf über Route `/settings`

Die Einstellungen sind in Sektionen unterteilt:

### 9.1 Sektion: Transport

- **Nostr-Netzwerk** → `NostrSettingsScreen` (Relay-Verwaltung, Verbindungsstatus)

### 9.2 Sektion: Benachrichtigungen

- **Benachrichtigungen aktiviert** (Toggle)
- **Vorschau anzeigen** (Nachrichteninhalt in Benachrichtigung)
- **Lautlos-Modus** (nur visuell, kein Ton)
- **Broadcasts benachrichtigen** (Toggle für #mesh und Kanal-Broadcasts)
- **Nicht stören (DND)** — Zeitraum: Von/Bis (Zeitauswahl)

Vollständige Benachrichtigungs-Einstellungen in `NotificationSettingsScreen`.

### 9.3 Sektion: Nachrichten

- **Statistik:** Anzahl gespeicherter Nachrichten + Speicherplatz (ungefähr)
- **Aufbewahrungsdauer** → Bottom Sheet mit Optionen (7 Tage / 30 Tage / 90 Tage / Für immer / etc.)
- **Alle Nachrichten löschen** (mit Bestätigungsdialog)

### 9.4 Sektion: Datensicherung (_BackupSection)

- Aktueller Backup-Status (letztes Backup, Anzahl Dateien)
- **Automatisches Backup** (Toggle)
- **Jetzt sichern** (manueller Backup)
- **Backup wiederherstellen** → `RestoreBackupScreen`

### 9.5 Sektion: Einladungen

- **Einladungscode einlösen** → `RedeemScreen`

### 9.6 Sektion: Kontakte

- **Blockierte Kontakte** — Liste mit Anzahl, Unblockieren möglich
- **Kontakte exportieren** — speichert JSON in Dokumente-Verzeichnis
- **Kontakte importieren** — "Kommt bald – benötigt Datei-Picker" (deaktiviert)

### 9.7 Sektion: Administration (nur für System-Admin / Superadmin sichtbar)

- Rollen-Badge des aktuellen Nutzers
- **System-Admins verwalten** → `AdminManagementScreen`
- **Zellen-Administration** → `AdminCellManagementScreen` (Zellen-Übersicht für Admins)
- **Superadmin übertragen** (nur Superadmin) — mit doppelter Bestätigung

### 9.8 Sektion: Info

- **Unsere Grundsätze** → `PrinciplesContentScreen(readOnly: true)` — Subtitle zeigt "Bestätigt am TT.MM.JJJJ" wenn bestätigt
- **NEXUS OneApp** — About-Dialog (Phase 1a – AETHER Protokoll, Version, Legalese)
- **App-Version: vX.Y.Z** — Versionsnummer aus `package_info_plus`
- **Nach Updates suchen** — prüft GitHub Releases API, zeigt Bottom Sheet bei neuer Version

### 9.9 G2 Debug-Sektion (_G2DebugSection)

Diese Sektion ist für Entwicklungszwecke vorgesehen. Enthält Debug-Buttons für Governance-G2 (z.B. "Force Voting beenden", "Cleanup"). In der Produktion vorhanden, aber als Debug-Bereich gekennzeichnet.

---

## 10. Push-Benachrichtigungen

Benachrichtigungen werden über `flutter_local_notifications` auf Android und Linux ausgegeben. Auf iOS und Windows werden keine Benachrichtigungen angezeigt (`_supported` = nur Android + Linux).

### 10.1 Benachrichtigungs-Trigger

| # | Ereignis | Methode | Konfigurierbar |
|---|---------|---------|----------------|
| 1 | Eingehende Direktnachricht | `showMessageNotification` | Ja (gesamt + DND) |
| 2 | Broadcast / Kanal-Nachricht | `showBroadcastNotification` | Ja (broadcastEnabled) |
| 3 | Chat-Reaktion auf eigene Nachricht | `showGenericNotification` | Ja (gesamt + DND) |
| 4 | Kanal-Reply auf eigene Nachricht | `showGenericNotification` | Ja (gesamt + DND) |
| 5 | Dorfplatz-Like (Reaktion auf eigenen Post) | `showGenericNotification` | Ja (gesamt + DND) |
| 6 | Dorfplatz-Kommentar auf eigenen Post | `showGenericNotification` | Ja (gesamt + DND) |
| 7 | Dorfplatz-Repost des eigenen Beitrags | `showGenericNotification` | Ja (gesamt + DND) |

Zusätzlich interne Governance-Benachrichtigungen (innerhalb der App, via `NotificationService`):
- Neuer Antrag in Zelle (DISCUSSION gestartet)
- Antrag bearbeitet
- Abstimmung gestartet
- Abstimmung entschieden

### 10.2 Benachrichtigungs-Einstellungen

- **Benachrichtigungen gesamt:** An/Aus
- **Nachrichtenvorschau anzeigen:** An/Aus (wenn aus: nur "Neue Nachricht")
- **Lautlos-Modus:** Kein Ton, keine Vibration
- **Broadcast-Benachrichtigungen:** Separat deaktivierbar
- **Nicht stören (DND):** Zeitfenster konfigurierbar (Von/Bis in HH:MM)

---

## 11. Rollen & Berechtigungen

### 11.1 System-Rollen (SystemRole)

| Rolle | Beschreibung |
|-------|-------------|
| `superadmin` | Einziger Gründer; DID aus `assets/config/system.json` geladen; kann alles was `systemAdmin` kann + System-Admins verwalten + Superadmin-Rolle übertragen |
| `systemAdmin` | Ernannt durch Superadmin; mehrere erlaubt; kann Inhalte moderieren, Announcement-Kanäle erstellen, Zellen gründen |
| `user` | Jeder reguläre Nutzer (Standard) |

### 11.2 Kanal-Rollen (ChannelRole)

| Rolle | Beschreibung |
|-------|-------------|
| `channelAdmin` | Ersteller des Kanals; kann alles in diesem Kanal |
| `channelModerator` | Ernannt durch Kanal-Admin; kann Nachrichten löschen und Mitglieder stummschalten |
| `channelMember` | Reguläres Mitglied |

### 11.3 Zell-Rollen (MemberRole)

| Rolle | Beschreibung |
|-------|-------------|
| `founder` | Gründer der Zelle; kann Moderatoren ernennen, Zelle konfigurieren und auflösen |
| `moderator` | Kann Beitrittsanfragen verwalten |
| `member` | Bestätigtes Mitglied |
| `pending` | Beitrittsanfrage ausstehend |

### 11.4 Berechtigungsmatrix (PermissionHelper)

| Berechtigung | USER | SYSTEM_ADMIN | SUPERADMIN |
|-------------|------|-------------|------------|
| `canPostInChannel` | Ja (außer Announcement) | Ja | Ja |
| `canCreateAnnouncementChannel` | Nein | Ja | Ja |
| `canDeleteMessage` | Nur eigene | Ja | Ja |
| `canMuteUser` | Nein | Ja | Ja |
| `canManageSystemAdmins` | Nein | Nein | Ja |
| `canManageChannelModerators` | Nein (nur Channel-Admin) | Ja | Ja |

### 11.5 Nostr Kinds für Rollen

| Aktion | Nostr Kind |
|--------|-----------|
| System-Rollen-Zuweisung | Kind-31001 |
| Kanal-Rollen-Zuweisung | Kind-31002 |

---

## 12. Technische Grundlagen (Kurzübersicht)

### 12.1 Selbstverwaltete Identität

Jeder Nutzer kontrolliert seine eigene Identität vollständig. Die Identität ist ein kryptographisches Schlüsselpaar (Ed25519), das aus einer 12-Wort-Seed-Phrase erzeugt wird. Die öffentlich sichtbare Adresse ist eine DID (Dezentrale Identität) im Format `did:key:z6Mk...`. Niemand außer dem Nutzer selbst kann diese Identität kontrollieren oder löschen.

### 12.2 Ende-zu-Ende-Verschlüsselung

Alle Direktnachrichten werden auf dem Gerät des Absenders verschlüsselt und erst auf dem Gerät des Empfängers entschlüsselt. Kein Server sieht den Inhalt. Die Verschlüsselung nutzt X25519 für den Schlüsselaustausch und AES-256-GCM für die eigentliche Nachrichtenverschlüsselung — beides Post-Quanten-resistente oder -vorbereitete Standards.

### 12.3 Nostr-Protokoll

Nostr ist ein offenes, dezentrales Kommunikationsprotokoll. N.E.X.U.S. nutzt es als Internet-Fallback wenn BLE/LAN nicht verfügbar ist. Nachrichten werden kryptographisch signiert und über öffentliche Relay-Server weitergeleitet. Kein zentraler Betreiber kann Nachrichten zensieren.

### 12.4 BLE/LAN Mesh

Bluetooth Low Energy (BLE) und lokales WLAN-Netzwerk ermöglichen direkte Kommunikation ohne Internet. Innerhalb der Reichweite funktioniert die App auch ohne Mobilfunk oder Internet — ideal für lokale Gemeinschaften, Veranstaltungen und Gebiete mit schlechter Verbindung.

### 12.5 Offline-First / SQLite

Alle Daten (Nachrichten, Kontakte, Zellen, Anträge) werden lokal in einer verschlüsselten SQLite-Datenbank (POD — Personal Online Datastore) gespeichert. Die App funktioniert vollständig offline. Wenn eine Verbindung verfügbar ist, werden Daten synchronisiert. Lokale Daten sind mit AES-256-GCM verschlüsselt, Schlüssel vom persönlichen Seed abgeleitet.

---

## Änderungen seit v0.1.3

Die folgenden nutzersichtbaren Änderungen wurden seit v0.1.3 eingeführt (aus Git-Log und CLAUDE.md):

### v0.1.4 / v0.1.5 (Kernfunktionen)
- **Dorfplatz (Sozialer Feed):** Vollständiger Social-Feed mit Posts, Bildern, Umfragen, Reaktionen, Kommentaren; 3-Tab-Layout (Kontakte / Meine Zelle / Entdecken); Nostr-Integration
- **Profilbild-Sichtbarkeit:** Profilbild hat eigene Sichtbarkeitseinstellung; Standard: nur Kontakte
- **Governance G1 — Zellen-Hub:** Zellen erstellen, beitreten, verwalten; CellScreen mit 4 Tabs (Pinnwand, Diskussion, Agora, Mitglieder); Beitrittsanfragen-Flow
- **GPS-basierter Geohash:** Lokale Zellen verwenden GPS für Standortermittlung
- **Zellen-Discovery via Nostr:** Automatische Entdeckung von Zellen anderer Nutzer
- **Zelle verlassen / Mitglied entfernen:** Gründer-Nachfolge-Pflicht; Nostr-Propagierung

### v0.1.6 (Stabilisierung)
- **Zombie-Zellen-Fix:** Dauerhaftes Tombstoning verhindert Wiedererscheinen gelöschter Zellen
- **Zell-Löschung durch Admin:** Superadmin und System-Admins können beliebige Zellen auflösen
- **Zellen-Innenansicht:** Vollständiger Pinnwand- und Diskussionsbereich pro Zelle
- **Feed-Scroll-Stabilisierung:** Kein Auto-Jump, persistenter ScrollController
- **Benachrichtigungs-Trigger:** Neu für Chat-Reaktionen, Kanal-Replies, Feed-Likes/Kommentare/Reposts

### v0.1.7 (Governance G2 — Aktuelle Version)
- **Liquid Democracy Abstimmungs-Engine (G2):** Vollständiges Abstimmungssystem innerhalb von Zellen
- **Antrag-Lebenszyklus:** DRAFT → DISCUSSION → VOTING → VOTING_ENDED → DECIDED → ARCHIVED / WITHDRAWN
- **Abstimmungs-UI:** Ja/Nein/Enthaltung-Buttons, optionale Begründung, Stimme ändern möglich
- **Grace Period:** 12-Stunden-Puffer nach Abstimmungsende für späte Stimmen
- **Quorum-Prüfung:** Standard 50% der Zellenmitglieder müssen abstimmen
- **Decision Record:** Unveränderlicher, kryptographisch verketteter Entscheidungsdatensatz (Hash-Kette)
- **Audit-Log:** Vollständige Ereignisprotokollierung mit 10 Ereignistypen
- **Bearbeitungshistorie:** Versionierte Edit-Nachverfolgung für Anträge im Diskussionsstatus
- **Diskussions-Posts:** Zellen-Mitglieder können direkt am Antrag diskutieren
- **Nostr-Synchronisation:** Anträge (Kind-31010), Stimmen (Kind-31011), Entscheidungen (Kind-31013)
- **ProposalScheduler:** Automatischer Statusübergang alle 5 Minuten + bei App-Resume
- **Proposals in Anträge umbenannt:** UI-Terminologie einheitlich auf Deutsch
