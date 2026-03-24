import 'dart:math';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/pseudonym_generator.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

/// Multi-step onboarding flow for creating a new NEXUS identity.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();

  String _mnemonic = '';
  List<String> _words = [];
  String _pseudonym = '';
  List<int> _verifyIndices = [];
  List<TextEditingController> _verifyControllers = [];
  late final TextEditingController _pseudonymController;
  bool _loading = false;
  String? _verifyError;

  @override
  void initState() {
    super.initState();
    _pseudonymController = TextEditingController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pseudonymController.dispose();
    for (final c in _verifyControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _generateMnemonic() {
    final mnemonic = IdentityService.instance.generateMnemonic();
    final words = mnemonic.split(' ');
    final rng = Random.secure();

    // Pick 3 unique random indices for verification
    final indices = <int>{};
    while (indices.length < 3) {
      indices.add(rng.nextInt(12));
    }
    final sortedIndices = indices.toList()..sort();

    // Dispose old controllers
    for (final c in _verifyControllers) {
      c.dispose();
    }

    final pseudonym = PseudonymGenerator.generate();
    setState(() {
      _mnemonic = mnemonic;
      _words = words;
      _verifyIndices = sortedIndices;
      _verifyControllers =
          List.generate(3, (_) => TextEditingController());
      _pseudonym = pseudonym;
      _pseudonymController.text = pseudonym;
      _verifyError = null;
    });
  }

  void _advancePage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  bool _validateVerification() {
    for (int i = 0; i < 3; i++) {
      final expected = _words[_verifyIndices[i]];
      final entered = _verifyControllers[i].text.trim().toLowerCase();
      if (entered != expected) {
        setState(() => _verifyError =
            'Wort #${_verifyIndices[i] + 1} ist falsch. Bitte prüfe deine Seed Phrase.');
        return false;
      }
    }
    setState(() => _verifyError = null);
    return true;
  }

  Future<void> _finishOnboarding() async {
    setState(() => _loading = true);
    try {
      final pseudonym = _pseudonymController.text.trim().isNotEmpty
          ? _pseudonymController.text.trim()
          : _pseudonym;
      await IdentityService.instance.createIdentity(_mnemonic, pseudonym);
      _advancePage();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _WelcomeStep(
              onNewIdentity: () {
                _generateMnemonic();
                _advancePage();
              },
              onRestore: () => context.go('/onboarding/restore'),
            ),
            _SeedPhraseStep(
              words: _words,
              onNext: _advancePage,
            ),
            _VerifyStep(
              words: _words,
              verifyIndices: _verifyIndices,
              verifyControllers: _verifyControllers,
              errorMessage: _verifyError,
              onNext: () {
                if (_validateVerification()) _advancePage();
              },
            ),
            _PseudonymStep(
              controller: _pseudonymController,
              loading: _loading,
              onFinish: _finishOnboarding,
            ),
            _CompleteStep(
              pseudonym: _pseudonymController.text.trim().isNotEmpty
                  ? _pseudonymController.text.trim()
                  : _pseudonym,
              onDone: () => context.go('/chat'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 1: Welcome ──────────────────────────────────────────────────────────

class _WelcomeStep extends StatelessWidget {
  final VoidCallback onNewIdentity;
  final VoidCallback onRestore;

  const _WelcomeStep({
    required this.onNewIdentity,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.gold, width: 2.5),
              color: AppColors.surface,
            ),
            child: const Center(
              child: Text(
                'N',
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 52,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          const Text(
            'Willkommen bei\nN.E.X.U.S.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Dezentral. Souverän. Für alle.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 16,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 56),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onNewIdentity,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.deepBlue,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Neu starten',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRestore,
            child: const Text(
              'Konto wiederherstellen',
              style: TextStyle(
                color: AppColors.goldLight,
                fontSize: 15,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.goldLight,
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

// ── Step 2: Seed Phrase Display ───────────────────────────────────────────────

class _SeedPhraseStep extends StatelessWidget {
  final List<String> words;
  final VoidCallback onNext;

  const _SeedPhraseStep({required this.words, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          const Text(
            'Deine Seed Phrase',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Schreibe diese 12 Wörter auf und bewahre sie sicher auf.\nSie sind der einzige Zugang zu deiner Identität.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onDark, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 24),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            padding: const EdgeInsets.all(16),
            child: words.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.gold))
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.4,
                    ),
                    itemCount: words.length,
                    itemBuilder: (context, index) => Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            '${index + 1}.',
                            style: const TextStyle(
                              color: AppColors.gold,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              words[index],
                              style: const TextStyle(
                                color: AppColors.onDark,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF3D2000),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Teile diese Wörter niemals mit anderen. Wer sie kennt, hat Zugriff auf dein Konto.',
                    style: TextStyle(color: Colors.orange, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text(
              'Ich habe sie aufgeschrieben',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Step 3: Verify Seed Phrase ────────────────────────────────────────────────

class _VerifyStep extends StatelessWidget {
  final List<String> words;
  final List<int> verifyIndices;
  final List<TextEditingController> verifyControllers;
  final String? errorMessage;
  final VoidCallback onNext;

  const _VerifyStep({
    required this.words,
    required this.verifyIndices,
    required this.verifyControllers,
    required this.errorMessage,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          const Text(
            'Seed Phrase bestätigen',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Bitte gib die folgenden Wörter ein, um deine Seed Phrase zu bestätigen.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onDark, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 32),
          if (verifyControllers.length == 3)
            ...List.generate(3, (i) {
              final wordIndex = verifyIndices.isNotEmpty ? verifyIndices[i] : i;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Wort #${wordIndex + 1}',
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: verifyControllers[i],
                      style: const TextStyle(color: AppColors.onDark),
                      decoration: InputDecoration(
                        hintText: 'Wort eingeben…',
                        hintStyle: TextStyle(
                            color: AppColors.onDark.withValues(alpha: 0.4)),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.gold.withValues(alpha: 0.3)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.gold.withValues(alpha: 0.3)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: AppColors.gold),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ],
                ),
              );
            }),
          if (errorMessage != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF3D0000),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
              ),
              child: Text(
                errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text(
              'Weiter',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Step 4: Pseudonym ─────────────────────────────────────────────────────────

class _PseudonymStep extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onFinish;

  const _PseudonymStep({
    required this.controller,
    required this.loading,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          const Text(
            'Dein Pseudonym',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'So wirst du in der NEXUS-Community angezeigt.\nDu kannst es jederzeit ändern.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onDark, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 40),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.person_outline,
                    color: AppColors.gold, size: 48),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Pseudonym eingeben…',
                    hintStyle: TextStyle(
                        color: AppColors.onDark.withValues(alpha: 0.4),
                        fontSize: 16),
                    filled: true,
                    fillColor: AppColors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: loading ? null : onFinish,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.deepBlue,
              disabledBackgroundColor:
                  AppColors.gold.withValues(alpha: 0.5),
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
                    'Fertig',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Step 5: Complete ──────────────────────────────────────────────────────────

class _CompleteStep extends StatefulWidget {
  final String pseudonym;
  final VoidCallback onDone;

  const _CompleteStep({required this.pseudonym, required this.onDone});

  @override
  State<_CompleteStep> createState() => _CompleteStepState();
}

class _CompleteStepState extends State<_CompleteStep>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnim = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
            scale: _scaleAnim,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.gold.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.gold, width: 2.5),
              ),
              child: const Icon(
                Icons.check_rounded,
                color: AppColors.gold,
                size: 56,
              ),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Identität erstellt!',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Willkommen, ${widget.pseudonym}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.onDark,
              fontSize: 16,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Du wirst weitergeleitet…',
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 13,
            ),
          ),
        ],
        ),
      ),
    );
  }
}
