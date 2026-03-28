import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact_service.dart';
import '../../core/transport/nostr/nostr_keys.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';
import 'qr_contact_payload.dart';

/// Parses any supported key/DID format into a [QrContactPayload].
///
/// Accepts (in order):
/// 1. NEXUS contact JSON (`{"type":"nexus-contact",...}`)
/// 2. `did:key:...` DID string
/// 3. `npub1...` Nostr bech32-encoded public key
/// 4. 64-char lowercase/uppercase hex (raw secp256k1 public key)
QrContactPayload? tryParseAnyKey(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  // 1. Full NEXUS contact JSON
  final fromJson = QrContactPayload.tryParse(text);
  if (fromJson != null) return fromJson;

  // 2. bare did:key:...
  if (text.startsWith('did:key:')) {
    final pseudo = text.length > 20
        ? '${text.substring(0, 12)}…${text.substring(text.length - 6)}'
        : text;
    return QrContactPayload(did: text, pseudonym: pseudo);
  }

  // 3. npub1... Nostr bech32 public key
  if (text.startsWith('npub1') && text.length > 10) {
    try {
      final bytes = NostrKeys.bech32Decode('npub', text);
      final hex =
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final shortNpub =
          text.length > 14 ? 'npub…${text.substring(text.length - 8)}' : text;
      return QrContactPayload(
        did: 'did:nostr:$hex',
        pseudonym: shortNpub,
        nostrPubkey: hex,
      );
    } catch (_) {
      return null;
    }
  }

  // 4. 64-char hex (raw secp256k1 / Nostr public key)
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
    final hex = text.toLowerCase();
    return QrContactPayload(
      did: 'did:nostr:$hex',
      pseudonym: '${hex.substring(0, 8)}…${hex.substring(56)}',
      nostrPubkey: hex,
    );
  }

  return null;
}

/// Shows a dialog (desktop) or bottom sheet (mobile) for manually entering
/// a contact's public key or DID.
///
/// Adds the contact with [TrustLevel.discovered] and triggers Nostr Kind-0
/// resolution for the display name.
Future<void> showManualKeyInputDialog(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  final isDesktop =
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  if (isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Kontakt hinzufügen',
          style: TextStyle(
              color: AppColors.gold, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 400,
          child: _ManualKeyInputForm(
            messenger: messenger,
            onDone: () => Navigator.of(ctx).pop(),
          ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        actionsPadding: EdgeInsets.zero,
        actions: const [],
      ),
    );
  } else {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: _ManualKeyInputForm(
          messenger: messenger,
          onDone: () => Navigator.of(ctx).pop(),
          showHeader: true,
        ),
      ),
    );
  }
}

// ── Form widget (shared between dialog and bottom sheet) ────────────────────

class _ManualKeyInputForm extends StatefulWidget {
  final ScaffoldMessengerState messenger;
  final VoidCallback onDone;

  /// When true, renders a drag handle and title (for the bottom-sheet variant).
  final bool showHeader;

  const _ManualKeyInputForm({
    required this.messenger,
    required this.onDone,
    this.showHeader = false,
  });

  @override
  State<_ManualKeyInputForm> createState() => _ManualKeyInputFormState();
}

class _ManualKeyInputFormState extends State<_ManualKeyInputForm> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      setState(() {
        _ctrl.text = data!.text!.trim();
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Bitte einen Schlüssel eingeben');
      return;
    }
    final payload = tryParseAnyKey(text);
    if (payload == null) {
      setState(() => _error =
          'Kein gültiger Schlüssel erkannt.\nAkzeptiert: did:key:…, npub1…, 64-stelliger Hex');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final contact = await ContactService.instance.addContact(
        payload.did,
        payload.pseudonym,
      );
      if (payload.nostrPubkey != null) {
        await ContactService.instance.setNostrPubkey(
            payload.did, payload.nostrPubkey!);
        try {
          if (mounted) {
            context
                .read<ChatProvider>()
                .nostrTransport
                ?.registerDidMapping(payload.did, payload.nostrPubkey!);
          }
        } catch (_) {
          // ChatProvider not in scope – mapping will be resolved on next start.
        }
      }
      if (mounted) {
        widget.onDone();
        widget.messenger.showSnackBar(
          SnackBar(
            content: Text('Kontakt hinzugefügt: ${contact.pseudonym}'),
            backgroundColor: AppColors.surface,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Bottom-sheet header (drag handle + title) ──────────────────────
        if (widget.showHeader) ...[
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Kontakt hinzufügen',
            style: TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 16),
        ],

        // ── Hint text ──────────────────────────────────────────────────────
        const Text(
          'Öffentlichen Netzwerkschlüssel oder DID des Kontakts einfügen:',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),

        // ── Key input ──────────────────────────────────────────────────────
        TextField(
          controller: _ctrl,
          style: const TextStyle(color: AppColors.onDark, fontSize: 13),
          maxLines: 3,
          minLines: 1,
          onChanged: (_) => setState(() => _error = null),
          decoration: InputDecoration(
            hintText: 'did:key:z6Mk…  ·  npub1…  ·  64-stelliger Hex',
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
            errorText: _error,
            errorMaxLines: 2,
            filled: true,
            fillColor: AppColors.surfaceVariant,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: AppColors.gold, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: AppColors.gold, width: 2),
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste,
                  color: AppColors.gold, size: 20),
              tooltip: 'Aus Zwischenablage einfügen',
              onPressed: _paste,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Submit button ──────────────────────────────────────────────────
        ElevatedButton.icon(
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.deepBlue),
                )
              : const Icon(Icons.person_add_outlined),
          label: const Text('Kontakt hinzufügen',
              style: TextStyle(fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: widget.onDone,
          child:
              const Text('Abbrechen', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}
