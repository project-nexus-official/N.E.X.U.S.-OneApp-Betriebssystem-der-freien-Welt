# CLAUDE.md – N.E.X.U.S. OneApp

## ⛔ KRITISCHE ENTWICKLUNGSREGELN — ABSOLUTE VERBOTE

Diese Regeln haben in den letzten Wochen Datenverlust verhindert oder 
verursacht. Sie sind NICHT verhandelbar.

1. **NIEMALS `flutter clean` vorschlagen oder ausführen.**
   `flutter clean` löscht SharedPreferences auf Windows und hat am 
   09.04.2026 Datenverlust verursacht (Tombstones, geclaimte Cells, 
   Founder-Status). Wenn ein Build-Problem `flutter clean` zu erfordern 
   scheint: STOPP, frage nach mehr Logs, suche eine andere Lösung.

2. **NIEMALS `adb uninstall` oder `flutter install` verwenden.**
   Immer `flutter run` für Updates — das behält alle Nutzerdaten.
   `adb uninstall` LÖSCHT den Android Keystore und damit die 
   Identität des Nutzers UNWIEDERBRINGLICH (außer per Seed Phrase).
   Lokale Daten (Kontakte, Nachrichten, Posts) sind dann verloren.

3. **NIEMALS die bestehende Datenbank löschen oder neu erstellen** 
   bei Migrationen. Immer `CREATE TABLE IF NOT EXISTS` und 
   `ALTER TABLE` für Änderungen. Bestehende Tabellen und Daten 
   sind heilig. NIEMALS `DROP TABLE` oder `DELETE FROM` auf 
   bestehende Tabellen.

4. **NIEMALS "Nuclear Wipe", "fresh start", "App-Daten löschen" 
   oder ähnliches als Lösungsweg vorschlagen.** Diese Aktionen 
   haben Datenverlust verursacht. Wenn du unter Druck stehst und 
   einen "Standard-Fix" vorschlagen willst — STOPP. Frage stattdessen 
   nach mehr Logs oder genauer Symptom-Beschreibung.

5. **Immer mit `flutter run` auf dem Gerät testen BEVOR gepusht 
   wird.** Nie ungetestete Builds releasen.

## 🌍 SPRACHE & TERMINOLOGIE (zwingend)

N.E.X.U.S. ist eine Graswurzelbewegung der Menschheitsfamilie. Die 
Sprache der Bewegung ist präzise und nicht verhandelbar.

- **Immer:** "Menschheitsfamilie" — niemals "System", "Gesellschaft" 
  oder "Community" als Synonym
- **Immer:** "N.E.X.U.S." mit Punkten — niemals "NEXUS"
- **Immer:** "Graswurzelbewegung" — niemals "Projekt"
- **Echte Umlaute:** ä, ö, ü, ß — niemals ae/oe/ue/ss in 
  User-facing Strings, Commit-Messages oder Dokumentation
- **Projekt-Begriffe konsequent verwenden:**
  - "Zellen" (nicht Gruppen/Communities für Governance-Einheiten)
  - "Anträge" (nicht Proposals in User-facing Strings; im Code 
    bleibt `Proposal` als Klassenname konsistent)
  - "Pinnwand" / "Diskussion" / "Agora" / "Mitglieder" (Cell-Tabs)
  - "Dorfplatz" (nicht Feed/Schwarzes Brett)
  - "Pioniere" (Telegram-Mitglieder) vs. "Architekten" (Genesis Circle)
- **Code-Kommentare:** Englisch (Effective Dart)
- **UI-Texte und User-facing Strings:** Deutsch mit echten Umlauten

## 🧩 PROAKTIVES LOGIK- & SYNC-PROTOKOLL

1. **Impact Analysis:** Bevor du Code änderst, analysiere alle 
   Abhängigkeiten. Frage dich: "Welche anderen Module verlassen 
   sich auf diese Logik?" Bei Unklarheit: nachfragen statt raten.

2. **Nostr-Synchronisation:** Bei jeder Änderung an Nostr-Events 
   (Kinds, Tags, Signing):
   - Prüfe NIP-Konformität (NIP-01, NIP-04, NIP-09, NIP-25, 
     NIP-28, NIP-33, NIP-44)
   - **NIP-01 e-Tag MUSS 64-Hex Event-ID sein** — keine UUIDs, 
     keine sonstigen Strings. Diese Regel hat am 08.04.2026 einen 
     8-Stunden-Bug-Marathon verursacht. Für Custom-IDs (z.B. 
     `proposal_id`) immer ein Custom-Tag verwenden, nicht den 
     e-Tag missbrauchen.
   - **OK-Handler ist Pflicht:** Jeder `publish()` muss einen 
     OK-Handler haben der die Antwort des Relays auswertet. Ohne 
     OK-Handler werden Relay-Fehler still ignoriert und der 
     Empfänger sieht das Event nie.
   - Replaceable Events (Kind 30000-39999): `d`-Tag und `created_at` 
     korrekt setzen, sonst überschreibt sich nichts.
   - Idempotenz: Simuliere im Kopf "Was passiert wenn dieses Event 
     doppelt oder verzögert eintrifft?" — jeder Handler muss damit 
     umgehen können.

