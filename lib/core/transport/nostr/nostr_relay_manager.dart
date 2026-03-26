import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr_event.dart';

/// Default public Nostr relays.
const defaultRelays = [
  'wss://relay.damus.io',
  'wss://relay.snort.social',
  'wss://nos.lol',
  'wss://relay.nostr.band',
  'wss://nostr.wine',
];

/// Connection state of a single relay.
enum RelayState { disconnected, connecting, connected, error }

/// Status of a relay (URL + state + latency).
class RelayStatus {
  final String url;
  RelayState state;
  int? latencyMs;

  RelayStatus(this.url) : state = RelayState.disconnected;
}

/// Manages WebSocket connections to a pool of Nostr relays.
///
/// Responsibilities:
///   - Connect/reconnect to all configured relays.
///   - Publish events to every connected relay.
///   - Maintain NIP-01 subscriptions and forward received events.
///   - Track relay health (state, latency).
class NostrRelayManager {
  NostrRelayManager({List<String>? relayUrls}) {
    for (final url in relayUrls ?? defaultRelays) {
      _statuses[url] = RelayStatus(url);
    }
  }

  // relay URL → status
  final Map<String, RelayStatus> _statuses = {};

  // relay URL → open WebSocket channel
  final Map<String, WebSocketChannel> _channels = {};

  // relay URL → subscription to its stream
  final Map<String, StreamSubscription<dynamic>> _channelSubs = {};

  // relay URL → pending reconnect timer
  final Map<String, Timer> _reconnectTimers = {};

  // Active subscriptions: subId → filter JSON
  final Map<String, Map<String, dynamic>> _subscriptions = {};

  final _eventController = StreamController<NostrEvent>.broadcast();

  bool _running = false;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Stream of all incoming events across all relays (deduplicated by ID).
  Stream<NostrEvent> get onEvent => _eventController.stream;

  /// Snapshot of all relay statuses.
  List<RelayStatus> get statuses => List.unmodifiable(_statuses.values);

  /// Whether any relay is currently connected.
  bool get hasConnectedRelay =>
      _statuses.values.any((s) => s.state == RelayState.connected);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Opens connections to all configured relays.
  Future<void> start() async {
    _running = true;
    for (final url in _statuses.keys) {
      _connect(url);
    }
  }

  /// Closes all relay connections and cancels timers.
  Future<void> stop() async {
    _running = false;
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    for (final sub in _channelSubs.values) {
      await sub.cancel();
    }
    _channelSubs.clear();
    for (final ch in _channels.values) {
      await ch.sink.close();
    }
    _channels.clear();
    for (final s in _statuses.values) {
      s.state = RelayState.disconnected;
    }
  }

  // ── Relay management ──────────────────────────────────────────────────────

  /// Adds a custom relay URL. Connects immediately if [start] was called.
  void addRelay(String url) {
    if (_statuses.containsKey(url)) return;
    _statuses[url] = RelayStatus(url);
    if (_running) _connect(url);
  }

  /// Removes a relay by URL and closes its connection.
  Future<void> removeRelay(String url) async {
    _reconnectTimers.remove(url)?.cancel();
    await _channelSubs.remove(url)?.cancel();
    await _channels.remove(url)?.sink.close();
    _statuses.remove(url);
  }

  // ── Publish ───────────────────────────────────────────────────────────────

  /// Publishes [event] to all connected relays.
  void publish(NostrEvent event) {
    final msg = jsonEncode(['EVENT', event.toJson()]);
    for (final entry in _channels.entries) {
      final url = entry.key;
      if (_statuses[url]?.state == RelayState.connected) {
        try {
          entry.value.sink.add(msg);
        } catch (_) {}
      }
    }
  }

  // ── Subscriptions ─────────────────────────────────────────────────────────

  /// Subscribes to events matching [filter] across all relays.
  ///
  /// Returns the subscription ID. Use [closeSubscription] to stop.
  String subscribe(Map<String, dynamic> filter) {
    final subId = generateSubId();
    _subscriptions[subId] = filter;
    final msg = jsonEncode(['REQ', subId, filter]);
    for (final entry in _channels.entries) {
      if (_statuses[entry.key]?.state == RelayState.connected) {
        try {
          entry.value.sink.add(msg);
        } catch (_) {}
      }
    }
    return subId;
  }

