import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/theme/app_theme.dart';

/// Screen 2 of the principles flow – the principles text in 4 pages.
///
/// [readOnly] == true: used from Settings – PageView with a "Schließen"
/// button at the end that pops the screen. No commitment step follows.
///
/// [readOnly] == false (default): "Weiter" on page 4 navigates to the
/// commitment screen.
class PrinciplesContentScreen extends StatefulWidget {
  final bool readOnly;

  const PrinciplesContentScreen({super.key, this.readOnly = false});

  @override
  State<PrinciplesContentScreen> createState() =>
      _PrinciplesContentScreenState();
}

class _PrinciplesContentScreenState extends State<PrinciplesContentScreen> {
  final _pageCtrl = PageController();
  int _page = 0;
  static const _totalPages = 4;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _totalPages - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      if (widget.readOnly) {
        Navigator.of(context).pop();
      } else {
        context.go('/principles/commitment');
      }
    }
  }

  void _back() {
    if (_page > 0) {
      _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  String get _nextLabel {
    if (_page == _totalPages - 1) {
      return widget.readOnly ? 'Schließen' : 'Weiter';
    }
    return 'Weiter';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header row: back arrow + progress dots ──────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: _page > 0
                        ? IconButton(
                            key: const Key('principles_back_btn'),
                            onPressed: _back,
                            icon: const Icon(Icons.arrow_back_ios,
                                color: AppColors.gold, size: 20),
                          )
                        : null,
                  ),
                  Expanded(
                    child: Center(
                      child: _PageDots(current: _page, total: _totalPages),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ── Page content ────────────────────────────────────────────────
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _Page1(),
                  _Page2(),
                  _Page3(),
                  _Page4(),
                ],
              ),
            ),
            // ── Next button ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('principles_next_btn'),
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.deepBlue,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _nextLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Progress dots ──────────────────────────────────────────────────────────────

class _PageDots extends StatelessWidget {
  final int current;
  final int total;

  const _PageDots({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 12 : 8,
          height: active ? 12 : 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? AppColors.gold
                : AppColors.gold.withValues(alpha: 0.3),
          ),
        );
      }),
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _GoldCard extends StatelessWidget {
  final String title;
  final String body;

  const _GoldCard({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold, width: 1),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              color: AppColors.onDark,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletPoint extends StatelessWidget {
  final String text;

  const _BulletPoint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '◆',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 12,
              height: 1.8,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.onDark,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Page 1: Introduction + Pillar 1 ───────────────────────────────────────────

class _Page1 extends StatelessWidget {
  const _Page1();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SizedBox(height: 8),
          Text(
            'Die Grundsätze der Menschheitsfamilie',
            key: Key('principles_page1_title'),
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Bevor du diesen Raum betrittst, nimm dir einen Moment für diese Worte. '
            'Sie sind kein Vertrag und kein Kleingedrucktes. '
            'Sie sind die Grundlage, auf der wir gemeinsam etwas Neues aufbauen.',
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Ich trete ein in eine Gemeinschaft, die auf drei Säulen ruht:',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              height: 1.4,
            ),
          ),
          SizedBox(height: 16),
          _GoldCard(
            title: '1. Schade niemandem (Do No Harm)',
            body: 'Ich handle nach bestem Wissen und Gewissen und übernehme '
                'Verantwortung für die Wirkung meines Handelns. Meine Freiheit '
                'endet dort, wo sie die Würde, Freiheit oder Unversehrtheit '
                'eines anderen verletzt.',
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Page 2: Pillars 2 & 3 ─────────────────────────────────────────────────────

class _Page2 extends StatelessWidget {
  const _Page2();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: const [
          SizedBox(height: 8),
          _GoldCard(
            title: '2. Radikale Wahrheit (Transparenz)',
            body: 'Unsere gemeinsamen Entscheidungen, Strukturen und '
                'Prozesse sind offen und nachvollziehbar. Es gibt keine '
                'versteckten Machtzentren und keine Absprachen im Schatten. '
                'Gleichzeitig bleibt mein persönliches Leben, meine Gedanken '
                'und meine Identität geschützt.',
          ),
          SizedBox(height: 16),
          _GoldCard(
            title: '3. Macht der Basis (Subsidiarität)',
            body: 'Entscheidungen werden dort getroffen, wo sie wirken. '
                'Was meine lokale Gemeinschaft betrifft, entscheiden wir '
                'gemeinsam vor Ort. Es gibt keine zentrale Instanz, die über '
                'das bestimmt, was wir selbst verantworten können.',
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Page 3: Rights ────────────────────────────────────────────────────────────

class _Page3 extends StatelessWidget {
  const _Page3();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SizedBox(height: 8),
          Text(
            'Meine Rechte — unveräußerlich und unantastbar:',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          SizedBox(height: 20),
          _BulletPoint(
            'Mein Körper, mein Geist und meine digitalen Daten gehören mir allein.',
          ),
          _BulletPoint(
            'Ich darf frei sprechen und meine Meinung äußern — im Einklang mit dem Grundsatz, niemandem zu schaden.',
          ),
          _BulletPoint(
            'Ich habe das Recht zu gehen — jederzeit, ohne Strafe, ohne Ächtung.',
          ),
          _BulletPoint(
            'Jede Stimme hat das gleiche Gewicht, wenn es um Würde, Freiheit und grundlegende Fragen des Menschseins geht.',
          ),
          _BulletPoint(
            'Kein Code, kein Algorithmus und keine Mehrheit kann diese Rechte aufheben.',
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Page 4: Commitment & Pact ──────────────────────────────────────────────────

class _Page4 extends StatelessWidget {
  const _Page4();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SizedBox(height: 8),
          Text(
            'Mein Bekenntnis:',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Ich trete nicht ein, um nur zu konsumieren. Ich trete ein, um Teil von '
            'etwas zu sein, das größer ist als ich selbst. Diese Gemeinschaft lebt '
            'davon, dass wir füreinander wirken — freiwillig und aus innerer '
            'Überzeugung. Mein Beitrag mag groß oder klein sein, aber er trägt zur '
            'gemeinsamen Fülle bei.',
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Der Pakt:',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Ich begegne jedem Menschen in diesem Raum mit Würde und Respekt. '
            'Und im Gegenzug schützt dieser Raum auch meine Würde.',
            style: TextStyle(
              color: AppColors.onDark,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}