3. **Diagnose vor Fix:** Bei Sync-Bugs IMMER zuerst Raw-Relay-Logging 
   einbauen (`[PUBLISH]`, `[RELAY-RAW]`, `[RELAY-OK]`), testen, 
   Logfiles analysieren — DANN gezielt fixen. Nie raten und 
   spekulativ Code ändern.

4. **Tests (wo Infrastruktur existiert):** Für neue Logik-Verknüpfungen 
   einen Unit-Test in `test/` erstellen. Wenn keine Test-Infrastruktur 
   für den betroffenen Bereich existiert (z.B. Mock-Relay-Tests), 
   dokumentiere das als TODO im Commit und teste manuell auf beiden 
   Geräten. Niemals Tests erfinden die nicht laufen können.

5. **Zustands-Validierung:** Prüfe bei UI-Änderungen ob der State 
   (Provider/Service) auch bei Verbindungsabbrüchen (Offline-First) 
   konsistent bleibt. In-Memory-State und DB-State müssen synchron 
   gehalten werden — eine reine DB-Änderung ohne State-Update führt 
   zu UI-Bugs (Lehre aus dem Zombie-Cell-Bug).

## 🛡️ SECURITY & SAFETY AUDIT (vor jedem Commit)

1. **Key-Safety:** Suche aktiv nach hardcoded Keys, API-Tokens oder 
   unverschlüsselter Speicherung von sensitiven Daten. Private Keys 
   gehören in den Android Keystore / Windows DPAPI, niemals in 
   SharedPreferences oder SQLite-Klartext.

2. **Daten-Verschlüsselung:** Prüfe ob private Daten vor dem 
   Speichern in die SQLite-DB (`PodDatabase`) verschlüsselt werden 
   (AES-256-GCM mit aus Seed abgeleitetem Key). Die `enc`-Spalte 
   in den Tabellen ist Pflicht für alle privaten Inhalte.

3. **Nomenklatur (für neuen Code im AETHER-Kontext):** Verwende 
   projektkonforme Begriffe statt Finanz-Vokabular wenn neue 
   Wert-Module gebaut werden:
   - ✅ `energyToken`, `vitaBalance`, `valueExchange`, `timeEquivalent`
   - ❌ `money`, `payment`, `price`, `wallet`, `bank`
   - **Wichtig:** Bestehende Code-Stellen (z.B. die `wallet`-Route 
     im ShellRoute) werden NICHT umbenannt ohne expliziten Auftrag. 
     Diese Regel gilt nur für NEUEN Code in AETHER- und 
     Wert-Modulen.

4. **Input-Validierung:** Checke alle eingehenden Nostr-Events auf 
   schädliche Payloads bevor sie verarbeitet werden — ungültige 
   Signaturen, übergroße Payloads, malformed JSON, fehlende 
   Pflicht-Tags. Niemals Daten aus dem Netz unvalidiert in die 
   DB schreiben.

## 🤖 SELBSTSTÄNDIGKEITS-MODUS

- Wenn eine Aufgabe unklar ist oder logische Lücken im Plan bestehen: 
  **Stoppe und frage nach**, anstatt Vermutungen im Code zu 
  implementieren. Es ist okay zu sagen "Ich brauche mehr Informationen 
  bevor ich das umsetzen kann."

- Schlage proaktiv Verbesserungen vor wenn du siehst dass eine 
  bestehende Implementierung gegen das dezentrale Paradigma verstößt 
  (zentrale Server, Single Points of Failure, ungerechtfertigte 
  Vertrauensannahmen).

- **Wenn du unter Druck stehst und einen Standard-Tipp vorschlagen 
  willst der gegen die Verbote oben verstößt — STOPP.** Frage 
  stattdessen nach mehr Logs oder genauer Symptom-Beschreibung. 
  Lieber langsam und sicher als schnell und mit Datenverlust.

## 🧪 TEST-WORKFLOW (wichtig: Joachim liest keine Live-Logs)

Joachim hat keinen Programmierhintergrund und kann Logs NICHT live 
im Terminal verfolgen. Alle Tests müssen Logfiles erzeugen die er 
hochladen kann:

- **Standard-Befehl:** `flutter run > test-name.txt 2>&1` 
  (Android über USB) oder `flutter run -d windows > test-name.txt 2>&1`
- **Bei mehreren Test-Läufen:** separate Dateinamen verwenden 
  (`test-1-vorher.txt`, `test-2-nachher.txt`)
