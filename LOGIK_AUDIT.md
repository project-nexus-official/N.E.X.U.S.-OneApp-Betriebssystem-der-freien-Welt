# Logik-Audit N.E.X.U.S. OneApp
Datum: 2026-04-06

---

## 🔴 KETTE GEBROCHEN (Feature funktioniert wahrscheinlich nicht)

### 1. Proposals (G1) — KEINE Nostr-Synchronisation
- `ProposalService.publishProposal()` ändert nur den lokalen Status auf DISCUSSION, publiziert aber KEIN Nostr-Event → `lib/features/governance/proposal_service.dart:91-108`
- Kein `publishProposal()`-Gegenstück in `NostrTransport` — keine `Kind-36`-Events oder äquivalente → `lib/core/transport/nostr/nostr_transport.dart` (grep "proposal" = 0 Treffer)
- `ChatProvider` verdrahtet Feed, Cells und Channels, aber KEINE Proposals → `lib/features/chat/chat_provider.dart:180-188`
- **Folge**: Proposals existieren nur lokal auf dem Erstellungsgerät. Andere Zellenmitglieder sehen sie nie. Multi-Device ist vollständig gebrochen.

### 2. Backup & Restore — Nostr-Re-Subscriptions fehlen nach Restore
- `BackupService._applyBackup()` fügt Kontakte, Kanäle, Zellen via `addContactFromBackup()` / `restoreFromBackup()` wieder ein ✓
- Danach wird `NostrTransport._setupSubscriptions()` oder ein Äquivalent NICHT aufgerufen → `lib/services/backup_service.dart:299-310`
- `RestoreBackupScreen` macht nach dem Restore nur ein UI-Update, kein Transport-Re-Init → `lib/features/onboarding/restore_backup_screen.dart:54-68`
- `NostrTransport._setupSubscriptions()` baut `feedAuthors`-Subscription aus `ContactService.instance.contacts` zum Startup-Zeitpunkt — wiederhergestellte Kontakte fehlen in dieser Subscription → `lib/core/transport/nostr/nostr_transport.dart:837-856`
- **Folge**: Nach Restore werden DMs/Feed-Posts von wiederhergestellten Kontakten nicht empfangen, bis die App neu gestartet wird. Kein Hinweis im UI.

### 3. Einladungscodes — kein bidirektionaler Sync (Inviter-Benachrichtigung fehlt)
- `InviteService.redeemEncoded()` fügt den Inviter lokal als Kontakt hinzu und sendet eine DM-Benachrichtigung ✓
- `markRedeemed()` wird nur auf Empfänger-Seite aufgerufen; der Inviter bekommt `redeemedByPseudonym` NICHT gesetzt → `lib/services/invite_service.dart:307-312`
- Der Inviter hat kein `handleIncomingRedemption()`-Handler in `ContactRequestService` oder `ChatProvider`
- Die gesendete DM-Benachrichtigung landet zwar im Chat, wird aber nicht automatisch als "Einladung angenommen" verarbeitet → `lib/services/invite_service.dart:244-302`
- **Folge**: Inviter sieht in `InviteScreen` seine Einladung dauerhaft als "ausstehend", selbst wenn der Empfänger sie bereits eingelöst hat. `InviteRecord.redeemedByPseudonym` bleibt auf dem Inviter-Gerät immer `null`.

---

## 🟡 VERDÄCHTIG (könnte funktionieren, aber riskant)

### 4. Dorfplatz-Posts nach Seed-Restore — Author-Subscription nicht aktualisiert
- Nach Restore werden neue Kontakte via `addContactFromBackup()` hinzugefügt, aber `feedAuthors`-Nostr-Subscription wird nicht erneut aufgesetzt → `lib/core/transport/nostr/nostr_transport.dart:846-855`
- Die tag-basierte Subscription (`["t", "nexus-dorfplatz"]`) ohne Author-Filter sollte Posts trotzdem finden — aber nur innerhalb des 7-Tage-Fensters, nicht mit dem 30-Tage-Fenster der Author-Sub
- **Risiko**: MEDIUM — Funktioniert meistens, aber ältere Posts von frisch wiederhergestellten Kontakten werden evtl. nicht geholt

### 5. Kanal-Mitgliederliste — kein Nostr-Sync
- `GroupChannelService.updateMembers()` speichert Mitglieder nur lokal, publiziert kein Nostr-Event → `lib/features/chat/group_channel_service.dart:104-110`
- Kind-40 (Channel-Create) und Kind-42 (Messages) sind verknüpft, aber keine Mitgliederlisten-Events → `lib/core/transport/nostr/nostr_transport.dart:301-324`
- **Risiko**: MEDIUM-LOW — Funktioniert auf Single-Device, kann auf Multi-Device zu inkonsistenten Mitgliederlisten führen

