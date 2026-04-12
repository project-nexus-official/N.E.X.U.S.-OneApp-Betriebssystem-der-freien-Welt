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

  /// In-memory set of channel IDs that have been tombstoned (deleted by user).
  /// Loaded from DB at startup so discovered channels cannot re-appear after
  /// a restart.
  Set<String> _deletedChannelIds = {};

  /// In-memory set of normalised channel NAMES that have been tombstoned.
  /// Guards against re-discovery when a channel comes back with a different UUID.
  Set<String> _deletedChannelNames = {};

  final _joinedController =
      StreamController<List<GroupChannel>>.broadcast();

  /// Stream that emits the joined channel list whenever it changes.
  Stream<List<GroupChannel>> get joinedStream => _joinedController.stream;

  final _channelChangedController = StreamController<void>.broadcast();

  /// Fires whenever _joined or _discovered changes (use to rebuild the
  /// channel tab which shows both sections).
  Stream<void> get channelChangedStream => _channelChangedController.stream;

  List<GroupChannel> get joinedChannels => List.unmodifiable(_joined);

  /// Joined channels that are NOT cell-internal (shown in the Kanäle tab).
  List<GroupChannel> get joinedPublicChannels =>
      _joined.where((c) => c.cellId == null).toList();

  /// Returns cell-internal channels for the given [cellId].
  List<GroupChannel> cellChannelsFor(String cellId) =>
      _joined.where((c) => c.cellId == cellId).toList();

  /// Returns joined + newly discovered channels (deduped by name).
  List<GroupChannel> get allDiscovered {
    final joined = {for (final c in _joined) c.name};
    return [
      ..._joined,
      ..._discovered.where((c) => !joined.contains(c.name)),
    ];
  }

  /// Channels that are discovered via Nostr but not yet joined by the user.
  List<GroupChannel> get discoveredOnlyChannels =>
      _discovered.where((c) => !_joined.any((j) => j.name == c.name)).toList();

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      // Load tombstones FIRST so we can filter _joined against them immediately.
      _deletedChannelIds = await PodDatabase.instance.listDeletedChannelIds();
      _deletedChannelNames = await PodDatabase.instance.listDeletedChannelNames();
      debugPrint('[CHANNEL-LOAD] Tombstones geladen: '
          '${_deletedChannelIds.length} IDs, '
          '${_deletedChannelNames.length} Namen');
      debugPrint('[CHANNEL-LOAD] Tombstone IDs: $_deletedChannelIds');
      debugPrint('[CHANNEL-LOAD] Tombstone Namen: $_deletedChannelNames');

      final allRows = await PodDatabase.instance.listChannels();
      final all = allRows.map(GroupChannel.fromJson).toList();

      // Debug: byte-level comparison to detect whitespace/encoding issues.
      for (final ch in all) {
        final chId = ch.id.trim();
        debugPrint('[CHANNEL-LOAD] Checking channel: id=$chId name=${ch.name}');
        if (_deletedChannelIds.isNotEmpty) {
          final tombstone = _deletedChannelIds.first;
          debugPrint('[CHANNEL-LOAD-DEBUG] chId bytes: ${chId.codeUnits}');
          debugPrint('[CHANNEL-LOAD-DEBUG] tombstone bytes: ${tombstone.codeUnits}');
          debugPrint('[CHANNEL-LOAD-DEBUG] contains(raw): ${_deletedChannelIds.contains(ch.id)}');
          debugPrint('[CHANNEL-LOAD-DEBUG] contains(trimmed): ${_deletedChannelIds.contains(chId)}');
        }
      }

      // Normalise IDs with trim() to guard against whitespace artefacts.
      // Filter out tombstoned channels so they never reappear in the UI.
      final active = all
          .where((ch) =>
              !_deletedChannelIds.contains(ch.id.trim()) &&
              !_deletedChannelNames.contains(ch.name.trim()))
          .toList();
      final deletedOnes = all
          .where((ch) =>
              _deletedChannelIds.contains(ch.id.trim()) ||
              _deletedChannelNames.contains(ch.name.trim()))
          .toList();

      _joined
        ..clear()
        ..addAll(active);

      debugPrint('[CHANNEL-LOAD] Loaded ${_joined.length} channels from DB '
          '(${all.length} total in DB)');
      debugPrint('[CHANNEL-LOAD] Filtered ${deletedOnes.length} deleted channels: '
          '${deletedOnes.map((c) => c.name).toList()}');
      for (final ch in _joined) {
        debugPrint('[CHANNEL-LOAD]   • ${ch.name} id=${ch.id}');
      }
    } catch (e) {
      debugPrint('[CHANNEL-LOAD] Error: $e');
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

  /// Returns the channel whose Kind-40 Nostr event ID matches [eventId], or
  /// null if no such channel is found in memory.  Used by the Kind-5 receiver
  /// to translate Nostr event IDs back to internal channel UUIDs.
  GroupChannel? findByNostrEventId(String eventId) {
    try {
      return _joined.firstWhere((c) => c.nostrEventId == eventId);
    } catch (_) {
      try {
        return _discovered.firstWhere((c) => c.nostrEventId == eventId);
      } catch (_) {
        return null;
      }
    }
  }

  /// Updates the [nostrEventId] for the in-memory channel and persists it.
  ///
  /// Called after [publishChannelCreate] returns the real Nostr event ID.
  Future<void> setNostrEventId(String channelId, String nostrEventId) async {
    final idx = _joined.indexWhere((c) => c.id == channelId);
    if (idx >= 0) {
      _joined[idx] = _joined[idx].copyWith(nostrEventId: nostrEventId);
    }
    await PodDatabase.instance.setChannelNostrEventId(channelId, nostrEventId);
    // Also update the enc blob so restores include the nostrEventId.
    final updated = idx >= 0 ? _joined[idx] : null;
    if (updated != null) {
      await PodDatabase.instance.upsertChannel(channelId, updated.toJson());
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
    _channelChangedController.add(null);
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
    _channelChangedController.add(null);
    return channel;
  }

  /// Removes the channel from joined list, sets a tombstone, and deletes from
  /// DB so it cannot re-appear after restart via Nostr discovery.
  Future<void> leaveChannel(String name) async {
    final n = GroupChannel.normaliseName(name);
    final channel = _joined.firstWhere(
      (c) => c.name == n,
      orElse: () => throw StateError('Not joined: $n'),
    );
    debugPrint('[CHANNEL-DELETE] Deleting channel: ${channel.id} name=${channel.name}');

    final joinedCount = _joined.where((c) => c.name == n).length;
    final discoveredCount = _discovered.where((c) => c.name == n).length;

    _joined.removeWhere((c) => c.name == n);
    _discovered.removeWhere((c) => c.name == n);
    debugPrint('[CHANNEL-DELETE] Aus _joined und _discovered entfernt '
        '(joined=$joinedCount, discovered=$discoveredCount)');

    // Tombstone prevents this channel from re-appearing via Nostr discovery
    // after restart. We tombstone both ID and name because a re-discovered
    // channel may arrive with a different UUID.
    // Trim to avoid whitespace artefacts causing lookup misses.
    _deletedChannelIds.add(channel.id.trim());
    _deletedChannelNames.add(channel.name.trim());
    try {
      await PodDatabase.instance.addDeletedChannel(channel.id.trim());
      await PodDatabase.instance.addDeletedChannelName(channel.name.trim());
      debugPrint('[CHANNEL-DELETE] Tombstone gesetzt: id=${channel.id} name=${channel.name}');
    } catch (e) {
      debugPrint('[CHANNEL-DELETE] Tombstone FAILED: $e');
    }

    try {
      await PodDatabase.instance.deleteChannel(channel.id);
      debugPrint('[CHANNEL-DELETE] DB delete: success id=${channel.id}');
    } catch (e) {
      debugPrint('[CHANNEL-DELETE] DB delete: FAILED — $e');
    }

    _joinedController.add(joinedChannels);
    _channelChangedController.add(null);
  }

  /// Marks a channel as deleted when a Kind-5 deletion event is received from
  /// another peer.  Handles both joined and discovered channels.
  Future<void> markChannelDeletedLocally(String channelId) async {
    if (_deletedChannelIds.contains(channelId)) return; // already tombstoned

    _deletedChannelIds.add(channelId);
    await PodDatabase.instance.addDeletedChannel(channelId);

    // Remove from _joined (if present) and delete from DB.
    GroupChannel? joinedChannel;
    try {
      joinedChannel = _joined.firstWhere((c) => c.id == channelId);
    } catch (_) {}
    if (joinedChannel != null) {
      // Also tombstone by name so discovery cannot re-add it.
      _deletedChannelNames.add(joinedChannel.name);
      await PodDatabase.instance.addDeletedChannelName(joinedChannel.name);
      _joined.removeWhere((c) => c.id == channelId);
      try {
        await PodDatabase.instance.deleteChannel(channelId);
      } catch (_) {}
    }

    // Remove from _discovered (if present).
    _discovered.removeWhere((c) => c.id == channelId);

    _joinedController.add(joinedChannels);
    _channelChangedController.add(null);
    debugPrint('[CHANNEL-DELETE-RECV] Kanal lokal gelöscht + tombstone: $channelId');
  }

  /// Called when a Nostr Kind-40 announcement arrives.
  ///
  /// Skips channels that have been tombstoned (deleted by this user).
  /// Adds the channel to the discovered list unless it is hidden
  /// (isDiscoverable == false) or already joined.
  void addDiscoveredFromNostr(GroupChannel channel) {
    final isJoined = _joined.any((c) => c.name == channel.name);
    print('[CHANNEL-SYNC] Kind-40 empfangen: ${channel.name} → joined=$isJoined '
        'id=${channel.id}');
    if (_deletedChannelIds.contains(channel.id.trim()) ||
        _deletedChannelNames.contains(channel.name.trim())) {
      print('[CHANNEL-SYNC] Überspringe gelöschten Kanal: ${channel.id} '
          'name=${channel.name}');
      return;
    }
    if (!channel.isDiscoverable) {
      print('[CHANNEL-SYNC] Überspringe nicht-öffentlichen Kanal: ${channel.name}');
      return;
    }
    if (isJoined) return;
    _discovered.removeWhere((c) => c.name == channel.name);
    _discovered.add(channel);
    _channelChangedController.add(null);
    print('[CHANNEL-SYNC] Zu discovered hinzugefügt: ${channel.name}');
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
