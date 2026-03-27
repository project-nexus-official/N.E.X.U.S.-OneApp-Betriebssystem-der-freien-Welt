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

## Aktueller Fokus
>>> PHASE 1a: Fundament + Identität (in Fertigstellung) <<<

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