### 6. Kontaktanfrage-Rate-Limit — Race Condition bei Mehrfachgeräten
- `sendRequest()` prüft Rate Limits gegen die In-Memory `_requests`-Liste, die nur beim Start aus der DB geladen wird → `lib/services/contact_request_service.dart:84-133`
- Zwei parallele Geräte des gleichen Nutzers können das Limit unabhängig reißen, da sie ihre DB-Zustände nicht synchronisieren → `lib/services/contact_request_service.dart:172-175`
- **Risiko**: LOW-MEDIUM — kein Sicherheitsproblem, aber User könnte versehentlich mehr als 10 Anfragen/Tag senden

### 7. Benachrichtigungen — fehlende Trigger für Feed-Kommentare und Reaktionen
- `FeedService.handleIncomingPost()` triggert Notification für Reposts, aber `handleIncomingComment()` hat KEINE Notification → `lib/features/dorfplatz/feed_service.dart:233-266`
- `NostrTransport._handleReaction()` emittet nur `_feedReactionController.add()`, ruft NICHT `NotificationService` auf → `lib/core/transport/nostr/nostr_transport.dart:920-930`
- Zellen-Beitrittsanfragen: Kein dedizierter Notification-Trigger geprüft
- **Risiko**: LOW — Feature-Gap, nicht gebrochen; Core-Notifications (DMs, Channels) funktionieren

### 8. Proposal-Berechtigungsprüfung — `proposalWaitDays` nur lokal
- `ProposalService._checkCanCreateProposal()` prüft Membership-Status und `proposalWaitDays` korrekt → `lib/features/governance/proposal_service.dart:157-180`
- Da Proposals nicht via Nostr synchronisiert werden (→ Punkt 1), kann das Mitglied auf einem zweiten Gerät die Wartezeit umgehen (leere lokale DB → kein existierendes Proposal gefunden)
- **Risiko**: MEDIUM — direkte Folge aus Broken Chain #1

---

## 🟢 KETTE VOLLSTÄNDIG (sieht korrekt verknüpft aus)

### Kontaktanfrage-System (Core Flow)
- `sendRequest()` → NexusMessage via `TransportManager` → `_onMessageReceived()` in ChatProvider → `ContactRequestService.handleIncomingRequest()` → `_streamCtrl.add()` → UI (ContactRequestsScreen StreamBuilder)
- `acceptRequest()` → `ContactService.addContactFromQr()` → `contactsChanged` emitted → Bestätigung per DM → Inviter ruft `handleAcceptance()` → auch `addContactFromQr()` → `contactsChanged` beiderseits
- Bidirektionaler Kontakt-Add ist vollständig implementiert → `lib/services/contact_request_service.dart:84-308`, `lib/features/chat/chat_provider.dart:848-916`

### Zellen-Discovery über Nostr
- `CellService.createCell()` → lokal persistiert → `ChatProvider.publishNostrCellAnnouncement()` → `NostrTransport.publishCellAnnouncement()` → Kind-30000 mit Tag `["t", "nexus-cell"]`
- Remote: Subscription auf Kind-30000 in `_setupSubscriptions()` → `_handleCellAnnounceEvent()` → `_cellAnnouncedController.add()` → `ChatProvider._onCellAnnounced()` → `CellService.addDiscoveredCell()` → `stream` emit → UI
- Kette vollständig → `lib/core/transport/nostr/nostr_transport.dart:372-388, 821-825, 932-946`, `lib/features/chat/chat_provider.dart:286-315`

### Dorfplatz-Posts (Core)
- `FeedService.createPost()` → lokal + Publisher (`NostrTransport.publishFeedEvent()`) → Kind-1 mit Tag `["t", "nexus-dorfplatz"]`
- Remote: Tag-Subscription in `_setupSubscriptions()` → `_handleFeedPost()` → `_feedPostController.add()` → `ChatProvider` (Zeile 183) → `FeedService.handleIncomingPost()` → DB → `stream` emit → UI
- Kette vollständig → `lib/features/dorfplatz/feed_service.dart:85-229`, `lib/core/transport/nostr/nostr_transport.dart:426-438, 830-856`

### Kanal-System (Kind-40/42)
- `createChannel()` → lokal → `NostrTransport.publishChannelCreate()` → Kind-40
- Remote: Kind-40-Discovery-Subscription → `_handleChannelCreateEvent()` → `_channelAnnouncedController` → `ChatProvider._onChannelAnnounced()` → `GroupChannelService.addDiscoveredFromNostr()`
- `subscribeToChannel()` für beigetretene Kanäle → Kind-42 Nachrichten fließen korrekt
- Kette vollständig → `lib/core/transport/nostr/nostr_transport.dart:301-324, 809-818`, `lib/features/chat/chat_provider.dart:228-283`