- **Beide Geräte parallel testen:** Handy + Windows haben oft 
  unterschiedliche Logs — beide Files brauchen wir
- **Diagnose-Logs immer mit aussagekräftigen Präfixen:** 
  `[CELL-CREATE]`, `[PUBLISH]`, `[RELAY-OK]`, `[ZOMBIE-V3]` etc. — 
  damit Joachim und du die richtigen Stellen schnell findet
- **Eine Sache pro Prompt:** Nicht mehrere Bugs gleichzeitig fixen. 
  Erst diagnostizieren, dann fixen, dann verifizieren, dann nächster 
  Bug. Sammelfixes haben in der Vergangenheit zu Eskalations-Spiralen 
  geführt.

## Projekt-Übersicht
Die N.E.X.U.S. OneApp ist eine dezentrale, zensurresistente App für 
die Menschheitsfamilie. Sie implementiert das AETHER-Protokoll mit 
drei Wertformen:
- VITA Ꝟ (fließend, für Alltag, mit Demurrage 0,5%/Monat)
- TERRA ₮ (fest, für Infrastruktur, kein Demurrage)
- AURA ₳ (immateriell, Reputation, nicht transferierbar)

## Architektur-Entscheidungen
- **Frontend:** Flutter (Dart) – eine Codebase für Android + Windows 
  (iOS und Linux später)
- **Identität:** BIP-39 Seed Phrase, Ed25519/SLIP-0010, did:key 
  W3C Standard
- **Verschlüsselung:** X25519/NIP-44 (E2E Chat), AES-256-GCM 
  (Storage), HKDF-SHA256
- **Transport (heute):** Nostr (primär), BLE Mesh, LAN Discovery
- **Transport (geplant):** WiFi Direct, LoRa-Gateway-Integration 
  für Pioniere, perspektivisch Reticulum als Meta-Transport-Layer
- **Daten:** SQLite (`PodDatabase`) lokal, AES-256-GCM verschlüsselt, 
  Nostr-Events für Sync
- **Offline-First:** Kernfunktionen müssen ohne Internet laufen
- **Blockchain (Phase 1c):** Substrate (Rust) – eigene souveräne 
  Chain für AETHER

## Projekt-Phasen
- **Phase 1a:** Fundament + Identität + Chat ✅ (komplett)
- **Phase 1b:** Governance — G1 (Zellen, Anträge) ✅, G2 (Liquid 
  Democracy) ⏳ in Arbeit, G3-G5 später
- **Phase 1c:** AETHER Wallet + Lokaler Marktplatz
- **Phase 2:** Care-System + Sphären-Plugins (Asklepios, Paideia, 
  Demeter, Hestia)

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
  - Navigation umstrukturiert: **Home · Chat · Dorfplatz · Entdecken · Profil** (Governance- und Wallet-Tab entfernt)
  - Wallet-Route (`/wallet`) bleibt im ShellRoute für zukünftige Nutzung erhalten
  - App startet auf `/home` statt `/chat`; Onboarding-Redirect → `/home`
  - **Header**: Zeitabhängige Begrüßung ("Guten Morgen/Tag/Abend, [Pseudonym]") + Datum auf Deutsch
  - **Radar-Karte** (prominent, 200px hoch, goldener Rahmen):
    - Mini-Radar-Animation (150px, `_MiniRadarPainter` mit `dart:math` sin/cos)
    - "Lokal: X Peers" (BLE/LAN) | "NEXUS-Netzwerk: X Nodes" unten
    - Tipp → öffnet vollen `RadarScreen` (rootNavigator)
  - **Feature-Karten**: Nachrichten, Kanäle, Kontakte, Agora, Dorfplatz
    - Jede Karte: Icon-Kreis (gold), Titel, Status-Subtitle, optionale Preview, Badge
    - Agora-Karte: Titel "Agora — Politik & Demokratie", Tipp → GovernanceScreen (rootNavigator push)
    - Dorfplatz-Karte: Titel "Dorfplatz", Subtitle "Bald verfügbar", Tipp → `/dorfplatz` Tab
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

