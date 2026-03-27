import 'dart:async';

import '../../core/storage/pod_database.dart';
import 'group_channel.dart';

/// Manages joined and discovered group channels.
///
/// Joined channels are persisted in the POD.  Discovered channels (from Nostr
/// Kind-40 announcements) are kept in memory for the duration of the session.
class GroupChannelService {
  GroupChannelService._();
  static final instance = GroupChannelService._();

  final List<GroupChannel> _joined = [];

  /// Channels discovered via Nostr Kind-40 that the user has not yet joined.
  final List<GroupChannel> _discovered = [];

  final _joinedController =
      StreamController<List<GroupChannel>>.broadcast();

  /// Stream that emits the joined channel list whenever it changes.
  Stream<List<GroupChannel>> get joinedStream => _joinedController.stream;

  List<GroupChannel> get joinedChannels => List.unmodifiable(_joined);

  /// Returns joined + newly discovered channels (deduped by name).
  List<GroupChannel> get allDiscovered {
    final joined = {for (final c in _joined) c.name};
    return [
      ..._joined,
      ..._discovered.where((c) => !joined.contains(c.name)),
    ];
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final rows = await PodDatabase.instance.listChannels();
      _joined
        ..clear()
        ..addAll(rows.map(GroupChannel.fromJson));
    } catch (_) {
      // DB not yet open (e.g. during onboarding).
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  bool isJoined(String name) =>
      _joined.any((c) => c.name == GroupChannel.normaliseName(name));

  GroupChannel? findByName(String name) {
    final n = GroupChannel.normaliseName(name);
    try {
      return _joined.firstWhere((c) => c.name == n);
    } catch (_) {
      try {
        return _discovered.firstWhere((c) => c.name == n);
      } catch (_) {
        return null;
      }
    }
  }

  GroupChannel? findByNostrTag(String tag) {
    try {
      return _joined.firstWhere((c) => c.nostrTag == tag);
    } catch (_) {
      try {
        return _discovered.firstWhere((c) => c.nostrTag == tag);
      } catch (_) {
        return null;
      }
    }
  }

  /// Creates a new channel, persists it, and returns it.
  Future<GroupChannel> createChannel(GroupChannel channel) async {
    _joined.removeWhere((c) => c.name == channel.name);
    _joined.add(channel);
    await PodDatabase.instance.upsertChannel(channel.id, channel.toJson());
    _joinedController.add(joinedChannels);
    return channel;
  }

  /// Marks the channel as joined and persists it.
  Future<GroupChannel> joinChannel(GroupChannel channel) async {
    channel.joinedAt = DateTime.now().toUtc();
    _joined.removeWhere((c) => c.name == channel.name);
    _joined.add(channel);
    _discovered.removeWhere((c) => c.name == channel.name);
    await PodDatabase.instance.upsertChannel(channel.id, channel.toJson());
    _joinedController.add(joinedChannels);
    return channel;
  }

  /// Removes the channel from joined list and deletes from DB.
  Future<void> leaveChannel(String name) async {
    final n = GroupChannel.normaliseName(name);
    final channel = _joined.firstWhere(
      (c) => c.name == n,
      orElse: () => throw StateError('Not joined: $n'),
    );
    _joined.removeWhere((c) => c.name == n);
    await PodDatabase.instance.deleteChannel(channel.id);
    _joinedController.add(joinedChannels);
  }

  /// Called when a Nostr Kind-40 announcement arrives.
  ///
  /// If the channel is already joined, updates its metadata.
  /// Otherwise adds it to the discovered list.
  void addDiscoveredFromNostr(GroupChannel channel) {
    if (_joined.any((c) => c.name == channel.name)) return;
    _discovered.removeWhere((c) => c.name == channel.name);
    _discovered.add(channel);
  }

  /// Ensures default channels are present on first start.
  Future<void> ensureDefaults(String myDid) async {
    if (!isJoined('#nexus-global')) {
      final global = GroupChannel(
        id: 'nexus-global',
        name: '#nexus-global',
        description: 'Der globale NEXUS-Kanal für alle',
        createdBy: myDid,
        createdAt: DateTime.utc(2024, 1, 1),
        nostrTag: 'nexus-channel-nexus-global',
        joinedAt: DateTime.now().toUtc(),
      );
      await joinChannel(global);
    }
  }
}