  /// Closes the subscription with [subId].
  void closeSubscription(String subId) {
    _subscriptions.remove(subId);
    final msg = jsonEncode(['CLOSE', subId]);
    for (final entry in _channels.entries) {
      if (_statuses[entry.key]?.state == RelayState.connected) {
        try {
          entry.value.sink.add(msg);
        } catch (_) {}
      }
    }
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  void _connect(String url) {
    if (!_running) return;
    _statuses[url]?.state = RelayState.connecting;
    print('[NOSTR] Connecting to $url …');

    final connectStart = DateTime.now().millisecondsSinceEpoch;
    late WebSocketChannel channel;

    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      print('[NOSTR] $url – sync connect error: $e');
      _statuses[url]?.state = RelayState.error;
      _scheduleReconnect(url);
      return;
    }

    _channels[url] = channel;

    // channel.ready completes when the WebSocket handshake succeeds.
    // This is the correct place to mark a relay as connected and send
    // initial subscriptions – not on the first received message, because
    // relays only send data AFTER we send a REQ.
    channel.ready.then((_) {
      if (!_running) return;
      final latency = DateTime.now().millisecondsSinceEpoch - connectStart;
      print('[NOSTR] $url – connected (${latency}ms)');
      _statuses[url]?.latencyMs = latency;
      _statuses[url]?.state = RelayState.connected;
      _resubscribe(url);
    }).catchError((Object e) {
      print('[NOSTR] $url – handshake error: $e');
      _statuses[url]?.state = RelayState.error;
      _channels.remove(url);
      _scheduleReconnect(url);
    });

    final sub = channel.stream.listen(
      (data) => _handleMessage(url, data as String),
      onError: (Object e) {
        print('[NOSTR] $url – stream error: $e');
        _statuses[url]?.state = RelayState.error;
        _channels.remove(url);
        _scheduleReconnect(url);
      },
      onDone: () {
        if (_statuses[url]?.state != RelayState.disconnected) {
          print('[NOSTR] $url – disconnected, scheduling reconnect');
          _statuses[url]?.state = RelayState.error;
          _channels.remove(url);
          _scheduleReconnect(url);
        }
      },
    );

    _channelSubs[url]?.cancel();
    _channelSubs[url] = sub;
  }

  void _scheduleReconnect(String url) {
    if (!_running) return;
    print('[NOSTR] $url – reconnect in 10s');
    _reconnectTimers[url]?.cancel();
    _reconnectTimers[url] = Timer(const Duration(seconds: 10), () {
      if (_running) _connectSafe(url);
    });
  }

  Future<void> _connectSafe(String url) async {
    try {
      _connect(url);
    } catch (_) {
      _statuses[url]?.state = RelayState.error;
      _scheduleReconnect(url);
    }
  }

  void _resubscribe(String url) {
    final channel = _channels[url];
    if (channel == null) return;
    print('[NOSTR] $url – resubscribing ${_subscriptions.length} filters');
    for (final entry in _subscriptions.entries) {
      try {
        final since = entry.value['since'];
        print('[NOSTR]   REQ ${entry.key.substring(0, 8)} '
            'kinds=${entry.value['kinds']} since=$since');
        print('[SYNC] Relay connected: ${_shortUrl(url)}  '
            'sending REQ ${entry.key.substring(0, 8)} since=$since');
        channel.sink.add(jsonEncode(['REQ', entry.key, entry.value]));
      } catch (_) {}
    }
  }

  /// Seen event IDs for relay-level deduplication.
  final Set<String> _seenEventIds = {};

  static String _shortUrl(String url) =>
      url.replaceAll('wss://', '').replaceAll('ws://', '');

  void _handleMessage(String url, String data) {
    try {
      final msg = jsonDecode(data) as List<dynamic>;
      if (msg.isEmpty) return;

      switch (msg[0] as String) {
        case 'EVENT':
          if (msg.length < 3) return;
          final eventJson = msg[2] as Map<String, dynamic>;
          final event = NostrEvent.fromJson(eventJson);

          print('[NOSTR] ← EVENT kind=${event.kind} '
              'id=${event.id.substring(0, 8)} '
              'from=${event.pubkey.substring(0, 8)} '
              'created_at=${event.createdAt} '
              '(relay: ${_shortUrl(url)})');

          // Relay-level deduplication
          final isNew = !_seenEventIds.contains(event.id);
          print('[SYNC] Event is new: $isNew  id=${event.id.substring(0, 8)}');
          if (!isNew) return;
          if (_seenEventIds.length > 5000) _seenEventIds.clear();
          _seenEventIds.add(event.id);

          _eventController.add(event);

        case 'NOTICE':
          print('[NOSTR] NOTICE from ${_shortUrl(url)}: ${msg.length > 1 ? msg[1] : ""}');

        case 'EOSE':
          print('[NOSTR] EOSE from ${_shortUrl(url)} sub=${msg.length > 1 ? (msg[1] as String).substring(0, 8) : "?"}');
      }
    } catch (_) {
      // Malformed message – ignore
    }
  }
}
