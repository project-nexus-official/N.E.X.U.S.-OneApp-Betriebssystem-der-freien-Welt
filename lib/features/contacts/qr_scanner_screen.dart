import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../core/contacts/contact.dart';
import '../../core/contacts/contact_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/identicon.dart';
import '../chat/chat_provider.dart';
import 'contact_detail_screen.dart';
import 'manual_key_input_dialog.dart';
import 'qr_contact_payload.dart';

/// Full-screen QR code scanner for adding NEXUS contacts.
///
/// On mobile (Android, iOS, macOS): uses the device camera.
/// On Windows/Linux/Web: shows a manual JSON/DID input fallback.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _scanned = false;
  bool _torchOn = false;

  // Whether this platform supports camera-based scanning.
  bool get _useCamera =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Scan handling ───────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final payload = QrContactPayload.tryParse(raw);
      if (payload != null) {
        _scanned = true;
        _controller.stop();
        _showResultSheet(payload);
        return;
      }
    }
  }

  void _resetScanner() {
    setState(() => _scanned = false);
    _controller.start();
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() => _torchOn = !_torchOn);
  }

  // ── Manual input (Windows / Linux / Web fallback) ──────────────────────────

  final _manualCtrl = TextEditingController();
  String? _manualError;

  void _tryParseManual() {
    final text = _manualCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _manualError = 'Bitte Schlüssel oder DID eingeben');
      return;
    }
    final payload = tryParseAnyKey(text);
    if (payload == null) {
      setState(() => _manualError =
          'Kein gültiger Schlüssel erkannt (did:key:…, npub1…, Hex oder JSON)');
      return;
    }
    setState(() => _manualError = null);
    _showResultSheet(payload);
  }

  // ── Result bottom sheet ─────────────────────────────────────────────────────

  Future<void> _showResultSheet(QrContactPayload payload) async {
    final existing = ContactService.instance.findByDid(payload.did);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _ResultSheet(
        payload: payload,
        existing: existing,
        onAdded: (contact) {
          Navigator.of(ctx).pop();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => ContactDetailScreen(did: contact.did),
            ),
          );
        },
        onOpenContact: (contact) {
          Navigator.of(ctx).pop();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => ContactDetailScreen(did: contact.did),
            ),
          );
        },
        onCancel: () {
          Navigator.of(ctx).pop();
          if (_useCamera) _resetScanner();
        },
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _useCamera ? _buildCameraView() : _buildManualView(),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      children: [
        // Camera feed
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) => _buildCameraError(error),
        ),

        // Dark overlay with transparent scan area
        CustomPaint(
          size: Size.infinite,
          painter: _ScanOverlayPainter(),
        ),

        // Top bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Back button
                _overlayButton(
                  icon: Icons.arrow_back,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Expanded(
                  child: Text(
                    'QR-Code scannen',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Torch toggle
                _overlayButton(
                  icon: _torchOn ? Icons.flash_on : Icons.flash_off,
                  onTap: _toggleTorch,
                ),
              ],
            ),
          ),
        ),

        // Instruction text below scan frame
        Positioned(
          left: 0,
          right: 0,
          bottom: 120,
          child: Text(
            'NEXUS-Kontakt-QR-Code in den Rahmen halten',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
            ),
          ),
        ),

        // Manual key fallback link
        Positioned(
          left: 0,
          right: 0,
          bottom: 80,
          child: GestureDetector(
            onTap: () => showManualKeyInputDialog(context),
            child: const Text(
              'Schlüssel manuell eingeben',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.gold,
                fontSize: 13,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraError(MobileScannerException error) {
    return ColoredBox(
      color: AppColors.deepBlue,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, color: AppColors.gold, size: 48),
            const SizedBox(height: 16),
            Text(
              'Kamera nicht verfügbar:\n${error.errorDetails?.message ?? error.errorCode.name}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.onDark),
            ),
            const SizedBox(height: 24),
            _ManualInputWidget(
              controller: _manualCtrl,
              error: _manualError,
              onSubmit: _tryParseManual,
              onBack: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualView() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: AppColors.gold),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Kontakt hinzufügen',
                  style: TextStyle(
                    color: AppColors.onDark,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Icon(Icons.vpn_key, color: AppColors.gold, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Auf Desktop-Geräten kannst du den QR-Code nicht scannen. '
              'Bitte füge den Kontakt über seinen Netzwerkschlüssel hinzu.',
              style: TextStyle(color: AppColors.onDark, fontSize: 15),
            ),
            const SizedBox(height: 8),
            const Text(
              'Akzeptiert: did:key:…  ·  npub1…  ·  64-stelliger Hex  ·  NEXUS-JSON',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 24),
            _ManualInputWidget(
              controller: _manualCtrl,
              error: _manualError,
              onSubmit: _tryParseManual,
              onBack: null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _overlayButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

// ── Manual input widget ───────────────────────────────────────────────────────

class _ManualInputWidget extends StatelessWidget {
  final TextEditingController controller;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback? onBack;

  const _ManualInputWidget({
    required this.controller,
    required this.error,
    required this.onSubmit,
    required this.onBack,
  });

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) controller.text = data!.text!.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          maxLines: 3,
          minLines: 1,
          style: const TextStyle(color: AppColors.onDark, fontSize: 13),
          decoration: InputDecoration(
            hintText: 'did:key:z6Mk…  ·  npub1…  ·  64-stelliger Hex',
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
            errorText: error,
            errorMaxLines: 2,
            filled: true,
            fillColor: AppColors.surfaceVariant,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.gold, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.gold, width: 2),
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
        ElevatedButton(
          onPressed: onSubmit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.gold,
            foregroundColor: AppColors.deepBlue,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Kontakt prüfen',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

// ── Scan overlay painter ──────────────────────────────────────────────────────

class _ScanOverlayPainter extends CustomPainter {
  static const _frameSize = 260.0;
  static const _cornerLen = 28.0;
  static const _cornerWidth = 4.0;
  static const _borderRadius = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 - 40; // slightly above center

    final rect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: _frameSize,
      height: _frameSize,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_borderRadius));

    // Dark overlay
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, overlayPaint);

    // Gold corner accents
    final cornerPaint = Paint()
      ..color = AppColors.gold
      ..strokeWidth = _cornerWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;
    final cr = _borderRadius;
    final cl = _cornerLen;

    // Top-left
    canvas.drawPath(
        Path()
          ..moveTo(l + cl, t)
          ..lineTo(l + cr, t)
          ..arcToPoint(Offset(l, t + cr),
              radius: const Radius.circular(_borderRadius))
          ..lineTo(l, t + cl),
        cornerPaint);
    // Top-right
    canvas.drawPath(
        Path()
          ..moveTo(r - cl, t)
          ..lineTo(r - cr, t)
          ..arcToPoint(Offset(r, t + cr),
              radius: const Radius.circular(_borderRadius), clockwise: false)
          ..lineTo(r, t + cl),
        cornerPaint);
    // Bottom-left
    canvas.drawPath(
        Path()
          ..moveTo(l, b - cl)
          ..lineTo(l, b - cr)
          ..arcToPoint(Offset(l + cr, b),
              radius: const Radius.circular(_borderRadius), clockwise: false)
          ..lineTo(l + cl, b),
        cornerPaint);
    // Bottom-right
    canvas.drawPath(
        Path()
          ..moveTo(r, b - cl)
          ..lineTo(r, b - cr)
          ..arcToPoint(Offset(r - cr, b),
              radius: const Radius.circular(_borderRadius))
          ..lineTo(r - cl, b),
        cornerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Result bottom sheet ───────────────────────────────────────────────────────

class _ResultSheet extends StatefulWidget {
  final QrContactPayload payload;
  final Contact? existing;
  final void Function(Contact) onAdded;
  final void Function(Contact) onOpenContact;
  final VoidCallback onCancel;

  const _ResultSheet({
    required this.payload,
    required this.existing,
    required this.onAdded,
    required this.onOpenContact,
    required this.onCancel,
  });

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  bool _loading = false;

  Future<void> _addContact() async {
    setState(() => _loading = true);
    // Capture context-dependent references before the async gap.
    final chatProvider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final contact = await ContactService.instance.addContactFromQr(
        did: widget.payload.did,
        pseudonym: widget.payload.pseudonym,
        encryptionPublicKey: widget.payload.publicKey,
        nostrPubkey: widget.payload.nostrPubkey,
      );

      // Register DID→Nostr mapping so DMs can be sent immediately.
      if (widget.payload.nostrPubkey != null) {
        chatProvider.nostrTransport
            ?.registerDidMapping(widget.payload.did, widget.payload.nostrPubkey!);
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text('${widget.payload.pseudonym} wurde als Kontakt hinzugefügt'),
          backgroundColor: AppColors.surface,
        ),
      );
      if (mounted) widget.onAdded(contact);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendMessage() async {
    // Ensure contact exists first, then navigate to chat.
    final contact = ContactService.instance.findByDid(widget.payload.did) ??
        await ContactService.instance.addContactFromQr(
          did: widget.payload.did,
          pseudonym: widget.payload.pseudonym,
          encryptionPublicKey: widget.payload.publicKey,
          nostrPubkey: widget.payload.nostrPubkey,
        );
    if (!mounted) return;
    // Close sheet and open chat (caller handles navigation).
    widget.onAdded(contact);
  }

  List<int> _didToBytes(String did) {
    // Use last 32 chars of DID as pseudo-random seed for identicon.
    final suffix = did.length > 32 ? did.substring(did.length - 32) : did;
    return suffix.codeUnits;
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.payload;
    final existing = widget.existing;
    final isAlreadyContact = existing != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey.shade600,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Avatar
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isAlreadyContact ? AppColors.gold : Colors.grey.shade600,
                width: 2.5,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Identicon(
              bytes: _didToBytes(payload.did),
              size: 72,
            ),
          ),
          const SizedBox(height: 12),

          // Pseudonym
          Text(
            payload.pseudonym,
            style: const TextStyle(
              color: AppColors.onDark,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),

          // Short DID
          Text(
            payload.shortDid,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),

          if (isAlreadyContact) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppColors.gold.withValues(alpha: 0.4)),
              ),
              child: Text(
                'Bereits in deinen Kontakten · ${existing.trustLevel.label}',
                style: const TextStyle(
                    color: AppColors.gold, fontSize: 13),
              ),
            ),
          ],

          const SizedBox(height: 28),

          // Primary action
          if (isAlreadyContact)
            _actionButton(
              label: 'Zum Kontakt',
              icon: Icons.person_outline,
              primary: true,
              onTap: () => widget.onOpenContact(existing),
            )
          else
            _actionButton(
              label: 'Als Kontakt hinzufügen',
              icon: Icons.person_add_outlined,
              primary: true,
              loading: _loading,
              onTap: _addContact,
            ),

          const SizedBox(height: 10),

          // Secondary: send message
          _actionButton(
            label: 'Nachricht senden',
            icon: Icons.chat_bubble_outline,
            primary: false,
            onTap: _sendMessage,
          ),

          const SizedBox(height: 10),

          // Cancel
          TextButton(
            onPressed: widget.onCancel,
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required bool primary,
    bool loading = false,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: loading ? null : onTap,
        icon: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.deepBlue),
              )
            : Icon(icon),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: primary ? AppColors.gold : AppColors.surfaceVariant,
          foregroundColor: primary ? AppColors.deepBlue : AppColors.onDark,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}

