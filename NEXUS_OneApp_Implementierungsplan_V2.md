# NEXUS OneApp: Technischer Implementierungsplan V2
## Vom 400-Seiten-Bauplan zur funktionierenden Software
### Aktualisiert mit BitChat-Blaupause, Entwicklungs-Workflow und Plattformstrategie

---

## 1. FEATURE-INVENTAR: Was die OneApp laut Bauplan können muss

Aus dem Bauplan (V12.0) extrahiert, nach Priorität geordnet:

### Kern-Infrastruktur (muss von Tag 1 existieren)
- **Self-Sovereign Identity (SSI):** Seed Phrase, DID, kryptografische Schlüsselpaare, Social Recovery
- **AETHER Wallet:** VITA Ꝟ senden/empfangen, Kontostand, Transaktionshistorie
- **Mesh-Chat:** Ende-zu-Ende-verschlüsselt, funktioniert ohne Internet (Bluetooth/WLAN-Direct)
- **Offline-First:** Kernfunktionen ohne Internetverbindung nutzbar

### Phase 1a – Killer-App #1: Mesh-Chat (Monat 1-4)
- Zensurfreie Kommunikation
- BLE Mesh-Netzwerk (Device-to-Device), Protokoll basierend auf BitChat-Architektur
- Nostr als Internet-Fallback (dezentrale Relays)
- Gruppenkanäle / Zellen-Kanäle (Geohash-basiert)
- „Schwarzes Brett" (dezentrale Pinnwand)
- Low-Bandwidth-Modus (Katastrophen-Modus)

### Phase 1b – Killer-App #2: Lokaler Marktplatz (Monat 5-10)
- Angebote erstellen/suchen (nur lokale Zelle)
- Bezahlung in VITA Ꝟ (und Euro in Übergangsphase)
- AURA ₳-basierte Vertrauensanzeige
- QR-Code-Zahlung
- Proof of Useful Work: Selbst-Deklaration + Peer-Bestätigung

### Phase 2a – Killer-App #3: Care-System (Jahr 2)
- Pflege-Matching (wer braucht Hilfe ↔ wer bietet an)
- Automatische VITA-Auszahlung via Smart Contract
- Care-VITA-Tracking
- Skill-Multiplikator-Berechnung

### Phase 2b – Killer-App #4: Wohn-Kooperativen (Jahr 3)
- Fluid Living: Wohnungstausch-Matching
- AURA-basierte Zugangssteuerung (statt Kaution)
- Gemeinschaftsprojekt-Verwaltung

### Governance-Modul
- Liquid Democracy: Direkt abstimmen oder Stimme delegieren
- Quadratic Voting
- Delegation Decay (automatischer Stimmverfall)
- Proposals erstellen und diskutieren
- KI-gestützter Konsens-Finder

### Sphären-Module (5 Basis-Sphären)
- **Asklepios (Gesundheit):** KI-Schutzengel, Gesundheitsdaten im POD, Federated Learning
- **Athena (Bildung):** KI-Tutor, Skill-Trees, Mentor-Matchmaking, Open Library
- **Demeter (Ernährung):** Food-Coop-Koordination, Überschuss-Signalisierung, Lieferketten-Transparenz
- **Hestia (Wohnen):** Fluid Living, Hüter-System, Wohnraum-Matching
- **Agora (Politik):** Liquid Democracy (s.o.), Diskussionsforen, KI-Moderation

### Sicherheits-Features
- Dead-Man-Switch (24h-Check-in)
- Automatische Social-Media-Kampagne bei Verhaftung
- Rechtsanwalts-Netzwerk-Trigger
- Privacy Proxy (Zero-Knowledge-Proofs)
- Post-Quanten-Kryptografie
- Emergency/Survival-Modus
- Triple-Tap Emergency Wipe (sofortige Löschung aller lokalen Daten)

### Gamification
- Life-Quests (freiwillige Challenges)
- Skill-Trees (visuelle Fähigkeitendarstellung)
- Badges und Achievements

---

## 2. ARCHITEKTUR

### 2.1 Grundsatzentscheidungen

