# CLAUDE.md – NEXUS OneApp

## Projekt-Übersicht
Die NEXUS OneApp ist eine dezentrale, zensurresistente App für die Menschheitsfamilie.
Sie implementiert das AETHER-Protokoll mit drei Wertformen:
- VITA Ꝟ (fließend, für Alltag, mit Demurrage 0,5%/Monat)
- TERRA ₮ (fest, für Infrastruktur, kein Demurrage)
- AURA ₳ (immateriell, Reputation, nicht transferierbar)

## Architektur-Entscheidungen
- Frontend: Flutter (Dart) – eine Codebase für iOS + Android + Desktop
- Blockchain: Substrate (Rust) – eigene souveräne Chain
- Chat-Protokoll: Inspiriert von BitChat – BLE Mesh + Nostr als Internet-Fallback
- Daten: Solid PODs für persönliche Datensouveränität
- Offline-First: SQLite + CRDTs (Automerge) für lokale Datenhaltung
- Verschlüsselung: Noise Protocol (E2E), Post-Quanten ready

## Projekt-Phasen
Phase 1a: Fundament + Identität + BLE Mesh-Chat (Killer-App #1)
Phase 1b: Governance (Liquid Democracy)
Phase 1c: AETHER Wallet + Lokaler Marktplatz
Phase 2: Care-System + Sphären-Plugins

## Implementierter Feature-Stand (Phase 1a)

### Abgeschlossen:
- **BLE/LAN/Nostr Transport** – Bidirektionale Peer-Discovery und Messaging
- **Nachrichtenpersistenz** – SQLite (pod_messages), verschlüsselt mit AES-256-GCM, Reload nach Neustart
- **Chat UI** – ConversationsScreen (Postfach), ConversationScreen (Direkt-Chat), RadarScreen
- **Nachrichtentypen** – Text, Bilder (JPEG, max 1024px, Thumbnail), Emoji-Picker
- **Aufbewahrungseinstellungen** – Global und pro Konversation
- **Kontaktverwaltung (komplett)**:
  - `ContactsScreen` – Suche, Filter-Chips (Alle/Kontakte/Vertrauenspersonen/Bürgen), Trust-Badges
  - `ContactDetailScreen` – Vertrauensstufe ändern, Notizen bearbeiten, Selective Disclosure
  - Vertrauensstufen: Entdeckt → Kontakt → Vertrauensperson → Bürge (mit sortWeight)
  - Blockier-System (stilles Blockieren, lokal, kein Feedback an Sender)
  - Blockierte Peers aus Gesprächsliste + Radar gefiltert, Nachrichten in ChatProvider verworfen
  - Kontakt-Export als JSON (path_provider → Dokumente)
  - Blockierte Kontakte in Einstellungen verwaltbar
- **Chat-Integration**:
  - Trust-Badge in Gesprächsliste-Tiles und Chat-Header
  - Tap auf Chat-Header → Kontakt-Detailansicht
  - Unbekannte-Peer-Banner mit "Hinzufügen"-Button
  - Radar zeigt bekannte Kontakte mit Trust-Badge und Pseudonym
- **Kontakte Mobile-Navigation (3 Zugangspfade)**:
  - Profil-Tab: "Meine Kontakte"-Karte mit Anzahl, direkt unter den Profildaten
  - Entdecken-Hub: Aktive "Kontakte"-Kachel (goldener Rahmen, kein "Coming Soon")
  - Chat-Tab FAB: Bottom Sheet mit QR-Code, Peers in der Nähe, Kontakte anzeigen
  - Alle Pfade nutzen `rootNavigator: true` → keine Bottom-Nav sichtbar
- **E2E-Verschlüsselung (komplett)**:
  - X25519-Schlüssel aus Ed25519-Seed abgeleitet (HKDF-SHA256)
  - AES-256-GCM Nachrichtenverschlüsselung mit HKDF-Schlüssel
  - Schlüsselaustausch über Nostr Presence + Nachrichten-Metadata
  - UI-Indikatoren: Schloss-Icon in Nachrichten und Gesprächsliste
  - "Ende-zu-Ende verschlüsselt" Banner in Chat-Header
  - Schlüssel-Verifizierung: QR-Code + 8×4-Hex-Fingerprint (Signal-Style)
  - Schlüsselwechsel-Warnung im Chat
  - Fallback: unverschlüsselt wenn Peer keinen Key hat (mit Warnung)
  - Broadcasts bleiben unverschlüsselt (öffentlich by design)
- **Antworten / Zitieren (komplett)**:
  - Swipe-to-Reply (rechts wischen) auf eigene und fremde Nachrichten
  - Long-Press Kontextmenü: Antworten, Kopieren, Weiterleiten (UI), Löschen
  - Antwort-Banner über Eingabefeld mit Goldlinie, Absender, Vorschau, X-Button
  - Zitat-Block in Chat-Bubble: Goldlinie, Absender, Vorschautext, Bild-Placeholder
  - Tippen auf Zitat → scrollt zur Originalnachricht mit Goldflash (1 Sek.)
  - Toast wenn Originalnachricht nicht mehr verfügbar
  - Reply-Daten in metadata (reply_to_id/sender/preview/image), alle Transports
  - Verschlüsselte Antworten zeigen Klartext im Zitat
- **Sprachnachrichten (komplett)**:
  - Mikrofon-Button erscheint wenn Eingabefeld leer, Senden-Pfeil wenn Text vorhanden (wie WhatsApp)
  - Gedrückt halten auf Mikrofon → Aufnahme startet (AAC 16kHz 32kbps mono auf Android, WAV auf Desktop)
  - Pulsierender roter Punkt + Zeitanzeige während Aufnahme
  - Nach links wischen (>80px) → Aufnahme abbrechen
  - Loslassen → Sprachnachricht wird gesendet (max. 5 Minuten)
  - Haptisches Feedback bei Aufnahmestart/-abbruch
  - Mikrofon-Berechtigung wird beim ersten Mal angefragt
  - BLE-Only Verbindungen: Sprachnachrichten deaktiviert mit Toast-Hinweis
  - Sprachnachrichten-Bubble: Play/Pause-Button, 28-Balken-Wellenform (deterministisch aus Nachrichten-ID), Dauer, Geschwindigkeitswechsel 1×/1.5×/2×
  - Fortschrittsanzeige während Wiedergabe (goldene Füllung der Balken)
  - Nur eine Sprachnachricht gleichzeitig abspielbar (`VoicePlayer` Singleton)
  - E2E-Verschlüsselung: Audio-Base64 wird mit X25519/AES-256-GCM verschlüsselt
  - Empfangene Sprachnachrichten: Base64-Dekodierung → Temp-Datei → Wiedergabe
  - Eigene Aufnahmen: Wiedergabe direkt aus lokalem Pfad (in metadata gespeichert)
  - Antworten auf Sprachnachrichten: Mikrofon-Icon + "Sprachnachricht" im Zitat-Block
  - Konversationsliste: "🎤 Sprachnachricht" als Vorschau
  - Benachrichtigungen: "🎤 Sprachnachricht" als Preview
  - Suche: Sprachnachrichten von In-Chat-Textsuche ausgeschlossen; in Global-Suche als "🎤 Sprachnachricht" angezeigt
  - 32 Unit-Tests in `voice_message_test.dart`
  - Pakete: `record: ^5.1.2`, `audioplayers: ^6.1.0`
- **Nachrichtensuche (komplett)**:
  - Globale Suche (`MessageSearchScreen`) erreichbar über Lupen-Icon in Konversationsliste-AppBar
  - Sucht in allen Konversationen: Entschlüsselung in Dart + case-insensitiver Filter auf Klartext-Body
  - Suchergebnisse zeigen: Absender-Pseudonym (fett), hervorgehobener Suchbegriff (gold), Datum/Uhrzeit, Konversationsname
  - Tipp auf Ergebnis → öffnet Konversation und scrollt zur gefundenen Nachricht (Goldflash)
  - Paginierung: initial 50 Ergebnisse, "Mehr laden"-Button
  - Debounce: 300ms nach letzter Tastatureingabe
  - `HighlightedText` Widget: hebt Suchbegriff in Text mit goldenem Hintergrund hervor
  - In-Chat-Suche (`ConversationScreen`): Lupen-Icon in AppBar → AppBar wird zum Suchfeld
  - Navigation: Pfeile ↑/↓ zwischen Treffern, "X/N" Zähler
  - Aktueller Treffer: stärkeres Gold-Highlight, andere Treffer: dezentes Gold-Highlight
  - Inline-Highlighting in Chat-Bubble: Suchbegriff im Nachrichtentext hervorgehoben
  - 21 Unit-Tests in `message_search_test.dart`
- **QR-Code Kontakt-Scanner (komplett)**:
  - Eigener QR-Code im Profil enthält jetzt vollständiges JSON: `{type, did, pseudonym, publicKey (X25519), nostrPubkey}`
  - Neuer `QrScannerScreen`: Vollbild-Kameraansicht mit goldenem Scan-Rahmen (abgerundete Ecken)
  - Scanner ist erreichbar über: Profil-Screen ("Kontakt scannen" Button), Chat-FAB ("QR-Code scannen"), Kontakte-FAB ("QR-Code scannen")
  - Nach Scan: Bottom Sheet mit Identicon, Pseudonym, DID, Buttons "Als Kontakt hinzufügen" / "Nachricht senden" / "Abbrechen"
  - Kontakt wird direkt auf TrustLevel.contact gesetzt (Face-to-Face = volle Vertrauensstufe)
  - X25519 Public Key und Nostr Public Key werden beim Hinzufügen gespeichert → E2E sofort möglich
  - Duplikat-Erkennung: zeigt "Bereits in Kontakten" mit aktueller Stufe + "Zum Kontakt"-Button
  - Windows/Linux Fallback: Kein Kamera-Scanner → manuelles Eingabefeld für QR-JSON oder bare DID
  - `NostrTransport.registerDidMapping()`: Registriert DID↔Nostr-Pubkey direkt nach Scan → DMs sofort sendbar
  - `Contact.nostrPubkey` neues Feld (in DB als JSON-Blob, kein Schema-Update nötig)
  - `ContactService.addContactFromQr()`: Neu-Kontakt oder Upgrade bestehenden mit Keys
  - `ContactService.setNostrPubkey()`: Setzt Nostr-Pubkey für bekannten Kontakt
  - Route: `/qr-scanner` (außerhalb ShellRoute, kein Bottom-Nav)
  - Paket: `mobile_scanner: ^6.0.0` (Android, iOS, macOS; Windows Fallback)
  - Android: Kamera-Berechtigung in AndroidManifest eingetragen
  - Tests: 24 Tests in `qr_scanner_test.dart`
  - `QrContactPayload` (pure model in `lib/features/contacts/qr_contact_payload.dart`): `tryParse()` validiert type, did:key:-Prefix, Pseudonym; `toJsonString()` generiert das QR-Format
- **Anzeigename-Fix + Nostr Kind-0 (komplett)**:
  - **Root-Cause**: `_UnknownPeerBanner` rief `ContactService.addContact(did, peerPseudonym)` auf, wobei `peerPseudonym` bereits ein DID-Fragment war (letzten 12 Zeichen) → Kontakt dauerhaft mit falschem Namen gespeichert
  - **Fix**: Zentrale `ContactService.getDisplayName(did)` Funktion mit Fallback-Kette:
    1. Kontakt-Pseudonym (wenn nicht ein DID-Fragment)
    2. Live-Peer aus `TransportManager.instance.peers` (korrekt, aber ephemer)
    3. Letzte 12 Zeichen der DID (letzter Ausweg)
  - `ContactService.updatePseudonymIfBetter(did, pseudonym)`: Aktualisiert gespeicherten Pseudonym nur wenn neuer Name kein DID-Fragment ist
  - `ConversationService.getConversations()`: Nutzt jetzt `getDisplayName()` statt eigenem Fallback
  - `ConversationScreen` AppBar: Zeigt jetzt live `getDisplayName()` statt statischem `widget.peerPseudonym`
  - `_UnknownPeerBanner`: Ermittelt echten Namen per `getDisplayName()` vor dem Speichern + Anzeigen
  - **Nostr Kind-0 (NIP-01 Metadata)**:
    - `NostrKind.metadata = 0` in `nostr_event.dart`
    - Beim Start: Eigenes Profil als Kind-0 publizieren (`name`, `about: "DID: ..."`)
    - Subscription auf Kind-0 Events von bekannten Kontakten (kombiniert aus `Contact.nostrPubkey` und `_didToNostrPubkey`)
    - `_handleMetadataEvent`: Aktualisiert Kontakt-Pseudonym via `updatePseudonymIfBetter()`
    - Presence-Handler: Aktualisiert Kontakt-Pseudonym auch aus Presence-Events (Kind 30078)
  - Tests: 10 Tests in `display_name_test.dart`
- **Nostr Catch-Up (verpasste Nachrichten, komplett)**:
  - Letzter Nachrichten-Timestamp in SharedPreferences gespeichert
  - Beim App-Start: Nostr-Subscriptions starten ab diesem Timestamp (minus 60s Puffer)
  - Default: letzte 24 Stunden falls kein gespeicherter Timestamp
  - Duplikat-Erkennung via `message_id` Spalte in `pod_messages` (DB v3)
  - `insertMessage()` prüft vor jedem Insert ob ID bereits existiert → silent skip
  - Presence-Subscription bleibt immer bei "letzte 5 Minuten" (keine Catch-Up nötig)
  - DMs und Broadcasts beide mit Catch-Up
  - **Sprachnachrichten-Catch-Up (Fix)**:
    - Bug: `MessageEncryption._pad` nutzte 2-Byte Längenpräfix (max 65535 Bytes); Base64-Audio >~12s überläuft das → `encrypt()` gab silent `null` zurück
    - Fix: 4-Byte big-endian Längenpräfix in `_pad`/`_unpad` (unterstützt bis ~4 GB); `_nextPadLength` nicht mehr auf 65536 geclampt
    - Fix: `sendVoice` Null-Encryption-Fallthrough: Transport-Msg setzt `encrypted: true` jetzt nur wenn Verschlüsselung tatsächlich erfolgreich war
    - Fix: `_cacheVoiceAudio` speichert empfangenes Audio permanent in App-Documents-Verzeichnis (verhindert Verlust beim Temp-Bereinigung)
    - Limitation: Öffentliche Nostr-Relays (Größenlimit ~32–128 KB) speichern große Voice-Events ggf. nicht → Catch-Up über Relay nur für kurze Nachrichten zuverlässig; Live-Weiterleitung funktioniert immer
    - Tests: 15 Tests in `voice_catchup_test.dart`, 2 neue Großpayload-Tests in `encryption_test.dart`

- **Benannte Gruppenkanäle (komplett)**:
  - `GroupChannel` Modell: id, name (#teneriffa), description, createdBy, nostrTag, joinedAt
  - `GroupChannelService` Singleton: `load()`, `createChannel()`, `joinChannel()`, `leaveChannel()`, `isJoined()`, `findByName()`, `allDiscovered`, `addDiscoveredFromNostr()`, `ensureDefaults()`
  - DB v4-Migration: `group_channels` Tabelle (verschlüsselt wie andere Tabellen)
  - `PodDatabase`: `upsertChannel()`, `listChannels()`, `deleteChannel()`
  - `NostrKind.channelCreate = 40`, `NostrKind.channelMessage = 42` (NIP-28)
  - `NostrTransport`: `subscribeToChannel()`, `unsubscribeFromChannel()`, `publishChannelCreate()`, Kind-40 Discovery-Subscription, `_handleChannelCreateEvent()`, `_handleChannelMessageEvent()`, `onChannelAnnounced` Stream
  - `_sendBroadcast()` nutzt Kind-42 für non-mesh Kanäle, Kind-1 für #mesh
  - `ChatProvider`: `sendToChannel()`, `_initChannels()`, Channel-Routing in `_onMessageReceived()`, `_channelAnnouncedSub`
  - `Conversation.isGroup` getter (id starts with '#'), `peerDidFrom()` handles '#'-IDs
  - `ConversationService`: Group-Channel-Zweig in `getConversations()`
  - UI: `ChannelConversationScreen`, `CreateChannelScreen`, `JoinChannelScreen`
  - `ConversationsScreen`: FAB "Kanal erstellen" + "Kanal beitreten", `#`-Icon für Kanal-Tiles
  - Auto-Join: `#nexus-global` beim ersten Start via `ensureDefaults()`
  - Tests: 17 Tests in `test/features/chat/group_channel_test.dart`

- **ConversationsScreen – Segmented Tabs (komplett)**:
  - `TabController(length: 2)` mit `SingleTickerProviderStateMixin`
  - Tab 0 "Chats": #mesh angepinnt + alle DM-Konversationen (`!conv.isGroup`)
  - Tab 1 "Kanäle": alle beigetretenen Gruppenkanäle (`conv.isGroup`), #nexus-global immer oben angepinnt
  - Sortierung Kanäle-Tab: #nexus-global first → dann nach `lastMessageTime` desc
  - Ungelesen-Badge im Kanäle-Tab: Summe aller `unreadCount` über Kanal-Konversationen
  - Kontextabhängiger FAB: Chats-Tab → "Neue Konversation" (QR, Radar, Kontakte); Kanäle-Tab → "Kanal erstellen" + "Kanäle entdecken"
  - Leerzustände: `_EmptyChatsState` (mit Radar-Button), `_EmptyChannelsState` (mit "Kanäle entdecken"-Button)
  - Swipe zwischen Tabs via `TabBarView`; Tab-Tap mit `TabBar` (gold indicator)
  - Kanal-Discovery auch im Entdecken-Hub: neue "Kanäle"-Kachel (gold, aktiv) → navigiert zu `JoinChannelScreen` via `rootNavigator: true`
  - Tests: 19 Tests in `test/features/chat/conversations_tabs_test.dart`

- **Dashboard – Startbildschirm (komplett)**:
  - `DashboardScreen` ist der neue Default-Startbildschirm (Route `/home`, Index 0)
  - Navigation umstrukturiert: **Home · Chat · Governance · Entdecken · Profil** (Wallet-Tab entfernt)
  - Wallet-Route (`/wallet`) bleibt im ShellRoute für zukünftige Nutzung erhalten
  - App startet auf `/home` statt `/chat`; Onboarding-Redirect → `/home`
  - **Header**: Zeitabhängige Begrüßung ("Guten Morgen/Tag/Abend, [Pseudonym]") + Datum auf Deutsch
  - **Radar-Karte** (prominent, 200px hoch, goldener Rahmen):
    - Mini-Radar-Animation (150px, `_MiniRadarPainter` mit `dart:math` sin/cos)
    - "Lokal: X Peers" (BLE/LAN) | "NEXUS-Netzwerk: X Nodes" unten
    - Tipp → öffnet vollen `RadarScreen` (rootNavigator)
  - **Feature-Karten**: Nachrichten, Kanäle, Kontakte, Governance
    - Jede Karte: Icon-Kreis (gold), Titel, Status-Subtitle, optionale Preview, Badge
    - Governance-Karte: Platzhalter-Text "Hier werdet ihr gemeinsam Entscheidungen treffen."
  - **Coming-Soon-Karten** (halbe Breite, 2er-Reihe, ausgegraut):
    - Wallet · Marktplatz — kein onTap, Opacity 0.45
  - **Responsive**: Mobile = volle Breite; Desktop ≥800px = 2-Spalten-Grid für Feature-Karten
  - **`NodeCounterService`** (`lib/features/dashboard/node_counter_service.dart`):
    - Singleton; trackt Nostr-Peers (eindeutige DIDs) über 7-Tage-Fenster in SharedPreferences
    - Hört auf `TransportManager.onPeersChanged`, prunt stale Einträge
    - 30-Minuten-Refresh-Timer; `countStream` für Live-Updates
    - Init in `initServicesAfterIdentity()` + in `DashboardScreen.initState()`
  - **Hilfsfunktionen** (top-level, testbar): `dashboardGreeting(int hour)`, `dashboardFormattedDate(DateTime)`
  - Tests: 32 Tests in `test/features/dashboard/dashboard_test.dart`

- **Grundsätze-Flow (komplett)**:
  - `PrinciplesService` Singleton (`lib/services/principles_service.dart`):
    - `load()`: Liest `principles_seen`, `principles_accepted`, `principles_accepted_at` aus SharedPreferences
    - `accept()`: Setzt `hasSeen=true`, `isAccepted=true`, speichert ISO-8601-Timestamp
    - `skip()`: Setzt `hasSeen=true`, `isAccepted=false` — kein Timestamp
    - Wird in `main()` vor dem Router geladen (nach `IdentityService.init()`)
  - **Screen 1** (`principles_intro_screen.dart`): Ruhiger Eingangsscreen, Fade-In 1s, Gold-Button "Ich bin bereit" → Screen 2
  - **Screen 2** (`principles_content_screen.dart`): PageView mit 4 Seiten:
    - Seite 1: Titel + Einleitung + Säule 1 (Do No Harm)
    - Seite 2: Säulen 2 (Transparenz) + 3 (Subsidiarität) als Gold-Karten
    - Seite 3: 5 unveräußerliche Rechte als Gold-Bullet-Points
    - Seite 4: Bekenntnis + Pakt
    - Fortschrittsanzeige (4 Punkte, aktiver Punkt gold), Zurück-Pfeil ab Seite 2
    - `readOnly=true` für Settings-Ansicht: letzter Button heißt "Schließen" (kein Commit-Screen)
  - **Screen 3** (`principles_commitment_screen.dart`): Zwei Checkboxen (animiert, Gold-Akzent)
    - "Ich trete ein" nur aktiv wenn BEIDE Checkboxen gesetzt; pulsiert einmal beim Aktivwerden
    - Tipp → `accept()` + `go('/home')`
    - "Später zurückkehren" → `skip()` + `go('/home')` (zeigt Dashboard-Banner)
  - **Router-Redirect**: `hasSeen=false` → automatisch `/principles/intro` (gilt auch für bestehende Nutzer nach App-Update)
  - **Dashboard-Reminder-Banner** (`_PrinciplesReminderBanner`):
    - Erscheint wenn `!isAccepted && !_principlesReminderDismissed` (session-level Dismiss via X-Button)
    - Gold-Umrandung, Scroll-Icon, "Jetzt lesen"-Button → `go('/principles/intro')`
    - Verschwindet permanent nach Bestätigung
  - **Einstellungen**: Neuer Eintrag "Unsere Grundsätze" (Info-Sektion) → `PrinciplesContentScreen(readOnly: true)`
    - Subtitle: "Bestätigt am TT.MM.JJJJ" wenn bestätigt, sonst generischer Text
  - Onboarding `_CompleteStep` navigiert jetzt korrekt zu `/home` (statt `/chat`); Router übernimmt Weiterleitung
  - Tests: 32 Tests in `test/features/onboarding/principles_test.dart`

- **Automatischer Update-Checker (komplett)**:
  - `UpdateService` Singleton (`lib/services/update_service.dart`):
    - `startPeriodicCheck()`: Hintergrund-Timer, max. ein API-Call pro 6 Stunden (Rate-Limit via SharedPreferences `nexus_last_update_check`)
    - `checkNow()`: Sofortprüfung ohne Rate-Limit (für "Nach Updates suchen"-Button)
    - `dismissForSession()`: Blendet Banner bis zum nächsten Kaltstart aus
    - `skipVersion(version)`: Speichert übersprungene Version in SharedPreferences `nexus_skipped_version` → nie wieder anzeigen
    - `updateStream`: Broadcast-Stream für Live-Updates (Banner erscheint sofort wenn Update gefunden)
  - GitHub API: `GET https://api.github.com/repos/project-nexus-official/oneapp/releases/latest`
  - Versions-Vergleich: `parseVersion()` + `isNewer()` (top-level, testbar) — versteht `v0.1.1`, `v0.1.1-alpha`, `0.1.3+3`
  - Platform-Asset: `.apk` für Android, `.zip` für Windows; Fallback: `html_url` (GitHub Release-Seite)
  - **Dashboard-Banner** (`_UpdateBanner`): Goldener Rahmen, zwischen Header und Radar-Karte, Tipp → Bottom Sheet
  - **Bottom Sheet** (`lib/shared/widgets/update_bottom_sheet.dart`):
    - "Jetzt herunterladen" (Gold, prominent) → öffnet URL im Browser (`url_launcher`)
    - "Später" → `dismissForSession()`
    - "Version X überspringen" → `skipVersion()`
    - Release Notes (max. 500 Zeichen aus GitHub-Body)
  - **Einstellungen** (`_AppVersionSection`):
    - "App-Version: vX.Y.Z" (aus `package_info_plus`)
    - "Nach Updates suchen" Button → `checkNow()` → Toast oder Bottom Sheet
  - Neue Abhängigkeiten: `http: ^1.2.0`, `package_info_plus: ^8.0.0`, `url_launcher: ^6.3.0`
  - Android: `<queries>` für `https`-Schema in AndroidManifest.xml ergänzt
  - Tests: 26 Tests in `test/services/update_service_test.dart`

- **App-Einladungsfunktion (komplett)**:
  - `InvitePayload` – base64url-JSON-Kodierung mit Code, DID, Pseudonym, X25519-Key, Nostr-Key, Ablaufdatum (30 Tage)
  - `InviteRecord` – lokale Speicherung mit Einlösestatus (`redeemedByPseudonym`)
  - `InviteService` Singleton (`lib/services/invite_service.dart`):
    - `generateInviteCode()`: Generiert 8-Zeichen-Code aus ambiguity-freiem Alphabet, speichert lokal, optional Nostr-Publish
    - `redeemEncoded()`: Validiert Ablauf, verhindert Selbst-Einlösung, fügt Einlader als Kontakt hinzu, sendet Benachrichtigungs-DM
    - `markRedeemed()`: Setzt `redeemedByPseudonym` und persistiert
    - `buildDeepLink()`: `nexus://invite?c=NEXUS-XXXX-XXXX&d=<base64url>`
    - `buildShareText()`: Fertige Share-Nachricht mit Code, Ablaufdatum, Download-Links
  - Code-Format: `NEXUS-XXXX-XXXX` (Display), `XXXXXXXX` (intern), Alphabet ohne I/O/0/1
  - `InviteScreen` (`lib/features/invite/invite_screen.dart`): QR-Code des Deep-Links, Code-Anzeige mit Kopier-Button, Share-Sheet, Einladungs-Liste mit Status
  - `RedeemScreen` (`lib/features/invite/redeem_screen.dart`): Code-Eingabefeld, Validierung, Erfolgs-Ansicht mit "Zum Dashboard"-Button
  - **Integration**:
    - Dashboard-Karte "Freunde einladen" mit ausstehenden Einladungen als Subtitle
    - Kontakte-FAB: "Zur App einladen" als neuer Eintrag im Bottom Sheet
    - Profil-Screen: "Freund einladen"-Button unter QR-Code
    - Einstellungen: Neuer Abschnitt "Einladungen" mit "Einladungscode einlösen"
    - Router: `/invite` → `InviteScreen`, `/invite/redeem?c=...` → `RedeemScreen`
  - Tests: 25 Tests in `test/features/invite/invite_service_test.dart`

## Aktueller Fokus
>>> PHASE 1a: Fundament + Identität (in Fertigstellung) <<<

## Release-Prozess

Vor jedem Release folgende Schritte in dieser Reihenfolge:

1. **Version hochzählen** in `pubspec.yaml`:
   ```yaml
   version: X.Y.Z+B   # z.B. 0.1.4+4
   ```
   Format: `major.minor.patch+buildNumber`

2. **Build erstellen**:
   ```bash
   flutter build apk --release          # Android
   flutter build windows --release      # Windows
   ```

3. **Commit + Push**:
   ```bash
   git add pubspec.yaml
   git commit -m "chore: bump version to vX.Y.Z"
   git push origin master:main
   ```

4. **Windows Installer erstellen** (optional, empfohlen):
   ```bash
   installer\build_installer.bat
   ```
   Voraussetzung: [Inno Setup 6](https://jrsoftware.org/isdl.php) installiert (Standard-Pfad).
   Output: `installer\Output\Setup_NexusOneApp_vX.Y.Z.exe`

   Versionsnummer im Skript aktualisieren: `installer\windows_setup.iss` → `#define AppVersion`

5. **GitHub Release erstellen**:
   - Tag: `vX.Y.Z` (z.B. `v0.1.4`)
   - Release-Titel: `NEXUS OneApp vX.Y.Z`
   - APK als Asset hochladen: `nexus-vX.Y.Z.apk`
   - Windows-Installer hochladen: `Setup_NexusOneApp_vX.Y.Z.exe` *(bevorzugt)*
   - Windows-ZIP als Asset hochladen: `nexus-vX.Y.Z.zip` *(Fallback)*
   - Release Notes auf Deutsch verfassen

Der Update-Checker der App prüft diesen GitHub Release automatisch.
Für Windows sucht er nach einem `.exe`-Asset, dann `.zip` als Fallback.

## Code-Standards
- Dart/Flutter: Effective Dart Style Guide
- Tests: Jede neue Funktion braucht Unit-Tests
- Sprache: Code und Kommentare auf Englisch, UI-Texte auf Deutsch
- Commit-Messages: Conventional Commits (feat:, fix:, docs:)

## Befehle
- flutter run – App starten
- flutter test – Tests laufen lassen

## Design-Prinzipien
1. "Protokoll, nicht Plattform" – wir bauen einen Standard, keine geschlossene App
2. "Killer-App zuerst" – Chat muss funktionieren bevor Ökonomie kommt
3. "Offline-First" – Kernfunktionen müssen ohne Internet laufen
4. "So einfach wie WhatsApp" – Komplexität gehört in den Hintergrund
