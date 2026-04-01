# N.E.X.U.S. OneApp

### Das Cockpit der Souveränität — Eine dezentrale App für die Menschheitsfamilie

![Version](https://img.shields.io/badge/version-v0.1.3--alpha-gold)
![Lizenz](https://img.shields.io/badge/lizenz-AGPL%20v3-blue)
![Plattform](https://img.shields.io/badge/plattform-Android%20%7C%20Windows-lightgrey)
![Tests](https://img.shields.io/badge/tests-315%2B%20passing-brightgreen)

---

## Was ist die OneApp?

Die NEXUS OneApp ist eine dezentrale Kommunikations- und Selbstverwaltungs-App — ohne zentralen Server, ohne Konzernkontrolle, ohne Zensur. Sie ist Schritt für Schritt darauf ausgelegt, WhatsApp durch souveränen Chat, Banken durch das AETHER-Protokoll und Parlamente durch Liquid Democracy zu ersetzen.

Der gesamte Quellcode ist Open Source (AGPL v3). Alle Nachrichten sind Ende-zu-Ende-verschlüsselt. Du besitzt deine Identität, deine Daten und deine Schlüssel — niemand sonst.

Den vollständigen Bauplan des NEXUS-Projekts findest du auf **[nexus-terminal.org](https://nexus-terminal.org)**.

---

## Was funktioniert bereits? (Phase 1a)

| Bereich | Feature |
|---|---|
| **Identität** | Self-Sovereign Identity via Seed Phrase (BIP-39), DID (W3C-Standard), Pseudonym |
| **Chat** | Ende-zu-Ende-verschlüsselter Direkt-Chat (X25519 + AES-256-GCM) |
| **Transport** | BLE Mesh, LAN (lokal) + Nostr (Internet-Fallback) |
| **Nachrichten** | Text, Bilder (JPEG), Sprachnachrichten (AAC/WAV), Emojis |
| **Chat-Features** | Antworten/Zitieren (Swipe), Nachrichtensuche (global + in-chat) |
| **Kanäle** | Benannte Gruppenkanäle (NIP-28), Discovery, Auto-Join `#nexus-global` |
| **Kontakte** | 4 Vertrauensstufen (Entdeckt → Kontakt → Vertrauensperson → Bürge) |
| **Sicherheit** | Blockier-System (still, lokal), Schlüssel-Verifizierung (QR + Fingerprint) |
| **Entdecken** | QR-Code Scanner für Face-to-Face Kontaktaustausch |
| **Dashboard** | Live-Radar (lokale Peers), NEXUS-Node-Zähler (7-Tage-Fenster) |
| **Grundsätze** | Bewusster Onboarding-Flow mit den Grundsätzen der Menschheitsfamilie |
| **Push** | Benachrichtigungen ohne Google/Firebase (eigene Implementierung) |
| **Updates** | Automatischer Update-Checker via GitHub Releases |
| **Tests** | 315+ automatisierte Unit- und Widget-Tests |

---

## Screenshots

> Screenshots folgen mit dem ersten öffentlichen Beta-Release.

---

## Installation

### Android

1. Gehe zu [GitHub Releases](https://github.com/project-nexus-official/N.E.X.U.S.-OneApp-Betriebssystem-der-freien-Welt/releases)
2. Lade die neueste `nexus-vX.Y.Z.apk` herunter
3. Installiere die APK (Einstellungen → Unbekannte Quellen erlauben)

### Windows

1. Gehe zu [GitHub Releases](https://github.com/project-nexus-official/N.E.X.U.S.-OneApp-Betriebssystem-der-freien-Welt/releases)
2. Lade `nexus-vX.Y.Z.zip` herunter und entpacke es
3. Führe `nexus_oneapp.exe` aus

> iOS und macOS folgen in einer späteren Phase.

---

## Für Entwickler

### Tech Stack

| Layer | Technologie |
|---|---|
| Frontend | Flutter / Dart (iOS, Android, Windows, macOS, Linux) |
| Blockchain | Substrate / Rust (eigene souveräne Chain — Phase 1c) |
| Chat-Protokoll | BLE Mesh + Nostr (inspiriert von BitChat) |
| Verschlüsselung | X25519 + AES-256-GCM, Noise Protocol, Post-Quanten ready |
| Datenbank | SQLite (sqflite / sqflite_ffi), AES-256-GCM verschlüsselt |
| Identität | BIP-39 Seed Phrase, Ed25519, DID (W3C did:key) |

### Voraussetzungen

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel, ≥ 3.22)
- Android Studio oder VS Code mit Flutter-Extension
- Git

### Setup

```bash
git clone https://github.com/project-nexus-official/N.E.X.U.S.-OneApp-Betriebssystem-der-freien-Welt.git
cd N.E.X.U.S.-OneApp-Betriebssystem-der-freien-Welt

flutter pub get
flutter run                  # Android-Gerät oder Emulator
flutter run -d windows       # Windows Desktop
```

### Tests

```bash
flutter test                 # alle 315+ Tests
flutter test test/features/  # nur Feature-Tests
```

### Projektstruktur

```
lib/
├── core/                  # Kern-Infrastruktur
│   ├── crypto/            # Verschlüsselung (X25519, AES-GCM, HKDF)
│   ├── identity/          # DID, Seed Phrase, Pseudonym
│   ├── contacts/          # Kontakt-Service, Trust-Levels
│   ├── router.dart        # go_router mit Identity + Principles Guard
│   └── storage/           # SQLite-Datenbank (verschlüsselt)
│
├── features/              # UI-Screens nach Domain
│   ├── onboarding/        # Seed Phrase, Identität, Grundsätze-Flow
│   ├── dashboard/         # Startscreen, Radar, Node-Counter
│   ├── chat/              # Direktnachrichten, Kanäle, Radar
│   ├── contacts/          # Kontaktliste, Details, QR-Scanner
│   ├── discover/          # Entdecken-Hub
│   ├── governance/        # Liquid Democracy (Phase 1b)
│   ├── profile/           # Eigenes Profil, Selective Disclosure
│   └── settings/          # App-Einstellungen
│
└── services/              # Plattformübergreifende Services
    ├── principles_service.dart   # Grundsätze (Accept/Skip)
    ├── update_service.dart       # GitHub Release Checker
    ├── notification_service.dart # Push ohne Firebase
    └── background_service.dart   # Hintergrund-Transport
```

### Transport-Architektur

Der `TransportManager` verwaltet ein Plugin-System aus drei Transportschichten:

```
BLE Mesh  ──┐
            ├──► TransportManager ──► ChatProvider ──► UI
LAN/mDNS ──┤
            │
Nostr    ──┘  (Internet-Fallback, Catch-Up für verpasste Nachrichten)
```

Nachrichten werden über den besten verfügbaren Transport gesendet. Nostr dient als Relay für Offline-Empfänger.

### KI-gestützte Entwicklung

Dieses Projekt nutzt Claude Code für KI-gestützte Entwicklung. Alle Konventionen, Architekturentscheidungen und der aktuelle Feature-Stand sind in [`CLAUDE.md`](CLAUDE.md) dokumentiert — die primäre Referenz für alle Entwickler (menschlich und KI).

---

## Roadmap

### Phase 1b — Governance *(in Entwicklung)*
- Liquid Democracy: delegierbare Stimmen, Vorschlagssystem
- Sphären-basierte Abstimmungen

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

Installiere die App, nutze sie im Alltag und melde Bugs oder Verbesserungsvorschläge auf **[nexus-terminal.org](https://nexus-terminal.org)**.

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
- Rust / Substrate (eigene Blockchain — Phase 1c)
- UX / UI Design (Figma, mobile-first)
- Protokoll-Design (P2P, Kryptographie)

### Genesis Circle

Werde Teil des Gründungskreises und gestalte die Grundlagen mit: **[nexus-terminal.org](https://nexus-terminal.org)**

---

## Lizenz

**Code:** [AGPL v3](LICENSE) — Open Source, Copyleft. Jede Nutzung, Modifikation oder Weiterverbreitung muss unter denselben Bedingungen erfolgen und den Quellcode offenlegen.

**Bauplan, Konzepte und Inhalte:** © Josh Richman 2024–2026. Alle Rechte vorbehalten. Der Bauplan des NEXUS-Projekts (Protokoll, Governance-Modell, AETHER-Ökonomie) darf ohne ausdrückliche Genehmigung nicht reproduziert oder kommerziell genutzt werden.

---

## Links

| | |
|---|---|
| Website | [nexus-terminal.org](https://nexus-terminal.org) |
| Telegram | [t.me/t.me/Nexus_Project_official](https://t.me/Nexus_Project_official) |
| GitHub Releases | [Releases](https://github.com/project-nexus-official/N.E.X.U.S.-OneApp-Betriebssystem-der-freien-Welt/releases) |

---

*Protokoll, nicht Plattform. Für alle.*
