import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/principles_service.dart';
import '../../shared/theme/app_theme.dart';

/// Screen 3 of the principles flow – the commitment moment.
///
/// Two checkboxes must both be checked before "Ich trete ein" becomes active.
/// The "Später" link skips the flow and navigates to the Dashboard with a
/// reminder banner.
class PrinciplesCommitmentScreen extends StatefulWidget {
  const PrinciplesCommitmentScreen({super.key});

  @override
  State<PrinciplesCommitmentScreen> createState() =>
      _PrinciplesCommitmentScreenState();
}

class _PrinciplesCommitmentScreenState
    extends State<PrinciplesCommitmentScreen>
    with SingleTickerProviderStateMixin {
  bool _understood = false;
  bool _ready = false;
  bool _loading = false;

  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  bool get _canCommit => _understood && _ready;

  void _onCheckboxChanged() {
    if (_understood && _ready) {
      _pulseCtrl.forward().then((_) => _pulseCtrl.reverse());
    }
  }

  Future<void> _commit() async {
    if (!_canCommit) return;
    setState(() => _loading = true);
    await PrinciplesService.instance.accept();
    if (!mounted) return;
    setState(() => _loading = false);
    context.go('/home');
  }

  Future<void> _skipForNow() async {
    await PrinciplesService.instance.skip();
    if (!mounted) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              const Text(
                'Wenn du diesen Raum betrittst,\nträgst du ihn mit.\nNicht perfekt. Aber bewusst.',
                key: Key('principles_commitment_headline'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 20,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
              const Spacer(flex: 2),
              // ── Checkboxes ─────────────────────────────────────────────────
              _AnimatedCheckbox(
                key: const Key('principles_cb_understood'),
                label: 'Ich habe die Grundsätze verstanden',
                value: _understood,
                onChanged: (val) {
                  setState(() => _understood = val ?? false);
                  _onCheckboxChanged();
                },
              ),
              const SizedBox(height: 16),
              _AnimatedCheckbox(
                key: const Key('principles_cb_ready'),
                label: 'Ich bin bereit, nach ihnen zu handeln',
                value: _ready,
                onChanged: (val) {
                  setState(() => _ready = val ?? false);
                  _onCheckboxChanged();
                },
              ),
              const Spacer(flex: 2),
              // ── Commit button ───────────────────────────────────────────────
              ScaleTransition(
                scale: _pulseAnim,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    key: const Key('principles_commit_btn'),
                    onPressed: _canCommit && !_loading ? _commit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: AppColors.deepBlue,
                      disabledBackgroundColor:
                          AppColors.gold.withValues(alpha: 0.35),
                      disabledForegroundColor:
                          AppColors.deepBlue.withValues(alpha: 0.5),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.deepBlue,
                            ),
                          )
                        : const Text(
                            'Ich trete ein',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ── Skip link ──────────────────────────────────────────────────
              TextButton(
                key: const Key('principles_skip_btn'),
                onPressed: _skipForNow,
                child: const Text(
                  'Ich bin noch nicht bereit — Später zurückkehren',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.onDark,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.onDark,
                  ),
                ),
              ),
              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Animated checkbox tile ─────────────────────────────────────────────────────

class _AnimatedCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;

  const _AnimatedCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: value
              ? AppColors.gold.withValues(alpha: 0.1)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value
                ? AppColors.gold
                : AppColors.gold.withValues(alpha: 0.3),
            width: value ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            AnimatedScale(
              scale: value ? 1.1 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Checkbox(
                value: value,
                onChanged: onChanged,
                activeColor: AppColors.gold,
                checkColor: AppColors.deepBlue,
                side: const BorderSide(color: AppColors.gold),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: value ? AppColors.gold : AppColors.onDark,
                  fontSize: 15,
                  fontWeight:
                      value ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