Der Bauplan beschreibt bewusst ein **Protokoll, keine Plattform** (Kap. 4.8: „Standard statt Plattform"). Konkret heißt das:

**Schicht 1: Das NEXUS-Protokoll (der Standard)**
- Offene Spezifikation für Identität, Transaktionen, Governance, Messaging
- Jeder kann einen Client bauen, der dieses Protokoll spricht
- Vergleichbar mit E-Mail (SMTP/IMAP) oder dem Web (HTTP/HTML)

**Schicht 2: Die Referenz-Implementierung (die OneApp)**
- Der „offizielle" Client, den das Kern-Team baut
- Zeigt, wie das Protokoll funktioniert
- Wird Open Source veröffentlicht

**Schicht 3: Das Ökosystem (Community-Apps)**
- Dritte bauen eigene Clients, spezialisierte Tools, Sphären-Plugins
- Alle sprechen dasselbe Protokoll

### 2.2 Tech-Stack

#### Identität & Daten
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| Dezentrale ID | **did:key** + **did:web** (W3C Standard) | Einfachster Einstieg, kein Blockchain-Zwang für IDs |
| Datensouveränität | **Solid PODs** (Tim Berners-Lee) | Im Bauplan explizit genannt. Trennt Daten von Apps |
| Verifiable Credentials | **W3C VC Data Model 2.0** | Standard für digitale Nachweise |
| Schlüsselverwaltung | **BIP-39** (12-Wort Seed Phrase) | Bewährt, im Bauplan beschrieben |
| Social Recovery | **Shamir's Secret Sharing** | Verteilt Seed-Backup auf N Vertrauenspersonen |

#### Ledger & Smart Contracts
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| Blockchain | **Substrate** (Polkadot SDK) | Modular, eigene Chain möglich, upgradeable ohne Hardfork, Rust-basiert |
| Smart Contracts | **ink!** (Substrate-native) oder **CosmWasm** | WASM-basiert, sicher, formal verifizierbar |
| Alternative | **Cosmos SDK** | Wenn Inter-Chain-Kommunikation Priorität ist |
| Konsens | **BABE/GRANDPA** (Substrate-Default) | Proof-of-Authority anfangs, später Nominated PoS |

**Warum Substrate und nicht Ethereum/Solana?**
- Eigene souveräne Chain (keine Abhängigkeit von Ethereum-Gas-Preisen)
- Forkless Upgrades (im Bauplan gefordert: „Updates ohne Hardfork möglich")
- Modulare Runtime: Demurrage, AURA-Decay, Quadratic Voting als native Pallets
- Rust-basiert: Speichersicher, performant, passend für Embedded/Edge

#### Kommunikation & Mesh (aktualisiert mit BitChat-Erkenntnissen)
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| BLE Mesh-Protokoll | **BitChat-Architektur als Blaupause** | Bewährt unter Realbedingungen (Nepal Sept. 2025: 3K→50K Downloads in einem Tag). Multi-Hop, Store-and-Forward, 500-Byte-Chunks, LZ4-Kompression |
| Internet-Fallback | **Nostr** (statt Matrix) | BitChat nutzt Nostr erfolgreich. Dezentrale Relays weltweit vorhanden. Geohash-Kanäle = NEXUS-Zellen. Dart-Libraries verfügbar |
| BLE-Transport | **BLE 5.0 Advertising + GATT** | Wie BitChat: Jedes Gerät ist Client UND Peripheral. 30-100m Reichweite, Bridge-Nodes verbinden Cluster |
| E2E-Verschlüsselung (Mesh) | **Noise Protocol (XX Handshake)** | BitChat-Standard für lokale Verschlüsselung |
| E2E-Verschlüsselung (Nostr) | **NIP-17** | Nostr-Standard für private Nachrichten |
| Notfall-Funk | **LoRa/Meshtastic** | Im Bauplan explizit (5€ LoRa-Chips), als zusätzlicher Layer |
| Datei-Speicherung | **IPFS** (Kubo) | Im Bauplan explizit, Content-Addressable Storage |

**Wichtigste Änderung gegenüber V1: Nostr statt Matrix als Internet-Layer.**
Matrix erfordert eigene Homeserver-Infrastruktur. Nostr nutzt existierende dezentrale Relays weltweit — weniger Aufwand, mehr Resilienz, und BitChat hat bewiesen, dass die Kombination BLE+Nostr funktioniert.

#### KI & Privacy
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| Lokales LLM | **llama.cpp** / **MLX** / **ONNX Runtime** | Läuft auf Home-Node, keine Cloud nötig |
| Modell | **Mistral 7B** oder **Phi-3 Mini** (quantisiert) | Klein genug für Edge, gut genug für Tutoring |
| Federated Learning | **Flower** (Framework) | Open Source, production-ready |
| Zero-Knowledge-Proofs | **Circom** + **Groth16** oder **Halo2** | Für Altersnachweis, Berechtigungsprüfung |
| Post-Quanten-Krypto | **CRYSTALS-Kyber** + **CRYSTALS-Dilithium** | NIST-standardisiert (2024), Gitterbasiert |

#### Frontend / App
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| Cross-Platform App | **Flutter** (Dart) | Eine Codebase → Android + iOS + Linux Desktop + Web + Raspberry Pi |
| Offline-First DB | **SQLite** + **CRDTs** (Automerge) | Lokale Datenbank, Conflict-Free Sync |
| BLE-Library | **flutter_blue_plus** | Bewährte Flutter-BLE-Bibliothek |
| UI-Design | **Material 3** mit Custom NEXUS Design System | Wiedererkennbar, barrierefrei |
| Navigation | **GoRouter** | Deklaratives Routing für Flutter |

#### Infrastructure
| Komponente | Technologie | Begründung |
|-----------|------------|-----------|
| Home-Node | **Raspberry Pi 4/5** + **NixOS** | Im Bauplan erwähnt, günstig, reproduzierbar |
| Container | **Podman** (rootless) | Sicherer als Docker für Community-Nodes |
| CI/CD | **Forgejo** (self-hosted) + **GitHub Mirror** | Forgejo für Souveränität, GitHub für Sichtbarkeit |

### 2.3 Systemarchitektur (Übersicht)

```
┌──────────────────────────────────────────────────────────┐
│                    NUTZER-GERÄT                            │
│  ┌─────────────┐  ┌──────────┐  ┌─────────────────────┐  │
│  │  OneApp UI   │  │ Local AI │  │    Mesh Radio        │  │
│  │  (Flutter)   │  │ (LLM)   │  │  (BLE/LoRa/Nostr)   │  │
│  └──────┬───────┘  └────┬─────┘  └──────────┬──────────┘  │
│         │               │                    │             │
│  ┌──────┴───────────────┴────────────────────┴──────────┐ │
│  │              NEXUS SDK / Core Library                  │ │
│  │  ┌────────┐ ┌────────┐ ┌──────┐ ┌────────────┐       │ │
│  │  │Identity│ │ Wallet │ │ Chat │ │ Governance  │       │ │
│  │  │ (DID)  │ │(AETHER)│ │(E2EE)│ │(Liq. Demo.)│       │ │
│  │  └────────┘ └────────┘ └──────┘ └────────────┘       │ │
│  │  ┌────────┐ ┌────────┐ ┌──────────────────────────┐  │ │
│  │  │  ZKP   │ │ CRDT   │ │   Sphären-Plugin-API     │  │ │
│  │  │ Engine │ │  Sync  │ │  (Asklepios, Athena…)     │  │ │
│  │  └────────┘ └────────┘ └──────────────────────────┘  │ │
│  └──────────────────────┬────────────────────────────────┘ │
│                         │                                  │
│  ┌──────────────────────┴───────────────────────────────┐  │
│  │              Solid POD (Lokaler Datentresor)           │  │
│  │  Gesundheit │ Bildung │ Finanzen │ Soziales           │  │
│  └───────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
  ┌────────────┐   ┌────────────┐   ┌──────────┐
  │ BLE Mesh   │   │  Nostr     │   │ LoRa     │
  │ (BitChat-  │   │  Relays    │   │(Notfall) │
  │  Protokoll)│   │ (Internet) │   │          │
  └─────┬──────┘   └─────┬──────┘   └────┬─────┘
        │                │               │
        └───────┬────────┘               │
                ▼                        │
  ┌──────────────────────────────────────┴──────┐
  │         NEXUS-NETZWERK                       │
  │  ┌─────────────┐  ┌──────────────────────┐  │
  │  │ Substrate   │  │  IPFS-Cluster        │  │
  │  │ Blockchain  │  │  (Dateien)           │  │
  │  │ (VITA/      │  │                      │  │
  │  │  TERRA/     │  │  Nostr-Relays        │  │
  │  │  AURA)      │  │  (Chat-Fallback)     │  │
  │  └─────────────┘  └──────────────────────┘  │
  │                                              │
  │  ┌─────────────────────────────────────────┐ │
  │  │  Home-Nodes (Raspberry Pi)              │ │
  │  │  = lokale Validator-Knoten              │ │
  │  │  = IPFS-Pinning                         │ │
  │  │  = BLE-Relay (Dedicated Bridge)         │ │
  │  │  = Solid-POD-Host                       │ │
  │  │  = Lokales LLM (Schutzengel)           │ │
  │  └─────────────────────────────────────────┘ │
  └──────────────────────────────────────────────┘
```

---

## 3. PLATTFORM-UNABHÄNGIGKEIT: Überall laufen, von niemandem abhängen

### 3.1 Warum Flutter die richtige Wahl ist

Flutter kompiliert eine einzige Codebase zu nativen Apps für alle Zielplattformen:

```
Eine Flutter-Codebase
        │
        ├── → Android (Google)               ✅ automatisch
        ├── → Google-freies Android          ✅ gleicher Build
        │      (GrapheneOS, CalyxOS,
        │       /e/OS, LineageOS)
        ├── → iOS (Apple)                    ✅ automatisch
        ├── → Linux Desktop                  ✅ automatisch
        ├── → Raspberry Pi (ARM-Linux)       ✅ automatisch
        ├── → Windows Desktop                ✅ automatisch
        ├── → macOS Desktop                  ✅ automatisch
        ├── → Web (Browser)                  ✅ automatisch
        │
        └── → Linux-Phones                   ⚠️ mit UI-Anpassung
            (Ubuntu Touch, PinePhone)
```

Canonical (Ubuntu) hat offiziell mit Google zusammengearbeitet, um Flutter auf Linux erstklassig zu unterstützen. Flutter selbst ist Open Source (MIT-Lizenz).

### 3.2 Distributions-Strategie: Kein Google Play, kein Apple App Store

| Kanal | Plattform | Beschreibung |
|-------|-----------|-------------|
| **F-Droid** | Android | Open-Source App-Store, vorinstalliert auf GrapheneOS/CalyxOS |
| **Direkt-Download (APK)** | Android | Von NEXUS-Website, verifiziert mit GPG-Signatur |
| **GitHub/Forgejo Releases** | Alle | Offizielle Builds für jede Plattform |
| **TestFlight / Sideloading** | iOS | Für Beta-Tests und direkte Distribution |
| **Flatpak / Snap** | Linux Desktop | Für Ubuntu, Fedora und andere Linux-Distributionen |

### 3.3 Empfohlene Hardware für Pioniere

| Gerät | Betriebssystem | Warum |
|-------|---------------|-------|
| **Fairphone 5** + /e/OS | Google-freies Android | Reparierbar, nachhaltig, passt zur NEXUS-Philosophie |
| **Google Pixel** + GrapheneOS | Härteste Privatsphäre | Bester Sicherheits-Standard, häufigste Updates |
| **Raspberry Pi 5** + NixOS | Linux (Home-Node) | Günstig, 24/7, hostet Validator + IPFS + LLM |
| **Beliebiges Android-Gerät** | LineageOS | Für ältere/günstigere Handys, breiteste Kompatibilität |

### 3.4 Langfrist-Vision (Phase 3+)

- Linux-Phone-Support (PinePhone, Librem 5, Volla Phone)
- RISC-V-Hardware-Unterstützung (wie im Bauplan Kap. 3.17.1 beschrieben)
- Eventuell eigenes NEXUS-OS (minimales Linux + vorinstallierte OneApp)

---

## 4. BITCHAT ALS BLAUPAUSE: Was wir übernehmen, was wir selbst bauen

### 4.1 Hintergrund

BitChat wurde im Juli 2025 von Jack Dorsey als Open-Source BLE-Mesh-Chat veröffentlicht (Public Domain / Unlicense). Im September 2025 wurde es in Nepal zur Schlüsseltechnologie, als die Regierung 26 Social-Media-Plattformen sperrte — Downloads stiegen von 3.000 auf 50.000 an einem Tag.

BitChat ist fast wortgleich die Killer-App #1 aus dem NEXUS-Bauplan (Kap. 9.2.1.4).

### 4.2 Was wir von BitChat übernehmen (Protokoll-Wissen, kein Code-Fork)

BitChat ist in Swift (iOS-only) geschrieben. Wir forken nicht den Code, sondern übernehmen das **bewährte Protokoll-Design:**

| Von BitChat übernommen | Beschreibung |
|------------------------|-------------|
| **BLE-Mesh-Architektur** | Multi-Hop-Relay, Peer-Discovery, Bridge-Nodes zwischen Clustern |
| **Nachrichten-Fragmentierung** | 500-Byte-Chunks über BLE (MTU-Limit), LZ4-Kompression |
| **Store-and-Forward** | Nachrichten werden 12h auf Relay-Nodes gecacht |
| **Nostr-Integration** | Internet-Fallback über dezentrale Relays, Geohash-Kanäle |
| **IRC-Style Rooms** | Hashtag-Kanäle mit optionalem Passwort |
| **Emergency Wipe** | Triple-Tap löscht alle lokalen Daten sofort |
| **Advertising-Strategie** | BLE-Advertising-Intervalle und Scanning-Parameter |

### 4.3 Was wir selbst bauen (NEXUS-Erweiterungen)

| NEXUS-Eigenentwicklung | Beschreibung |
|------------------------|-------------|
| **DID-basierte Identität** | Statt BitChats anonymer Handles: BIP-39 Seed Phrase + DID |
| **AETHER-Wallet** | VITA/TERRA/AURA-Integration in den Chat |
| **Zellen-Kanäle** | Geohash-Kanäle = NEXUS-Zellen (Governance-Einheit) |
| **Schwarzes Brett** | Pinnwand-Modus als spezieller Kanal-Typ |
| **Solid POD** | Persönliche Datensouveränität |
| **LoRa-Fallback** | Zusätzlicher Notfall-Layer |
| **Post-Quanten-Krypto** | Zukunftssicher ab Tag 1 |

### 4.4 Zeitersparnis durch BitChat

| Aspekt | Ohne BitChat-Wissen | Mit BitChat-Blaupause |
|--------|--------------------|-----------------------|
| BLE-Protokoll-Design | Von Null | Übernommen (White Paper + 804 Commits) |
| BLE-iOS-Risiko | Hoch (Background-BLE unklar) | Niedrig (BitChat hat Lösung dokumentiert) |
| Internet-Fallback | Matrix (eigene Homeserver) | Nostr (existierende Relay-Infrastruktur) |
| Battle-Testing | Noch zu erbringen | Nepal hat bewiesen, dass BLE Mesh funktioniert |
| Phase 1a Dauer | ~3 Monate | **~2 Monate** |

---

## 5. ENTWICKLUNGS-WORKFLOW: Wie wir bauen

### 5.1 Primäres Werkzeug: Claude Code

Das Entwicklungsteam nutzt KI-gestütztes agentisches Coding für schnelle Iteration:

- **Plan Mode:** Bei jedem neuen Feature erst Architektur besprechen, dann implementieren
- **Eine Aufgabe pro Session:** Kleine, fokussierte Arbeitseinheiten statt monolithischer Sprints
- **Test-First:** Jede Funktion wird mit Tests geliefert
- **Review-Cycle:** Code wird geprüft, erklärt und iteriert

### 5.2 CLAUDE.md — Das Projekt-Briefing

Im Wurzelverzeichnis des Repositories liegt eine `CLAUDE.md`, die das Projekt, den Stack, die Konventionen und den aktuellen Fokus beschreibt. Diese Datei wird bei jedem Entwicklungs-Session automatisch gelesen und sichert Konsistenz über Sessions hinweg.

### 5.3 Custom Commands

| Command | Funktion |
|---------|---------|
| `/nexus-review` | NEXUS-spezifisches Code-Review (Offline-First, Verschlüsselung, Dezentralität) |
| `/nexus-status` | Implementierungsstand mit ✅/❌ pro Feature |
| `/nexus-plan` | Nächste 3 sinnvolle Aufgaben basierend auf aktuellem Stand |

### 5.4 Code-Standards

- Dart/Flutter: Effective Dart Style Guide
- Rust/Substrate: Clippy-clean, alle Warnungen beheben
- Tests: Jede neue Funktion braucht Unit-Tests
- Sprache: Code und Kommentare auf Englisch, UI-Texte auf Deutsch
- Commit-Messages: Conventional Commits (feat:, fix:, docs:, etc.)
- Repository: Forgejo (self-hosted) + GitHub-Mirror für Sichtbarkeit

---

## 6. IMPLEMENTIERUNGS-ROADMAP: Aufgabe für Aufgabe

### Phase 0: Fundament (Woche 1-2)

| Aufgabe | Beschreibung | Deliverable |
|---------|-------------|-------------|
| **A1** | Flutter-Projekt initialisieren: Ordnerstruktur (core/, features/chat/, features/wallet/, features/marketplace/, shared/), Theme (Material 3), Dependencies | Lauffähige App mit Splash-Screen |
| **A2** | Hauptnavigation: Bottom Nav mit 3 Tabs (Chat, Wallet „Coming Soon", Profil), GoRouter | Navigierbare App-Shell |

### Phase 0: Identität (Woche 2-3)

| Aufgabe | Beschreibung | Deliverable |
|---------|-------------|-------------|
| **B1** | Seed Phrase (BIP-39, 12 Wörter) generieren, Ed25519-Schlüsselpaar ableiten, verschlüsselt im Secure Storage speichern, lesbaren Pseudonym-Namen generieren. Onboarding-Flow: Willkommen → Seed anzeigen → Bestätigung → Name → Fertig | Sarahs „Tag 1" funktioniert |
| **B2** | Konto wiederherstellen: 12 Wörter eingeben → Schlüsselpaar wiederhergestellt, BIP-39-Wortliste-Validierung | Recovery funktioniert |

### Phase 1a: BLE Mesh-Chat (Woche 4-10)

| Aufgabe | Beschreibung | Deliverable |
|---------|-------------|-------------|
| **C1** | BLE Scanner + Advertiser (nach BitChat-Vorbild): NEXUS-Service-UUID, Peer-Discovery, GATT-Verbindung. flutter_blue_plus | Zwei Handys finden sich |
| **C2** | Nachrichten senden/empfangen: JSON-Format, LZ4-Kompression, 500-Byte-Fragmentierung, SQLite-Speicherung. Chat-UI mit Bubbles | Zwei Handys chatten direkt |
| **C3** | Multi-Hop Relay + Store-and-Forward: Jedes Gerät ist Relay. TTL 12h, ID-basierter Flood-Schutz. Nachrichten-Caching für Offline-Empfänger | Nachrichten springen über Geräte |
| **C4** | E2E-Verschlüsselung: Noise Protocol (XX Handshake) für Direktnachrichten, optionale Passwort-Verschlüsselung für Gruppenräume, Triple-Tap Emergency Wipe | Alles verschlüsselt |
| **C5** | Gruppen-Chat: #mesh (lokal), benannte Kanäle (/create, /join, /list), Schwarzes-Brett-Modus (Pinnwand), Sidebar mit Kanal-Liste | Zellen-Kommunikation funktioniert |
| **C6** | Nostr-Internet-Fallback: Automatisches Umschalten BLE↔Nostr, Geohash-basierte Kanäle (= NEXUS-Zellen auf Nostr), Dart-Nostr-Library | Chat funktioniert auch mit Internet |

### Phase 1a: Testing & Polish (Woche 11-12)

| Aufgabe | Beschreibung | Deliverable |
|---------|-------------|-------------|
| **D1** | Gesamttest: Unit-Tests, Integration-Test (2 virtuelle Nutzer), Performance-Check, Batterie-Optimierung | Alle Tests grün |
| **D2** | UI-Polish: NEXUS-Theme (Tiefblau + Gold), Radar-Animation für Peer-Suche, Verbindungsstatus-Indikator, Onboarding-Tutorial (3 Screens) | App sieht professionell aus |

### Phase 1b: AETHER-Wallet + Marktplatz (Monat 5-10)

#### Substrate-Blockchain

| Pallet (Modul) | Funktion | Komplexität |
|----------------|---------|-------------|
| `pallet-identity` | DID-Registrierung auf-Chain | Mittel |
| `pallet-vita` | VITA Ꝟ mit Demurrage (0,5%/Monat, Lazy Evaluation) | Hoch |
| `pallet-terra` | TERRA ₮, nicht-konsumierbar, Governance-genehmigt | Mittel |
| `pallet-aura-reputation` | AURA ₳: Akkumulation durch PoUW, Decay (2-5%/Mo), nicht-transferierbar, Domain-spezifisch | Hoch |
| `pallet-pouw` | Proof of Useful Work: Selbst + Peer → VITA-Schöpfung | Hoch |
| `pallet-gaia-fonds` | 10%-Abzug bei VITA-Schöpfung → Gaia-Pool | Niedrig |
| `pallet-demurrage-engine` | Berechnet Demurrage-Verluste, verteilt Rückflüsse | Hoch |

**Demurrage via Lazy Evaluation:**
```
Jedes Konto speichert: {balance, last_updated_block}
Bei Zugriff:
  blocks_elapsed = current_block - last_updated_block
  decay_factor = (1 - 0.005/blocks_per_month) ^ blocks_elapsed
  actual_balance = stored_balance * decay_factor
→ O(1) pro Block statt O(n). Skaliert unbegrenzt.
```

#### Marktplatz-Modul

| Feature | Beschreibung |
|---------|-------------|
| Angebot erstellen | Foto + Beschreibung + Preis in VITA Ꝟ, via IPFS gespeichert |
| Suche | Nur lokale Zelle (GPS/manuell). Kategorien: Lebensmittel, Handwerk, Dienstleistung |
| QR-Zahlung | Verkäufer zeigt QR → Käufer scannt → signiert → on-Chain bestätigt |
| AURA-Anzeige | AURA-Score als Vertrauensindikator pro Verkäufer |
| Euro-Bridge | Übergangsphase: Euro ↔ VITA (1:1) über Genossenschafts-Konto |

### Phase 2: Sphären-Framework + Care + Governance (Jahr 2)

#### Sphären-Plugin-Architektur

```yaml
# Plugin-Manifest
name: "asklepios"
version: "0.1.0"
permissions:
  - "pod:health:read"
  - "pod:health:write"
  - "chain:vita:transfer"
dependencies:
  - "nexus-core >= 1.0"
```

Jede Sphäre ist ein eigenständiges Modul mit Frontend (Flutter-Package), Backend (Substrate-Pallet oder Off-Chain), Daten (Solid POD Namespace) und nutzergesteuerten Berechtigungen.

#### Governance-Modul

| Feature | Implementierung |
|---------|----------------|
| Proposals | On-Chain mit IPFS-Beschreibung |
| Liquid Democracy | `delegate(from, to, domain, weight)`, jederzeit widerrufbar |
| Quadratic Voting | 1 Stimme = 1 Punkt, 2 = 4, 3 = 9. Budget pro Zyklus |
| Delegation Decay | -10%/Monat, zwingt zur aktiven Bestätigung |
| KI-Konsens-Finder | Lokales LLM auf Home-Node, Advisory ohne Stimmrecht |

#### Care-System

| Feature | Implementierung |
|---------|----------------|
| Pflege-Matching | Bedarf ↔ Angebot nach Fähigkeiten, Nähe, Verfügbarkeit |
| Smart Contract | `care_session_complete()` → VITA-Schöpfung + AURA-Boost |
| Skill-Multiplikator | On-Chain-Tabelle, Governance-gesteuert |
| Peer-Verifikation | Empfänger bestätigt via Signatur. >15 AURA: 2 Verifikatoren nötig |

### Phase 3: Vollständiges Ökosystem (Jahr 3-5)

| Modul | Beschreibung |
|-------|-------------|
| **Asklepios** | KI-Schutzengel auf Home-Node, Federated Learning, Gesundheitsdaten-POD |
| **Athena** | KI-Tutor, Skill-Trees, Mentor-Matchmaking, Open Library (IPFS) |
| **Demeter** | Food-Coop-Logistik, Überschuss-Alerts, Farm-to-Fork |
| **Hestia** | Wohnungs-Matching, Fluid Living, TERRA-Projekte |
| **Dead-Man-Switch** | 24h-Check-in, Alarmierung, Social-Media-Bot, Anwalts-Trigger |
| **Life-Quests** | Gamification: Challenges, Badges, Skill-Trees |
| **Inter-Zellen-Protokoll** | Föderations-Governance, Solidaritäts-Pool, Schiedsgericht |
| **Linux-Phone-Support** | Ubuntu Touch, PinePhone, Librem 5 |
| **RISC-V-Unterstützung** | Offene Hardware (Bauplan Kap. 3.17.1) |

---

## 7. TEAM-STRUKTUR UND RECRUITING

### 7.1 Aktuelle Situation: Solo-Gründer + KI-gestütztes Development

Das Projekt wird aktuell von einem Solo-Gründer vorangetrieben, der KI-gestütztes agentisches Coding nutzt, um die Geschwindigkeit eines kleinen Teams zu erreichen. Priorität: funktionierenden Prototypen bauen, dann damit Entwickler überzeugen.

### 7.2 Gesuchte Rollen (nach Priorität)

| Priorität | Rolle | Fokus | Recruiting-Kanal |
|-----------|-------|-------|-------------------|
| 🔴 Sofort | **Flutter/Dart-Entwickler** | OneApp UI, BLE-Mesh, Offline-First | GitHub, F-Droid Community, Flutter Discord |
| 🔴 Sofort | **Rust-Entwickler** | Substrate-Pallets, Crypto | Substrate Builders, Rust Community |
| 🟡 Phase 1b | **Netzwerk-Engineer** | BLE Mesh, Nostr, P2P | Mesh-Networking-Communities, Meshtastic-Forum |
| 🟡 Phase 1b | **Kryptograf** | ZKPs, Post-Quanten, Formale Verifikation | Kryptografie-Konferenzen, IACR |
| 🟢 Phase 2 | **UX-Designer** | „So einfach wie WhatsApp" | Design-Communities, Dribbble |
| 🟢 Phase 2 | **DevOps** | CI/CD, Testnet, Raspberry Pi Nodes | NixOS Community, Self-Hosted-Szene |

### 7.3 Recruiting-Strategie

- **Social Media:** Technische Posts auf LinkedIn, X/Twitter (Thread-Format), Mastodon, Reddit (r/opensource, r/privacy, r/decentralization)
- **Botschaft:** „Wir bauen gerade den Mesh-Chat (Phase 1), hier ist der Stack, das ist die Vision, wir suchen Leute"
- **Qualitätsfilter:** Link zum Repository + Bauplan. Wer nach dem Lesen immer noch dabei sein will, ist richtig
- **Keine VCs, kein Exit:** Ehrlich kommunizieren — das ist ein Open-Source-Infrastruktur-Projekt

### 7.4 Kern-Team (Ziel Phase 1): 5-8 Personen

| Rolle | Anzahl | Fokus |
|-------|--------|-------|
| **Protocol Engineer (Rust)** | 1-2 | Substrate-Blockchain, Pallets, Crypto |
| **Mobile Engineer (Flutter)** | 2-3 | OneApp UI, Offline-First, BLE-Mesh |
| **Mesh/Network Engineer** | 1 | BLE Mesh, Nostr, LoRa |
| **Product/UX Designer** | 1 | „So einfach wie WhatsApp"-Prinzip |

### 7.5 Erweiterung (Phase 2+): 12-20 Personen

- +1 Kryptograf (ZKPs, Post-Quanten-Krypto, Formale Verifikation)
- +1 DevOps / Infrastructure (CI/CD, Testnet, Raspberry Pi Nodes)
- +2-3 ML Engineers (lokale LLMs, Federated Learning)
- +2-3 Sphären-Entwickler (Asklepios, Athena, Demeter)
- +1 Governance-Spezialist
- +1 Security Auditor
- +1 Community/QA (Beta-Test-Koordination, Dokumentation)

---

## 8. DIE DREI GRÖSSTEN TECHNISCHEN RISIKEN

### Risiko 1: BLE Mesh auf iOS
Apple beschränkt Background-Bluetooth. Status: **ENTSCHÄRFT durch BitChat.**
BitChat hat bewiesen, dass BLE Mesh auf iOS funktioniert und die Workarounds dokumentiert.

**Verbleibende Maßnahmen:**
- MultipeerConnectivity Framework auf iOS als Ergänzung
- Dedicated Relay-Nodes (Raspberry Pi mit BLE-Dongle) in NEXUS-Hubs
- LoRa-Module als Always-On-Relay (Wochen Laufzeit)

### Risiko 2: Demurrage auf einer Blockchain
Demurrage widerspricht dem Standardverhalten jeder Blockchain. Status: **Lösbar mit Lazy Evaluation.**

**Lösung:**
- Eigene Chain (Substrate) → volle Kontrolle über Token-Logik
- Demurrage als First-Class-Feature, nicht als Wrapper
- `decay_checkpoint()` Extrinsic für periodische Materialisierung

### Risiko 3: Lokale LLMs auf Smartphones
2026 noch zu leistungsschwach für Smartphone-Betrieb. Status: **Gelöst durch Home-Node-Strategie.**

**Lösung:**
- Phase 1-2: Regelbasierte Systeme (kein LLM)
- Phase 3: Raspberry Pi 5 (8GB) als Home-Node hostet LLM im lokalen Netzwerk
- Langfristig: 2028-2029 werden 7B-Modelle auf Mittelklasse-Phones laufen

---

## 9. BUDGET-SCHÄTZUNG

### Szenario A: Solo-Gründer + KI-gestütztes Development

| Phase | Dauer | Kosten |
|-------|-------|--------|
| Phase 0 + 1a (Chat) | 3 Monate | ~600€ (Claude Max $100/Mo + Hosting) |
| Phase 1b (Wallet + Marktplatz) | 6 Monate | ~600€ + Substrate-Testnet-Hardware (~500€) |
| **Gesamt bis Killer-App #2** | **~9 Monate** | **~1.700€** |

### Szenario B: Kleines Team (5-8 Personen, teilweise unbezahlt)

| Phase | Dauer | Team | Kosten (Mix aus Sweat Equity + Stipendien) |
|-------|-------|------|-------------------------------------------|
| Phase 0 + 1a | 2 Monate | 3-5 | ~20.000€ (Grants: Prototype Fund, NGI) |
| Phase 1b | 5 Monate | 5-8 | ~80.000€ |
| Phase 2 | 12 Monate | 8-12 | ~300.000€ |
| **Gesamt bis Killer-App #3** | **~19 Monate** | | **~400.000€** |

### Szenario C: Voll finanziertes Team (Referenz)

| Phase | Dauer | Team | Kosten (5.000€/Mo/Person) |
|-------|-------|------|--------------------------|
| Phase 0 + 1a | 2 Monate | 7 | ~70.000€ |
| Phase 1b | 5 Monate | 10 | ~250.000€ |
| Phase 2 | 12 Monate | 15 | ~900.000€ |
| **Gesamt bis Killer-App #3** | **~19 Monate** | | **~1.220.000€** |

### Finanzierungsquellen (kein VC)
- **Prototype Fund** (BMBF): Bis 47.500€ für 6 Monate Open-Source-Entwicklung
- **NGI (Next Generation Internet, EU):** Bis 50.000€ für Dezentralisierungs-Projekte
- **NLnet Foundation:** Fördert Privacy- und Dezentralisierungs-Technologie
- **Sweat Equity:** Genesis-Pakt (Bauplan Kap. 11.6.1) — Pioniere arbeiten 10h/Woche für VITA Ꝟ
- **Community-Funding:** Spenden, Genossenschaftsanteile

---

## 10. ZEITPLAN (Zusammenfassung)

### Bei Solo-Entwicklung mit KI-Unterstützung (10-15h/Woche):

| Woche | Meilenstein |
|-------|------------|
| 1-2 | Flutter-Projekt steht, Identität (Seed Phrase) funktioniert |
| 3-4 | BLE-Scanner findet andere NEXUS-Geräte |
| 5-6 | Zwei Handys chatten direkt über Bluetooth |
| 7-8 | Multi-Hop und Verschlüsselung funktionieren |
| 9-10 | Gruppenkanäle und Nostr-Fallback |
| 11-12 | Testing, UI-Polish, erster Alpha-Test mit echten Geräten |
| **Woche 12** | **🎯 Killer-App #1: Mesh-Chat ist funktionsfähig** |
| 13-20 | Substrate-Testnet, VITA-Pallet mit Demurrage |
| 21-30 | Marktplatz, QR-Zahlung, AURA-Score |
| **Woche 30** | **🎯 Killer-App #2: Lokaler Marktplatz** |
| 31-52 | Care-System, Governance, erste Sphären-Plugins |
| **Woche 52** | **🎯 Killer-App #3: Care-System** |

### Bei Vollzeit-Team (5-8 Personen):

| Monat | Meilenstein |
|-------|------------|
| 1-2 | Fundament + Mesh-Chat (Killer-App #1) |
| 3-4 | Substrate-Testnet + VITA-Wallet |
| 5-8 | Marktplatz + QR-Zahlung (Killer-App #2) |
| 9-12 | Care-System + Governance (Killer-App #3) |
| 13-18 | Erste Sphären-Plugins (Asklepios, Athena) |
| **Monat 6** | **🎯 Erster öffentlicher Beta-Test: 100 Pioniere in Berlin** |

---

## 11. ZUSAMMENFASSUNG

Der Bauplan beschreibt ein technisch anspruchsvolles, aber realisierbares System. Die kritischsten Entscheidungen:

1. **Flutter als App-Framework** — eine Codebase für Android, iOS, Linux, Raspberry Pi. Läuft auf GrapheneOS, CalyxOS, /e/OS ohne Änderung. Unabhängig von Google Play Store.

2. **BitChat als Protokoll-Blaupause** — BLE Mesh, Nostr-Fallback, Store-and-Forward. Nepal hat bewiesen, dass es funktioniert. Spart 4-6 Wochen Entwicklungszeit und eliminiert das größte technische Risiko (BLE auf Mobilgeräten).

3. **Nostr statt Matrix als Internet-Layer** — keine eigene Server-Infrastruktur nötig. Dezentrale Relays existieren weltweit. Geohash-Kanäle werden zu NEXUS-Zellen.

4. **Substrate als Blockchain** — Souveränität, Forkless Upgrades, Demurrage nativ als Pallet.

5. **KI-gestütztes Development** — ermöglicht einem Solo-Gründer, die Geschwindigkeit eines kleinen Teams zu erreichen. Skaliert, sobald weitere Entwickler hinzukommen.

6. **F-Droid + Direkt-Distribution** — kein Google Play, kein Apple App Store als Abhängigkeit. Die App gehört den Nutzern.

7. **Lokale KI erst ab Phase 3** — Home-Node (Raspberry Pi 5) hostet das LLM. Smartphone fragt lokal an, keine Cloud.

Die größte Stärke: Der Bauplan sagt „Protokoll, nicht Plattform" und „Killer-App zuerst". Wer alles auf einmal baut, baut nichts. Wir bauen den Chat. Dann die Wirtschaft. Dann die Gesellschaft.