- **Rollen-Hierarchie (komplett)**:
  - **SystemRole Enum**: `SUPERADMIN` (Gründer, hartcodiert via DID), `SYSTEM_ADMIN` (ernannt), `USER` (Default)
  - **ChannelRole Enum**: `CHANNEL_ADMIN` (Ersteller), `CHANNEL_MODERATOR`, `CHANNEL_MEMBER`
  - **ChannelMode Enum**: `discussion` (alle posten) / `announcement` (nur Admins)
  - **SystemConfig** (`lib/core/config/system_config.dart`): Lädt Superadmin-DID aus `assets/config/system.json` (PLACEHOLDER_DID); nach Transfer aus SharedPreferences (`nexus_superadmin_did`); `forceForTest()` für Unit-Tests
  - **assets/config/system.json**: PLACEHOLDER_DID – Joachim trägt seine eigene DID ein; Datei bleibt im Repo (mit Platzhalter), nicht in `.gitignore`
  - **RoleService** Singleton (`lib/services/role_service.dart`): `init()`, `isSuperadmin()`, `isSystemAdmin()`, `getSystemRole()`, `getChannelRole()`; `grantSystemAdmin/revokeSystemAdmin/transferSuperadmin` (Superadmin-exklusiv); `grantChannelModerator/revokeChannelModerator` (Kanal-Admin oder System-Admin)
  - **PermissionHelper** (`lib/core/roles/permission_helper.dart`): Reine Funktionen – `canPostInChannel`, `canCreateAnnouncementChannel`, `canDeleteMessage`, `canMuteUser`, `canManageSystemAdmins`, `canManageChannelModerators`
  - **DB v6-Migration**: Neue Tabellen `system_roles` (did, role, granted_by, granted_at) und `channel_roles` (channel_id, did, role, granted_by, granted_at)
  - **GroupChannel.channelMode**: Neues Feld, serialisiert als `"channelMode"` im JSON-Blob; `GroupChannel.create()` akzeptiert `channelMode` Parameter
  - **Nostr Kinds**: `roleAssignment = 31001` (System-Rollen), `channelRoleAssignment = 31002` (Kanal-Rollen)
  - **UI – Kanal-Header**: Megafon-Icon + "Ankündigung"-Badge bei Announcement-Kanälen
  - **UI – Eingabefeld**: Ausgegraut mit "Nur Admins können hier posten" in Announcement-Kanälen für nicht-berechtigte Nutzer
  - **UI – Rollen-Badges**: Neben Absendernamen in Kanal-Nachrichten (Superadmin: Schild+Stern, Admin: Schild, Kanal-Admin: manage_accounts, Mod: verified_user)
  - **UI – Kanal erstellen**: Kanal-Modus-Selektor (Diskussion/Ankündigung) nur sichtbar für System-Admin/Superadmin
  - **UI – Einstellungen**: "Administration"-Sektion (nur für System-Admin/Superadmin sichtbar) mit Rollen-Badge, "System-Admins verwalten", "Superadmin übertragen" (mit doppelter Bestätigung)
  - **AdminManagementScreen** (`lib/features/settings/admin_management_screen.dart`): Liste aller System-Admins, FAB zum Ernennen, "Entfernen"-Button mit Bestätigungsdialog
  - **Init**: `RoleService.instance.init()` in `initServicesAfterIdentity()` nach DB-Öffnung
  - Tests: 32 Tests in `test/services/role_service_test.dart`

- **Kontaktanfrage-System (komplett)**:
  - **ContactRequest** Modell (`lib/features/contacts/contact_request.dart`): id, fromDid, fromPseudonym, fromPublicKey, fromNostrPubkey, message (max 500 Zeichen), receivedAt, status (pending/accepted/rejected/ignored), decidedAt, isSent; `generateId()` (UUID v4), JSON-Serialisierung
  - **DB v8-Migration**: Neue Tabelle `contact_requests` (id, from_did, is_sent, status, received_at, enc); `upsertContactRequest()`, `listContactRequests()`, `updateContactRequestStatus()` in PodDatabase
  - **ContactRequestService** Singleton (`lib/services/contact_request_service.dart`):
    - `load()`: Lädt alle Anfragen aus DB
    - `sendRequest()`: Sendet Anfrage mit Rate-Limit (max 10/Tag via SharedPrefs `nexus_cr_today_count/date`) und 30-Tage-Cooldown nach Ablehnung/Ignorieren; doppelte Anfragen an selbe DID werden abgefangen
    - `handleIncomingRequest()`: Verarbeitet eingehende `contact_request`-Nachrichten; ignoriert blockierte Absender und aktive Cooldowns; de-dupliziert mehrfache Anfragen
    - `handleAcceptance()`: Verarbeitet `contact_request_accepted`-Nachrichten; fügt Kontakt hinzu und markiert Anfrage als angenommen
    - `acceptRequest()`: Nimmt Anfrage an, fügt Kontakt via `addContactFn` hinzu, sendet Bestätigung via `sendConfirmFn`
    - `rejectRequest()` / `ignoreRequest()`: Stille Ablehnung/Ignorieren (kein Feedback an Absender)
    - `stream`: Broadcast-Stream für Live-Updates
  - **Chat-Integration**: `_onMessageReceived` in ChatProvider routet `contact_request` und `contact_request_accepted` Typen; `sendContactRequest()` und `acceptContactRequest()` Methoden in ChatProvider
  - **Nostr-Getter**: `NostrTransport.localNostrPubkeyHex` Getter hinzugefügt
  - **_ContactRequestGateScreen** (in `conversation_screen.dart`): Wird angezeigt wenn Peer nur `discovered`-Status hat oder unbekannt ist; zeigt Formular zum Senden einer Anfrage (mit Vorstellungstext, max 500 Zeichen) oder "Ausstehend"-Ansicht nach Versand; reagiert live auf Status-Änderungen via StreamBuilder
  - **ContactRequestsScreen** (`lib/features/contacts/contact_requests_screen.dart`): Eingehende Anfragen mit Identicon, Pseudonym, Nachricht, Datum; "Annehmen" (grün) / "Ablehnen" (rot) / Swipe-to-Dismiss (Ignorieren)
  - **SentRequestsScreen** (`lib/features/contacts/sent_requests_screen.dart`): Gesendete Anfragen mit Status-Chip (Angenommen/Ausstehend); zeigt nie Ablehnung/Ignorieren
  - **ContactsScreen**: Badge-Button mit Zähler für offene Anfragen in AppBar (person_add_alt_1-Icon)
  - **DashboardScreen**: Kontakte-Karte zeigt Anfragen-Zähler im Subtitle und als Badge; lauscht auf `ContactRequestService.stream`
  - **Router**: `/contact-requests` → `ContactRequestsScreen`, `/contact-requests/sent` → `SentRequestsScreen`
  - **Init**: `ContactRequestService.instance.load()` in `initServicesAfterIdentity()` nach `ContactService.instance.load()`
  - Tests: 28 Tests in `test/features/contacts/contact_request_test.dart`

