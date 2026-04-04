import 'dart:async';

import 'package:flutter/foundation.dart';

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
      debugPrint('[CHANNELS] Loaded ${_joined.length} joined channels from DB');
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

  GroupChannel? findById(String id) {
    try {
      return _joined.firstWhere((c) => c.id == id);
    } catch (_) {
      try {
        return _discovered.firstWhere((c) => c.id == id);
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

  /// Replaces the stored channel with [updated] and persists it.
  Future<void> updateChannel(GroupChannel updated) async {
    final idx = _joined.indexWhere((c) => c.id == updated.id);
    if (idx < 0) return;
    _joined[idx] = updated;
    await PodDatabase.instance.upsertChannel(updated.id, updated.toJson());
    _joinedController.add(joinedChannels);
  }

  /// Updates the member list of a joined channel and persists it.
  Future<void> updateMembers(String name, List<String> newMembers) async {
    final n = GroupChannel.normaliseName(name);
    final channel = _joined.firstWhere((c) => c.name == n,
        orElse: () => throw StateError('Channel not found: $n'));
    channel.members = List.from(newMembers);
    await PodDatabase.instance.upsertChannel(channel.id, channel.toJson());
    _joinedController.add(joinedChannels);
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
  /// Adds the channel to the discovered list unless it is hidden
  /// (isDiscoverable == false) or already joined.
  void addDiscoveredFromNostr(GroupChannel channel) {
    if (!channel.isDiscoverable) return; // hidden channels not in discovery
    if (_joined.any((c) => c.name == channel.name)) return;
    _discovered.removeWhere((c) => c.name == channel.name);
    _discovered.add(channel);
  }

  /// Restores a channel from a backup JSON map (merge – only adds if not
  /// already joined).  Called by [BackupService].
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    try {
      final channel = GroupChannel.fromJson(json);
      if (_joined.any((c) => c.id == channel.id)) return;
      _joined.add(channel);
      await PodDatabase.instance.upsertChannel(channel.id, json);
      _joinedController.add(joinedChannels);
    } catch (e) {
      debugPrint('[CHANNELS] restoreFromBackup error: $e');
    }
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
