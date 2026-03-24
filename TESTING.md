# NEXUS OneApp – Chat-Test zwischen zwei Geräten

Dieses Dokument beschreibt, wie du den NEXUS-Mesh-Chat zwischen zwei echten
Geräten testest.  Der LAN-Transport ist die einfachste Methode und funktioniert
auf allen Plattformen.

---

## Voraussetzungen

| Gerät   | Plattform          | Befehl                          |
|---------|--------------------|---------------------------------|
| Gerät A | Android-Handy      | `flutter run`                   |
| Gerät B | Windows-Laptop     | `flutter run -d windows`        |

Beide Geräte müssen im **selben WLAN-Netzwerk** sein.

---

## Schritt-für-Schritt

### 1. Projekt aufsetzen

```bash
flutter pub get
```

### 2. Gerät A starten (Android)

```bash
# Handy per USB verbinden
flutter run
```

Onboarding durchlaufen:
- Pseudonym wählen (z. B. „Alice")
- Identität erstellen (kein Wiederherstellen nötig)

### 3. Gerät B starten (Windows)

```bash
flutter run -d windows
```

Onboarding durchlaufen:
- Anderes Pseudonym wählen (z. B. „Bob")
- Identität erstellen

### 4. Chat-Tab öffnen

Auf beiden Geräten den **Chat**-Tab antippen (zweites Icon in der BottomNav).

- Das Radar beginnt zu drehen
- Nach 3–10 Sekunden erscheint der andere Peer in der Liste
- Der Status-Punkt (oben rechts) wechselt von gelb → grün

### 5. Nachricht senden

1. Auf Gerät A den Peer „Bob" antippen
2. Eine Nachricht in das Eingabefeld tippen (z. B. „Hallo Bob!")
3. Senden-Button drücken
4. Auf Gerät B erscheint die Nachricht in der Conversation

### 6. Antwort senden

1. Auf Gerät B den Peer „Alice" antippen (oder Nachricht erscheint direkt)
2. Antwort tippen und senden
3. Auf Gerät A erscheint die Antwort

---

## Verbindungsstatus-Indikatoren

| Farbe  | Bedeutung                              |
|--------|----------------------------------------|
| Grün   | Transport aktiv + Peer(s) gefunden    |
| Gelb   | Transport aktiv, noch keine Peers     |
| Rot    | Kein Transport verfügbar              |

---

## Transport-Icons im Peer-Tab

| Icon       | Bedeutung                   |
|------------|-----------------------------|
| WiFi-Icon  | Peer über LAN erreichbar    |
| BT-Icon    | Peer über Bluetooth (BLE)   |
| Cloud-Icon | Peer über Internet (Nostr)  |

Ein Peer kann mehrere Icons haben, wenn er über mehrere Transports sichtbar ist.

---

## Fehlerbehebung

### Peer wird nicht gefunden

- Beide Geräte im **selben** WLAN-Subnetz?
  (z. B. Hotspot-Modus: Handy als Hotspot, Laptop verbindet sich damit)
- Android: Stelle sicher, dass die App WLAN-Berechtigung hat
- Windows-Firewall: Port **51000/UDP** und **51001/TCP** erlauben

```powershell
# Windows Firewall – Ports freigeben (als Administrator)
netsh advfirewall firewall add rule name="NEXUS UDP" protocol=UDP dir=in localport=51000 action=allow
netsh advfirewall firewall add rule name="NEXUS TCP" protocol=TCP dir=in localport=51001 action=allow
```

### Nachrichten kommen nicht an

- Nachricht signiert? → grüner Haken ✓ in der Bubble
- Peer noch online? → Status-Punkt im Conversation-Screen
- Logs prüfen: `flutter run --verbose`

---

## Tests ausführen

```bash
# Alle Tests
flutter test

# Nur LAN-Tests
flutter test test/core/transport/lan/

# Nur Transport-Manager-Tests
flutter test test/core/transport/transport_manager_test.dart
```

---

## Weitere Szenarien

| Szenario                          | Erwartetes Verhalten                     |
|-----------------------------------|------------------------------------------|
| LAN + BLE gleichzeitig aktiv      | LAN bevorzugt; beide Icons beim Peer     |
| LAN-Verbindung trennen            | Peer bleibt via BLE; LAN-Icon verschwindet nach ~15 s |
| Offline (kein WLAN)               | BLE-Transport übernimmt (Mobilgeräte)    |
| Gerät C kommt dazu                | Radar zeigt 2 Peers; Direktnachrichten möglich |
