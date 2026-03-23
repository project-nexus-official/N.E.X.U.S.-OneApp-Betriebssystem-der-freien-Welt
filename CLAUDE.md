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

## Aktueller Fokus
>>> PHASE 1a: Fundament + Identität <<<

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
