import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/identity/identity_service.dart';
import '../../services/invite_service.dart';
import '../../shared/theme/app_theme.dart';
import '../chat/chat_provider.dart';

/// Screen where the user enters an invite code received from a friend.
///
/// Accepts `NEXUS-XXXX-XXXX`, `XXXXXXXX`, or a `nexus://invite?...` deep-link.
class RedeemScreen extends StatefulWidget {
  /// Pre-filled code from a deep-link or QR scan.
  final String? initialCode;

  const RedeemScreen({super.key, this.initialCode});

  @override
  State<RedeemScreen> createState() => _RedeemScreenState();
}

class _RedeemScreenState extends State<RedeemScreen> {
  late final TextEditingController _ctrl;
  bool _loading = false;
  String? _error;
  String? _successPseudonym;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialCode ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final input = _ctrl.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Bitte gib deinen Einladungscode ein.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _successPseudonym = null;
    });

    final identity = IdentityService.instance.currentIdentity;
    final myPseudonym = identity?.pseudonym ?? 'Anonym';
    final chat = context.read<ChatProvider>();

    final result = await InviteService.instance.redeemEncoded(
      encoded: input,
      myPseudonym: myPseudonym,
      sendDmNotification: ({
        required String toDid,
        required String message,
        Map<String, dynamic>? metadata,
      }) =>
          chat.sendMessage(toDid, message, extraMeta: metadata),
    );

    if (!mounted) return;

    if (result.success) {
      setState(() {
        _loading = false;
        _successPseudonym = result.inviterPseudonym;
      });
    } else {
      setState(() {
        _loading = false;
        _error = result.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Code einlösen'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: _successPseudonym != null
              ? _SuccessView(
                  pseudonym: _successPseudonym!,
                  onDone: () => context.go('/home'),
                )
              : _InputView(
                  ctrl: _ctrl,
                  loading: _loading,
                  error: _error,
                  onRedeem: _redeem,
                ),
        ),
      ),
    );
  }
}

// ── Input view ────────────────────────────────────────────────────────────────

class _InputView extends StatelessWidget {
  final TextEditingController ctrl;
  final bool loading;
  final String? error;
  final VoidCallback onRedeem;

  const _InputView({
    required this.ctrl,
    required this.loading,
    required this.error,
    required this.onRedeem,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.card_giftcard_outlined,
            color: AppColors.gold, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Einladungscode einlösen',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.gold,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Hast du einen Einladungscode erhalten?\n'
          'Gib ihn hier ein, um sofort verbunden zu sein.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.onDark,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),
        TextField(
          key: const Key('redeem_code_field'),
          controller: ctrl,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            color: AppColors.onDark,
            fontSize: 18,
            fontFamily: 'monospace',
            letterSpacing: 2,
          ),
          decoration: InputDecoration(
            hintText: 'NEXUS-XXXX-XXXX',
            hintStyle: TextStyle(
              color: AppColors.onDark.withValues(alpha: 0.3),
              fontSize: 18,
              fontFamily: 'monospace',
              letterSpacing: 2,
            ),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                  color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                  color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.gold),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 16),
          ),
          onSubmitted: (_) => onRedeem(),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF3D0000),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
            ),
            child: Text(
              error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          key: const Key('redeem_submit_button'),
          onPressed: loading ? null : onRedeem,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            disabledBackgroundColor: AppColors.gold.withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.deepBlue,
                  ),
                )
              : const Text(
                  'Einlösen',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
        ),
      ],
    );
  }
}

// ── Success view ──────────────────────────────────────────────────────────────

class _SuccessView extends StatelessWidget {
  final String pseudonym;
  final VoidCallback onDone;

  const _SuccessView({required this.pseudonym, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline,
            color: AppColors.gold, size: 72),
        const SizedBox(height: 20),
        Text(
          'Verbunden mit $pseudonym!',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.gold,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '$pseudonym wurde als Kontakt hinzugefügt.\n'
          'Ihr seid jetzt in N.E.X.U.S. verbunden.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.onDark,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 36),
        ElevatedButton(
          key: const Key('redeem_success_done_button'),
          onPressed: onDone,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text(
            'Zum Dashboard',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