- **Navigation-Restrukturierung (komplett)**:
  - Bottom-Navigation: **Home · Chat · Dorfplatz · Entdecken · Profil**
  - Governance-Tab entfernt; Agora-Screen (`GovernanceScreen`) weiterhin erreichbar via Dashboard-Karte und Entdecken → Sphären (rootNavigator push, keine Bottom-Nav)
  - `DorfplatzScreen` (`lib/features/dorfplatz/dorfplatz_screen.dart`): Platzhalter-Screen, Route `/dorfplatz` im ShellRoute
  - Route `/governance` außerhalb ShellRoute (kein Bottom-Nav, für Deep-Link-Kompatibilität)
  - **Entdecken-Hub** neu strukturiert:
    - Obere Kacheln (5): Kontakte · Kanäle · Meine Zelle (Phase 2) · Marktplatz (Phase 1c) · Einstellungen
    - Entfernt: Care, Agora-Politik, Schwarzes Brett
    - Sphären-Sektion (5): Agora (aktiv, gold, → GovernanceScreen) · Asklepios (Gesundheit & Fürsorge, Phase 3) · Paideia (Phase 3) · Demeter (Phase 3) · Hestia (Phase 3)
  - GovernanceScreen AppBar: "Agora — Politik & Demokratie"
  - Desktop-Sidebar: Dorfplatz statt Governance; Care aus Sphären entfernt (in Asklepios integriert)

