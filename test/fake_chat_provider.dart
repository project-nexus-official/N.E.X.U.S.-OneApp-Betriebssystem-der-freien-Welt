import 'package:nexus_oneapp/core/transport/nexus_peer.dart';
import 'package:nexus_oneapp/features/chat/chat_provider.dart';

/// Minimal stub of [ChatProvider] for widget tests.
///
/// Extends the real [ChatProvider] so that [context.read<ChatProvider>()]
/// resolves correctly. All network/DB operations are no-ops.
class FakeChatProvider extends ChatProvider {
  // ChatProvider() calls TransportManager.instance – safe, no I/O side effects.

  @override
  bool get running => false;

  @override
  List<NexusPeer> get peers => const [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> deleteConversation(String conversationId) async {}

  @override
  void clearAllCaches() {}
}