### Push-Benachrichtigungen (Core-Pfade)
- Chat DM: `_onMessageReceived()` → `NotificationService.showMessageNotification()` → `lib/features/chat/chat_provider.dart:736`
- Broadcast/#mesh: `showBroadcastNotification()` → `lib/features/chat/chat_provider.dart:730`
- Feed Reposts: `FeedService.handleIncomingPost()` → `NotificationService.showGenericNotification()` → `lib/features/dorfplatz/feed_service.dart:219`
- DND-Fenster und `NotificationSettings.enabled` werden in allen Pfaden respektiert

### Dashboard-Karten (Daten + Live-Updates)
- Alle 7 Karten haben korrekte Stream-Subscriptions in `initState()`:
  - Conversations → `ConversationService.stream`
  - NodeCounter → `NodeCounterService.countStream`
  - ContactRequests → `ContactRequestService.stream`
  - FeedPosts → `FeedService.stream`
  - Cells/Proposals → `CellService.stream` / `ProposalService.stream`
  - Updates → `UpdateService.updateStream`
- Alle Subscriptions lösen `setState()` aus → `lib/features/dashboard/dashboard_screen.dart:96-149`
- Navigation der Karten ist korrekt verdrahtet (rootNavigator wo nötig)

### Governance-Berechtigungsprüfungen (lokal)
- `ProposalService._checkCanCreateProposal()` prüft Mitgliedschaft, Rolle (nicht pending), und `proposalWaitDays` korrekt
- `PermissionHelper`-Funktionen sind reine Funktionen ohne Seiteneffekte → testbar
- UI-Screens fangen `StateError` und zeigen Fehlermeldungen an → `lib/features/governance/proposal_service.dart:157-180`

---

## Gesamtübersicht

| # | Feature | Status | Schweregrad |
|---|---------|--------|-------------|
| 1 | Proposals (Nostr-Sync) | 🔴 GEBROCHEN | Kritisch — kein Multi-Device |
| 2 | Backup Restore (Re-Subscriptions) | 🔴 GEBROCHEN | Hoch — Daten kommen nach Restore nicht an |
| 3 | Einladungscodes (Inviter-Sync) | 🔴 GEBROCHEN | Mittel — UI zeigt falschen Status |
| 4 | Dorfplatz nach Restore (Author-Sub) | 🟡 VERDÄCHTIG | Mittel — 7-Tage-Limit |
| 5 | Kanal-Mitgliederliste (Nostr) | 🟡 VERDÄCHTIG | Niedrig — Single-Device OK |
| 6 | Kontaktanfrage-Rate-Limit (Race) | 🟡 VERDÄCHTIG | Niedrig — kein Sicherheitsproblem |
| 7 | Benachrichtigungen (Kommentare/Reaktionen) | 🟡 VERDÄCHTIG | Niedrig — Feature-Gap |
| 8 | Proposal-Wartezeit (Multi-Device) | 🟡 VERDÄCHTIG | Mittel — Folge aus #1 |
| 9 | Kontaktanfrage-System | 🟢 VOLLSTÄNDIG | — |
| 10 | Zellen-Discovery | 🟢 VOLLSTÄNDIG | — |
| 11 | Dorfplatz-Posts (Core) | 🟢 VOLLSTÄNDIG | — |
| 12 | Kanal-System (Kind-40/42) | 🟢 VOLLSTÄNDIG | — |
| 13 | Push-Benachrichtigungen (Core) | 🟢 VOLLSTÄNDIG | — |
| 14 | Dashboard-Karten | 🟢 VOLLSTÄNDIG | — |
| 15 | Governance-Berechtigungen (lokal) | 🟢 VOLLSTÄNDIG | — |

---

## Empfohlene Prioritäten

1. **SOFORT**: Proposals → `NostrTransport.publishProposal()` + Subscription hinzufügen (Kind-36 oder eigener Kind)
2. **SOFORT**: Backup Restore → nach `_applyBackup()` Transport-Re-Subscriptions triggern (z.B. `NostrTransport.instance.resetSubscriptions()`)
3. **BALD**: Einladungscodes → `handleIncomingRedemptionDm()` in ChatProvider/InviteService implementieren
4. **BALD**: Feed-Kommentar-Notifications hinzufügen
5. **SPÄTER**: Kanal-Mitgliederlisten-Sync via Nostr (NIP-28-Extension oder Custom Kind)