- **Dorfplatz – Sozialer Feed (komplett)**:
  - **Datenmodell** (`lib/features/dorfplatz/feed_post.dart`): `FeedVisibility` (contacts/cell/public), `PollOption`, `Poll`, `LinkPreview`, `FeedPost`, `FeedComment`, `generateFeedId()` (UUID v4)
  - **DB v9-Migration**: Neue Tabellen `feed_posts` (id, author_did, visibility, created_at, nostr_event_id, enc, is_deleted), `feed_comments` (id, post_id, author_did, created_at, enc, is_deleted), `feed_mutes` (author_did, muted_at)
  - **PodDatabase v9**: `insertFeedPost`, `updateFeedPost`, `softDeleteFeedPost`, `listFeedPosts` (limit/offset/authorDid), `countFeedPosts`, `insertFeedComment`, `softDeleteFeedComment`, `listFeedComments`, `muteAuthor`, `unmuteAuthor`, `getMutedAuthors`
  - **FeedService** (`lib/features/dorfplatz/feed_service.dart`): Singleton; `load()`, `createPost()`, `getPostsForTab()`, `loadMore()`, `getPostsByAuthor()`, `handleIncomingPost()`, `deletePost()`, `editPost()` (24h-Fenster); `getComments()`, `addComment()`, `deleteComment()`; `getReactions()`/`toggleReaction()` (reuse message_reactions table); `voteInPoll()`; `muteAuthor()`/`unmuteAuthor()`; `stream` (Broadcast); `totalPostCount`
  - **Nostr-Integration**: `publishFeedEvent()` in NostrTransport; Kind-1 (Text-Posts), Kind-6 (NIP-18 Reposts), Kind-7 (NIP-25 Reactions), Kind-5 (NIP-09 Deletion); Feed-Subscription auf `#nexus-dorfplatz` Tag; `onFeedPost` Stream; ChatProvider verdrahtet `FeedService` mit Publisher + Incoming-Handler
  - **FeedPostCard** (`lib/features/dorfplatz/feed_post_card.dart`): `_Header` (Identicon, Pseudonym, Zeitstempel, Sichtbarkeits-Icon, Drei-Punkte-Menü), `_RepostIndicator`, `_ContentText` (expandierbar, max 5 Zeilen), `_ImageGrid` (1/2/4+ Bilder), `_PollWidget` (Abstimmung + Ergebnis-Balken), `_LinkPreviewCard`, `_Footer` (Emoji-Picker, Reaktions-Badges, Kommentar-Zähler)
  - **DorfplatzScreen** (`lib/features/dorfplatz/dorfplatz_screen.dart`): 3-Tab-Layout (Kontakte | Meine Zelle | Entdecken), FAB → CreatePostScreen, Pull-to-Refresh, Pagination (20 Posts), Post-Menü (Bearbeiten/Löschen/Repost/Stumm-schalten)
  - **CreatePostScreen** (`lib/features/dorfplatz/create_post_screen.dart`): Autor-Zeile, Sichtbarkeits-Selector (BottomSheet), Textfeld (autofocus), Bild-Picker (max 4, JPEG-Komprimierung 1024px/75%), Umfrage-Editor (2–6 Optionen, Mehrfachauswahl, Ablaufdatum), Repost-Formular; "Posten"-Button (gold, disabled wenn leer)
  - **PostDetailScreen** (`lib/features/dorfplatz/post_detail_screen.dart`): Vollständiger Post + verschachtelter Kommentarbaum (max 3 Ebenen, goldene Einrücklinie), Antwort-Banner, fixiertes Kommentar-Eingabefeld, eigene Kommentare löschbar
  - **Dashboard**: Dorfplatz-Karte zeigt Post-Zähler und Preview des neuesten Beitrags; lauscht auf `FeedService.stream`
  - **Init**: `FeedService.instance.load()` in `initServicesAfterIdentity()` in `main.dart`
  - Tests: 31 Tests in `test/features/dorfplatz/feed_service_test.dart`

- **Profilbild-Sichtbarkeit (komplett)**:
  - `profileImage` hat wie alle anderen Profilfelder eine `VisibilityLevel`-Einstellung (Alle/Kontakte/Vertrauenspersonen/Bürgen/Privat)
  - **Default** für neue Nutzer: `contacts` (vorher implizit `public`)
  - **EditProfileScreen**: Sichtbarkeits-Picker direkt unter dem Avatar-Bild (Icon + Label, tippbar → gleicher Dropdown wie andere Felder)
  - **`Contact.profileImageVisibility`** Getter: liest `nexusProfile['profileImageVisibility']`, Fallback `public` (Rückwärtskompatibilität)
  - **`Contact.visibleProfileImage`** Getter: gibt `profileImage` nur zurück wenn `trustLevel.allowedVisibility.contains(profileImageVisibility)`, sonst `null` → Identicon
  - **`ContactService.resolveVisibleProfileImage(did)`**: Convenience-Helper für Call-Sites ohne direktes Contact-Objekt
  - **Nostr Kind-0**: `picture`-Feld nur wenn Sichtbarkeit `public`; `profileImageVisibility` immer in `nexus_profile`-Block (Kind-0-Empfänger kennen die Stufe)
  - **Angewendet auf**: Konversationsliste, Kontaktliste, Kontakt-Details, Dorfplatz Feed-Posts, Dorfplatz Kommentare
  - Tests: 21 Tests in `test/features/profile/profile_image_visibility_test.dart`

