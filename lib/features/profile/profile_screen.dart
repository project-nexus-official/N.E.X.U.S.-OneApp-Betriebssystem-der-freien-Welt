import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/identicon.dart';

/// Profile screen displaying the current user's NEXUS identity.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _identityService = IdentityService.instance;

  void _copyPublicKey() {
    final identity = _identityService.currentIdentity;
    if (identity == null) return;
    Clipboard.setData(ClipboardData(text: identity.publicKeyHex));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Öffentlicher Schlüssel kopiert'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _copyDid() {
    final identity = _identityService.currentIdentity;
    if (identity == null) return;
    Clipboard.setData(ClipboardData(text: identity.did));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('DID kopiert'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showSeedPhrase() async {
    final seedPhrase = await _identityService.loadSeedPhrase();
    if (!mounted) return;

    if (seedPhrase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Seed Phrase gefunden.')),
      );
      return;
    }

    final words = seedPhrase.split(' ');

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Seed Phrase',
          style: TextStyle(
            color: AppColors.gold,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF3D2000),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Teile diese Wörter niemals mit anderen!',
                      style:
                          TextStyle(color: Colors.orange, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 2.4,
              ),
              itemCount: words.length,
              itemBuilder: (context, index) => Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '${index + 1}.',
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        words[index],
                        style: const TextStyle(
                          color: AppColors.onDark,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Schließen',
              style: TextStyle(color: AppColors.gold),
            ),
          ),
        ],
      ),
    );
  }

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i + 1 < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identityService.currentIdentity;

    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: identity == null
              ? const Center(
                  child: Text(
                    'Keine Identität gefunden.',
                    style: TextStyle(color: AppColors.onDark),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Identicon avatar
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: AppColors.gold, width: 2.5),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Identicon(
                        bytes: _hexToBytes(identity.publicKeyHex),
                        size: 100,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Pseudonym
                    Text(
                      identity.pseudonym,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.onDark,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    // DID card
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.25)),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Dezentrale ID (DID)',
                            style: TextStyle(
                              color: AppColors.gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: _copyDid,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    identity.shortDid,
                                    style: const TextStyle(
                                      color: AppColors.onDark,
                                      fontSize: 14,
                                      fontFamily: 'monospace',
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.copy_outlined,
                                  color: AppColors.gold,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Tippe zum Kopieren',
                            style: TextStyle(
                              color: AppColors.onDark.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // QR code section
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.25)),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'QR-Code zum Hinzufügen',
                            style: TextStyle(
                              color: AppColors.gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 16),
                          QrImageView(
                            data: identity.did,
                            version: QrVersions.auto,
                            size: 180,
                            backgroundColor: Colors.white,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Color(0xFF000000),
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Color(0xFF000000),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Public key card
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.25)),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Öffentlicher Schlüssel',
                            style: TextStyle(
                              color: AppColors.gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: _copyPublicKey,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    identity.shortPublicKey,
                                    style: const TextStyle(
                                      color: AppColors.onDark,
                                      fontSize: 16,
                                      fontFamily: 'monospace',
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.copy_outlined,
                                  color: AppColors.gold,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Tippe zum Kopieren',
                            style: TextStyle(
                              color: AppColors.onDark.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Seed phrase button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showSeedPhrase,
                        icon: const Icon(Icons.key_outlined,
                            color: AppColors.gold),
                        label: const Text(
                          'Seed Phrase anzeigen',
                          style: TextStyle(color: AppColors.gold),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(
                              color: AppColors.gold.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 56),
                    // NEXUS branding
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: AppColors.gold, width: 1.5),
                        color: AppColors.surface,
                      ),
                      child: const Center(
                        child: Text(
                          'N',
                          style: TextStyle(
                            color: AppColors.gold,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'N.E.X.U.S. OneApp',
                      style: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.5),
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
