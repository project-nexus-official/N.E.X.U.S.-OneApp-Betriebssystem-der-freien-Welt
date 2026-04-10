# N.E.X.U.S. OneApp

### Das Cockpit der Souveränität — Eine dezentrale App für die Menschheitsfamilie

![Version](https://img.shields.io/badge/version-v0.1.8--alpha-gold)
![Lizenz](https://img.shields.io/badge/lizenz-AGPL%20v3-blue)
![Plattform](https://img.shields.io/badge/plattform-Android%20%7C%20Windows-lightgrey)

---

> ⚠️ **Rechtliche Hinweise & Haftungsausschluss**  
> Diese Software befindet sich in aktiver Alpha-Entwicklung. Vor der Nutzung bitte den vollständigen **[DISCLAIMER.md](DISCLAIMER.md)** lesen. Die Nutzung erfolgt auf eigene Verantwortung.

---

## Was ist die OneApp?

Die N.E.X.U.S. OneApp ist eine dezentrale Kommunikations- und Selbstverwaltungs-App — ohne zentralen Server, ohne Konzernkontrolle, ohne Zensur. Sie ist Schritt für Schritt darauf ausgelegt, WhatsApp durch souveränen Chat, Banken durch das AETHER-Protokoll und Parlamente durch Liquid Democracy zu ersetzen.

Der gesamte Quellcode ist Open Source (AGPL v3). Alle Nachrichten sind Ende-zu-Ende-verschlüsselt. Du besitzt deine Identität, deine Daten und deine Schlüssel — niemand sonst.

Den vollständigen Bauplan des N.E.X.U.S.-Projekts findest du auf **[nexus-terminal.org](https://nexus-terminal.org)**.

---

## Was funktioniert bereits? (v0.1.8-alpha)

| Bereich | Feature |
|---|---|
| **Identität** | Self-Sovereign Identity via Seed Phrase (BIP-39), DID (W3C-Standard), Pseudonym |
| **Chat** | Ende-zu-Ende-verschlüsselter Direkt-Chat (X25519 + AES-256-GCM) |
| **Transport** | BLE Mesh, LAN (lokal) + Nostr (Internet-Fallback) |
| **Nachrichten** | Text, Bilder (JPEG), Sprachnachrichten (AAC/WAV), Emojis, Reaktionen |
| **Chat-Features** | Antworten/Zitieren (Swipe), Nachrichtensuche, Weiterleiten, Favoriten |
| **Kanäle** | Öffentliche & private Kanäle (NIP-28/44), Gruppen, Ankündigungs-Kanäle |
| **Kontakte** | 4 Vertrauensstufen (Entdeckt → Kontakt → Vertrauensperson → Bürge) |
| **Zellen** | Lokale & thematische Gemeinschaften mit GPS-Geohash, Beitrittsanfragen, Mitgliederverwaltung |
| **Zellen-Leben** | Pinnwand, Diskussion, Agora (Abstimmungen), Mitglieder — 4 Tabs pro Zelle |
| **Agora** | Direkte Demokratie: Anträge erstellen, diskutieren, abstimmen (Ja/Nein/Enthaltung) |
| **Abstimmungs-Sync** | Echtzeit-Synchronisation zwischen allen Geräten via Nostr (NIP-01) |
| **Dorfplatz** | Dezentraler sozialer Feed: Posts, Reposts, Kommentare, Umfragen, Reaktionen |
| **Dorfplatz-Sync** | Reposts & Löschungen synchronisieren sich geräteübergreifend (NIP-18, NIP-09) |
| **Sicherheit** | Blockier-System, Schlüssel-Verifizierung (QR + Fingerprint), Selective Disclosure |
| **Dashboard** | Live-Radar (lokale Peers), N.E.X.U.S.-Node-Zähler |
| **Grundsätze** | Bewusster Onboarding-Flow mit den Grundsätzen der Menschheitsfamilie |
| **Push** | Benachrichtigungen ohne Google/Firebase (eigene Implementierung) |
| **Updates** | Automatischer Update-Checker via GitHub Releases |
| **Backup** | Automatisches Backup, Export & Wiederherstellung |

---

## Screenshots

> Screenshots folgen mit dem ersten öffentlichen Beta-Release.

---

## Installation

### Android

1. Gehe zu [GitHub Releases](https://github.com/project-nexus-official/oneapp/releases)
2. Lade die neueste `NexusOneApp_0.1.8.apk` herunter
3. Installiere die APK (Einstellungen → Unbekannte Quellen erlauben)

### Windows

1. Gehe zu [GitHub Releases](https://github.com/project-nexus-official/oneapp/releases)
2. Lade `Setup_NexusOneApp_v0.1.8.exe` herunter
3. Installer ausführen und Anweisungen folgen

### Bedienungsanleitung

Die vollständige Bedienungsanleitung steht als PDF im [aktuellen Release](https://github.com/project-nexus-official/oneapp/releases/tag/v0.1.8-alpha) zum Download bereit.

> iOS und macOS folgen in einer späteren Phase.

---

## Für Entwickler

### Tech Stack

| Layer | Technologie |
|---|---|
| Frontend | Flutter / Dart (Android, Windows — iOS/macOS folgen) |
| Transport | BLE Mesh + LAN + Nostr |
| Verschlüsselung | X25519 + NIP-44, Ed25519, AES-256-GCM |
| Datenbank | SQLite (sqflite / sqflite_ffi) |
| Identität | BIP-39 Seed Phrase, Ed25519/SLIP-0010, DID (W3C did:key) |
| Protokoll | Nostr (NIP-01/04/28/44) |

### Voraussetzungen

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel, ≥ 3.22)
- Android Studio oder VS Code mit Flutter-Extension
- Git

### Setup

```bash
git clone https://github.com/project-nexus-official/oneapp.git
cd oneapp

flutter pub get
flutter run                  # Android-Gerät oder Emulator
flutter run -d windows       # Windows Desktop
```

### Projektstruktur

```
lib/
├── core/                  # Kern-Infrastruktur
│   ├── crypto/            # Verschlüsselung (X25519, AES-GCM, HKDF)
│   ├── identity/          # DID, Seed Phrase, Pseudonym
│   ├── contacts/          # Kontakt-Service, Trust-Levels
│   ├── router.dart        # go_router mit Identity + Principles Guard
│   └── storage/           # SQLite-Datenbank
│
├── features/              # UI-Screens nach Domain
│   ├── onboarding/        # Seed Phrase, Identität, Grundsätze-Flow
│   ├── dashboard/         # Startscreen, Radar, Node-Counter
│   ├── chat/              # Direktnachrichten, Kanäle
│   ├── cells/             # Zellen, Agora, Mitgliederverwaltung
│   ├── dorfplatz/         # Sozialer Feed
│   ├── contacts/          # Kontaktliste, Details, QR-Scanner
│   ├── profile/           # Eigenes Profil, Selective Disclosure
│   └── settings/          # App-Einstellungen
│
└── services/              # Plattformübergreifende Services
    ├── cell_service.dart         # Zellen-Verwaltung
    ├── feed_service.dart         # Dorfplatz-Feed
    ├── notification_service.dart # Push ohne Firebase
    └── update_service.dart       # GitHub Release Checker
```

### KI-gestützte Entwicklung

Dieses Projekt nutzt Claude Code für KI-gestützte Entwicklung. Alle Konventionen, Architekturentscheidungen und der aktuelle Feature-Stand sind in [`CLAUDE.md`](CLAUDE.md) dokumentiert — die primäre Referenz für alle Entwickler (menschlich und KI).

---

## Roadmap

### v0.1.9 — Governance Stufe 2
- G2 Quadratic Voting (gewichtete Stimmen)
- G2 Stimmen-Delegation pro Antrag (echte Liquid Democracy)

### Phase 1c — AETHER Wallet & Marktplatz
- VITA Ꝟ (fließend, Demurrage 0,5%/Monat)
- TERRA ₮ (fest, für Infrastruktur)
- AURA ₳ (Reputation, nicht transferierbar)
- Lokaler Marktplatz (Peer-to-Peer)

### Phase 2 — Sphären-Plugins
- Care-System (Gesundheit, Bildung, Ernährung, Wohnen)
- Plugin-Schnittstelle für Community-Erweiterungen

---

## Mitmachen

### Als Nutzer: Testen und Feedback geben

Installiere die App, nutze sie im Alltag und melde Bugs oder Verbesserungsvorschläge direkt als [GitHub Issue](https://github.com/project-nexus-official/oneapp/issues) oder im Discord.

### Als Entwickler: Code beitragen

```bash
# 1. Fork auf GitHub
# 2. Feature-Branch erstellen
git checkout -b feat/dein-feature

# 3. Änderungen committen (Conventional Commits)
git commit -m "feat: kurze Beschreibung"

# 4. Pull Request öffnen
```

**Gesuchte Rollen:**
- Flutter / Dart (Frontend, Tests)
- Protokoll-Design (P2P, Kryptographie, Nostr)
- UX / UI Design (Figma, mobile-first)
- Rust / Substrate (eigene Blockchain — Phase 1c)

### Genesis Circle

Werde Teil des Gründungskreises und gestalte die Grundlagen mit — 100 Architekten, 6 Archetypen, 5 Arbeitskreise.

👉 **[nexus-terminal.org](https://nexus-terminal.org)**

---

## Rechtliches

> ⚠️ Bitte den vollständigen **[DISCLAIMER.md](DISCLAIMER.md)** vor der Nutzung lesen.

**Code:** [AGPL v3](LICENSE) — Open Source, Copyleft. Jede Nutzung, Modifikation oder Weiterverbreitung muss unter denselben Bedingungen erfolgen und den Quellcode offenlegen.

**Bauplan, Konzepte und Inhalte:** © Josh Richman 2024–2026. Alle Rechte vorbehalten. Der Bauplan des N.E.X.U.S.-Projekts (Protokoll, Governance-Modell, AETHER-Ökonomie) darf ohne ausdrückliche Genehmigung nicht reproduziert oder kommerziell genutzt werden.

---

## Links

| | |
|---|---|
| 🌐 Website | [nexus-terminal.org](https://nexus-terminal.org) |
| 💬 Telegram Kanal | [t.me/NexusProjectOfficial](https://t.me/NexusProjectOfficial) |
| 💬 Telegram Gruppe | [t.me/Nexus_Project_official](https://t.me/Nexus_Project_official) |
| 📺 YouTube | [Project-N.e.x.u.s-Official](https://www.youtube.com/@Project-N.e.x.u.s-Official) |
| 📖 Roman-Trilogie | [Amazon Kindle](https://www.amazon.de/dp/B0GGL1ZD7B) |
| 🎧 Hörbuch (Gratis) | [YouTube Playlist](https://www.youtube.com/playlist?list=PLLIatNIX1ph05NEJKZ1dG7yEqgl6txJBy) |
| 📘 Facebook | [NexusTerminal](https://www.facebook.com/NexusTerminal) |
| 📸 Instagram | [n.e.x.u.s._navigator](https://www.instagram.com/n.e.x.u.s._navigator) |
| 🐦 X (Twitter) | [nexusxnavigator](https://x.com/nexusxnavigator) |
| 🦋 Bluesky | [nexus-navigator.bsky.social](https://bsky.app/profile/nexus-navigator.bsky.social) |
| 🐙 GitHub | [project-nexus-official/oneapp](https://github.com/project-nexus-official/oneapp) |

---

*Protokoll, nicht Plattform. Für alle.*  
*Wir reformieren nicht. Wir bauen parallel. Dezentral statt Zentralmacht. Vertrauen statt Kontrolle. Liebe als Systemparameter — nicht als Floskel.*