- **Governance G1: Zellen-Hub und Proposals (komplett)**:
  - **Datenmodell** (`lib/features/governance/`):
    - `Cell` – Zelle mit `CellType` (LOCAL/THEMATIC), `JoinPolicy` (APPROVAL_REQUIRED/INVITE_ONLY), `MinTrustLevel` (NONE/CONTACT/TRUSTED), `proposalWaitDays`, Dunbar-Limit (max 150), `isNew`/`isFull` Getter
    - `CellMember` – Mitgliedschaft mit `MemberRole` (FOUNDER/MODERATOR/MEMBER/PENDING), `isConfirmed`, `canManageRequests`
    - `CellJoinRequest` – Beitrittsanfrage mit Status (PENDING/APPROVED/REJECTED), `isPending`
    - `Proposal` – Governance-Proposal mit `ProposalScope` (CELL/FEDERATION/GLOBAL), `ProposalStatus` (DRAFT/DISCUSSION/VOTING/DECIDED/ARCHIVED), Deadlines, Quorum
  - **DB v10-Migration**: Neue Tabellen `cells`, `cell_members`, `cell_join_requests`, `proposals` (alle AES-verschlüsselt)
  - **PodDatabase**: `upsertCell/listCells/deleteCell`, `upsertCellMember/listCellMembers/deleteCellMember`, `upsertCellJoinRequest/listCellJoinRequests/listMyCellJoinRequests/updateCellJoinRequestStatus`, `upsertProposal/listProposals/deleteProposal`
  - **CellService** Singleton (`lib/features/governance/cell_service.dart`): `load()`, `createCell()`, `updateCell()`, `leaveCell()`, `sendJoinRequest()`, `handleIncomingJoinRequest()`, `approveRequest()`, `rejectRequest()`, `promoteModerator()`, `meetsMinTrustLevel()`, `stream` (Broadcast)
  - **ProposalService** Singleton (`lib/features/governance/proposal_service.dart`): `load()`, `createProposal()`, `publishProposal()`, `proposalsForCell()`, `activeProposalsForCell()`, `myProposals()`, automatische Status-Advancement (DISCUSSION→VOTING→DECIDED→ARCHIVED)
  - **Screens**:
    - `CellHubScreen` – "Meine Zelle": Leerzustand (Entdecken/Gründen), Gefüllt (Meine Zellen + Discovery mit Kategorie-Chips)
    - `CreateCellScreen` – Formular: Typ, Standort/Thema/Kategorie, Beitrittspolitik, Vertrauensstufe, Wartezeit, Max-Mitglieder
    - `CellInfoScreen` – Zellendetails, Mitgliederliste, Founder-Aktionen (Moderator-Beförderung), Verlassen
    - `CellRequestsScreen` – Beitrittsanfragen verwalten (Bestätigen/Ablehnen), Vertrauens-Kontext, Zellen-Mitgliedschaften des Anfragenden
    - `GovernanceScreen` (Agora) – Tabs Aktiv/Abgeschlossen/Meine, Zell-Selektor bei mehreren Zellen, Leerzustand mit "Zelle finden"-Button
    - `CreateProposalScreen` – Titel, Beschreibung, Scope (CELL aktiv / FEDERATION+GLOBAL disabled), Domäne, Diskussions-/Abstimmungsdauer, Quorum; Entwurf oder Veröffentlichen
    - `ProposalDetailScreen` – Status, Timeline, Abstimmungs-Placeholder (G2)
  - **Integration**:
    - Entdecken-Hub: "Meine Zelle" Kachel aktiviert (→ `CellHubScreen`)
    - Dashboard-Karte "Agora": Zeigt echte Daten (aktive Proposals, Beitrittsanfragen, Zellen-Anzahl); Tipp → Agora wenn in Zelle, Zellen-Hub wenn nicht
    - `initServicesAfterIdentity()`: `CellService.load()` + `ProposalService.load()`
    - Router: `/cell-hub` Route hinzugefügt
  - Tests: 33 Tests in `test/features/governance/cell_service_test.dart`, 29 Tests in `test/features/governance/proposal_service_test.dart`

## Aktueller Fokus
- **Automatisches lokales Backup-System (komplett)**:
  - **BackupService** Singleton (`lib/services/backup_service.dart`):
    - Verschlüsselung: AES-256-GCM mit SHA-256(seed64 || "nexus-backup-v1") → 32-Byte-Schlüssel
    - Gesichert: Kontakte, Kanal-Mitgliedschaften, Zellen-Mitgliedschaften, Profil, Grundsätze-Status, Benachrichtigungseinstellungen
    - NICHT gesichert: Seed Phrase / Private Keys, Nachrichten, Bilder, Sprachnachrichten
    - Automatisch alle 24h mit Hash-Vergleich (überspringt wenn keine Änderungen)
    - Maximal 3 Backups, älteste werden automatisch gelöscht
    - Speicherort: Android – `getExternalStorageDirectory()/nexus_backups/`; Windows/andere – Documents/nexus_backups/
    - Dateiname: `nexus_backup_YYYYMMDD_HHMMSS.enc`
  - **BackupSetupScreen** (`lib/features/onboarding/backup_setup_screen.dart`): Einmalig nach Grundsätze-Flow
  - **RestoreBackupScreen** (`lib/features/onboarding/restore_backup_screen.dart`): Automatisch nach Seed-Phrase-Wiederherstellung
  - **Merge-Logik**: Bestehende Kontakte/Kanäle/Zellen werden NICHT überschrieben; nur fehlende werden ergänzt
  - **Einstellungen**: Neuer Abschnitt "Datensicherung" in `settings_screen.dart`
  - **Dashboard-Banner**: `_BackupReminderBanner` wenn Backup noch nicht eingerichtet
  - **Router**: `/backup-setup` Route + Redirect nach Principles; `/onboarding/restore-backup` Route
  - `PrinciplesService.restoreFromBackup()`, `ContactService.addContactFromBackup()`, `GroupChannelService.restoreFromBackup()`, `CellService.restoreFromBackup()` hinzugefügt
  - Tests: 31 Tests in `test/services/backup_service_test.dart`
  - Onboarding-Flow (neu): Seed Phrase → Nickname → Grundsätze → Backup-Einrichtung → Dashboard
  - Restore-Flow (neu): Seed-Phrase-Eingabe → Backup-Suche → Wiederherstellung → Dashboard

