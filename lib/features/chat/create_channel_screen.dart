import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../shared/theme/app_theme.dart';
import 'chat_provider.dart';
import 'group_channel.dart';
import 'group_channel_service.dart';

/// Screen to create a new named group channel.
class CreateChannelScreen extends StatefulWidget {
  const CreateChannelScreen({super.key});

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _creating = false;
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  String _normalisedName() {
    final raw = _nameController.text.trim();
    return GroupChannel.normaliseName(raw);
  }

  Future<void> _create() async {
    setState(() => _nameError = null);

    final name = _normalisedName();
    final bare = name.startsWith('#') ? name.substring(1) : name;

    if (!GroupChannel.isValidName(bare)) {
      setState(() => _nameError =
          'Nur Kleinbuchstaben, Ziffern und Bindestriche erlaubt (2–50 Zeichen).');
      return;
    }

    if (GroupChannelService.instance.isJoined(name)) {
      setState(() => _nameError = 'Du bist diesem Kanal bereits beigetreten.');
      return;
    }

    setState(() => _creating = true);

    final myDid =
        IdentityService.instance.currentIdentity?.did ?? 'unknown';

    final channel = GroupChannel.create(
      name: name,
      description: _descController.text.trim(),
      createdBy: myDid,
    );

    await GroupChannelService.instance.createChannel(channel);

    if (!mounted) return;

    // Publish Kind-40 announcement on Nostr.
    final nostr = context.read<ChatProvider>().nostrTransport;
    nostr?.publishChannelCreate(channel.toJson());
    nostr?.subscribeToChannel(channel.nostrTag);

    Navigator.of(context).pop(channel);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kanal erstellen')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Neuen Gruppenkanal erstellen',
              style: TextStyle(
                color: AppColors.gold,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Öffentliche Kanäle können von allen NEXUS-Nutzern gefunden und '
              'betreten werden.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              style: const TextStyle(color: AppColors.onDark),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Kanalname',
                hintText: 'teneriffa',
                prefixText: '#',
                prefixStyle: const TextStyle(
                    color: AppColors.gold, fontWeight: FontWeight.bold),
                errorText: _nameError,
                helperText: 'Kleinbuchstaben, Ziffern, Bindestriche',
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: AppColors.onDark),
              decoration: InputDecoration(
                labelText: 'Beschreibung (optional)',
                hintText: 'Worum geht es in diesem Kanal?',
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            // Preview of the channel name.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _nameController,
              builder: (context2, value, child2) {
                if (value.text.trim().isEmpty) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.tag, color: AppColors.gold, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _normalisedName(),
                        style: const TextStyle(
                          color: AppColors.gold,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('Kanal erstellen'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _creating ? null : _create,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
