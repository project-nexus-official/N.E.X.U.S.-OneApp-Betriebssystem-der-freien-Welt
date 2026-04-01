import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/crypto/encryption_keys.dart';
import '../../core/identity/identity_service.dart';
import '../../services/invite_service.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';

/// Full-screen invite hub: generate invite codes, share them, and view sent
/// invites with their redemption status.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  InviteRecord? _activeRecord;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _loadOrGenerate();
  }

  Future<void> _loadOrGenerate() async {
    await InviteService.instance.load();
    // Use the most recent pending invite if it hasn't expired.
    final existing = InviteService.instance.invites
        .where((r) {
          final payload = InvitePayload.tryDecode(r.encoded);
          return payload != null && !payload.isExpired && r.isPending;
        })
        .toList();
    if (existing.isNotEmpty) {
      if (mounted) setState(() => _activeRecord = existing.first);
    } else {
      await _generateNew();
    }
  }

  Future<void> _generateNew() async {
    final identity = IdentityService.instance.currentIdentity;
    if (identity == null) return;
    if (mounted) setState(() => _generating = true);

    final xpub = EncryptionKeys.instance.publicKeyHex ?? '';
    final npub = context.read<ChatProvider>().nostrTransport?.keys?.publicKeyHex ?? '';

    final record = await InviteService.instance.generateInviteCode(
      did: identity.did,
      pseudonym: identity.pseudonym,
      xpub: xpub,
      npub: npub,
    );
    if (mounted) setState(() {
      _activeRecord = record;
      _generating = false;
    });
  }

  void _copyCode() {
    if (_activeRecord == null) return;
    Clipboard.setData(ClipboardData(text: _activeRecord!.displayCode));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Code kopiert'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _share() {
    if (_activeRecord == null) return;
    final text = InviteService.instance.buildShareText(_activeRecord!);
    Share.share(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Freunde einladen'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
      ),
      body: SafeArea(
        child: _generating
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.gold))
            : ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                children: [
                  _InviteHeroCard(
                    record: _activeRecord,
                    onCopy: _copyCode,
                    onShare: _share,
                    onNew: _generateNew,
                  ),
                  const SizedBox(height: 24),
                  if (InviteService.instance.invites.isNotEmpty) ...[
                    const Text(
                      'Gesendete Einladungen',
                      style: TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...InviteService.instance.invites
                        .map((r) => _InviteRecordTile(record: r)),
                  ],
                ],
              ),
      ),
    );
  }
}

// ── Hero card ─────────────────────────────────────────────────────────────────

class _InviteHeroCard extends StatelessWidget {
  final InviteRecord? record;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onNew;

  const _InviteHeroCard({
    required this.record,
    required this.onCopy,
    required this.onShare,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    final deepLink = record != null
        ? InviteService.instance.buildDeepLink(record!)
        : null;
    final payload = record != null
        ? InvitePayload.tryDecode(record!.encoded)
        : null;
    final expiryStr = payload != null
        ? 'Gültig bis ${payload.expires.day.toString().padLeft(2, '0')}.'
            '${payload.expires.month.toString().padLeft(2, '0')}.'
            '${payload.expires.year}'
        : '';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: AppColors.gold.withValues(alpha: 0.6), width: 1.5),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text(
            'Teile deinen Einladungscode',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Sobald dein Freund die App installiert und den Code eingibt,'
            ' seid ihr sofort verbunden.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),

          // QR code
          if (deepLink != null)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(10),
              child: QrImageView(
                data: deepLink,
                version: QrVersions.auto,
                size: 180,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square, color: Color(0xFF000000)),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF000000)),
              ),
            ),
          const SizedBox(height: 16),

          // Display code
          if (record != null) ...[
            GestureDetector(
              onTap: onCopy,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      record!.displayCode,
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.copy_outlined,
                        color: AppColors.gold, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              expiryStr,
              style: TextStyle(
                color: AppColors.onDark.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 20),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  key: const Key('invite_share_button'),
                  onPressed: record != null ? onShare : null,
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Teilen'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                key: const Key('invite_new_button'),
                onPressed: onNew,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Neu'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  side: const BorderSide(color: AppColors.gold),
                  padding: const EdgeInsets.symmetric(
                      vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Invite record tile ────────────────────────────────────────────────────────

class _InviteRecordTile extends StatelessWidget {
  final InviteRecord record;

  const _InviteRecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        leading: Icon(
          record.isPending
              ? Icons.hourglass_empty
              : Icons.check_circle_outline,
          color: record.isPending
              ? AppColors.onDark.withValues(alpha: 0.4)
              : AppColors.gold,
          size: 20,
        ),
        title: Text(
          record.displayCode,
          style: const TextStyle(
            color: AppColors.onDark,
            fontFamily: 'monospace',
            letterSpacing: 1,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          record.isPending
              ? 'Noch nicht eingelöst'
              : 'Eingelöst von ${record.redeemedByPseudonym}',
          style: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.55),
            fontSize: 12,
          ),
        ),
        trailing: Text(
          '${record.createdAt.day.toString().padLeft(2, '0')}.'
          '${record.createdAt.month.toString().padLeft(2, '0')}.'
          '${record.createdAt.year}',
          style: TextStyle(
            color: AppColors.onDark.withValues(alpha: 0.4),
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

// ── Redeem shortcut ───────────────────────────────────────────────────────────

/// Small banner shown at the bottom of InviteScreen to enter a received code.
class RedeemCodeBanner extends StatelessWidget {
  const RedeemCodeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => context.push('/invite/redeem'),
      icon: const Icon(Icons.card_giftcard_outlined,
          color: AppColors.gold, size: 18),
      label: const Text(
        'Einladungscode einlösen',
        style: TextStyle(color: AppColors.gold, fontSize: 14),
      ),
    );
  }
}