>>> PHASE 1b: Governance G1 abgeschlossen – G2 (Liquid Democracy Abstimmung) als nächstes <

## Release-Prozess

Vor jedem Release folgende Schritte in dieser Reihenfolge:

1. **Version hochzählen** in `pubspec.yaml`:
```yaml
   version: X.Y.Z+B   # z.B. 0.1.8+8
```
   Format: `major.minor.patch+buildNumber`

2. **Version im Inno Setup Skript aktualisieren:**
   `installer\windows_setup.iss` → `#define AppVersion`

3. **Build erstellen:**
```bash
   flutter build apk --release          # Android
   flutter build windows --release      # Windows
```

4. **Testen auf beiden Plattformen** bevor commit/push.

5. **Commit + Push:**
```bash
   git add pubspec.yaml installer/windows_setup.iss
   git commit -m "chore: bump version to vX.Y.Z"
   git push origin master:main
```

6. **Windows Installer erstellen:**
```bash
   installer\build_installer.bat
```
   Voraussetzung: Inno Setup 6 installiert (Standard-Pfad).
   Output: `installer\Output\Setup_NexusOneApp_vX.Y.Z.exe`

7. **GitHub Release erstellen:**
   - Tag: `vX.Y.Z-alpha` (z.B. `v0.1.8-alpha`)
   - Release-Titel: `N.E.X.U.S. OneApp vX.Y.Z`
   - APK als Asset hochladen: `nexus-vX.Y.Z.apk`
   - Windows-Installer hochladen: `Setup_NexusOneApp_vX.Y.Z.exe`
   - Release Notes auf Deutsch verfassen (mit echten Umlauten 
     und N.E.X.U.S. mit Punkten)

Der Update-Checker der App prüft diesen GitHub Release automatisch.
Für Windows sucht er nach einem `.exe`-Asset, dann `.zip` als Fallback.

## Code-Standards
- Dart/Flutter: Effective Dart Style Guide
- Tests: Wo Test-Infrastruktur existiert, jede neue Funktion mit 
  Unit-Tests; sonst manueller Test auf beiden Geräten dokumentieren
- Sprache: Code und Kommentare auf Englisch, UI-Texte auf Deutsch 
  mit echten Umlauten
- Commit-Messages: Conventional Commits (`feat:`, `fix:`, `docs:`, 
  `chore:`, `debug:`)
- Git: `git push origin master:main`

## Befehle
- `flutter run > log.txt 2>&1` – App starten mit Logfile
- `flutter run -d windows > log.txt 2>&1` – Windows-Build mit Log
- `flutter test` – Tests laufen lassen (wo vorhanden)
- `flutter build apk --release` – Android Release-Build
- `flutter build windows --release` – Windows Release-Build

## Design-Prinzipien
1. **"Protokoll, nicht Plattform"** – wir bauen einen Standard, 
   keine geschlossene App
2. **"Killer-App zuerst"** – Chat und Governance müssen funktionieren 
   bevor Ökonomie kommt
3. **"Offline-First"** – Kernfunktionen müssen ohne Internet laufen
4. **"So einfach wie WhatsApp"** – Komplexität gehört in den 
   Hintergrund
5. **"Diagnose vor Fix"** – Bei Bugs erst loggen, dann verstehen, 
   dann fixen. Niemals raten.

## Selbst-Verifikation nach jeder Implementierung

Nach JEDER Code-Änderung — vor dem Commit — folgende
Schritte zwingend ausführen:

1. flutter analyze
   → Muss 0 Fehler und 0 Warnings zeigen
   → Bei Fehlern: sofort fixen, nicht committen

2. flutter test
   → Darf keine bestehenden Tests brechen
   → Bei Fehlern: sofort fixen, nicht committen

3. Manuelle Code-Prüfung:
   → Jede State-Änderung: notifyListeners() aufgerufen?
   → Jeder neue StreamController: dispose() vorhanden?
   → Jeder neue Provider-Wert: via context.watch() oder
     Consumer abonniert?
   → Jede neue Subscription: wird sie beim App-Start
     aufgebaut und beim Beenden geschlossen?

4. Erst wenn alle Punkte grün: git add + commit

Diese Regel gilt für ALLE Prompts — auch wenn der
Prompt es nicht explizit erwähnt.