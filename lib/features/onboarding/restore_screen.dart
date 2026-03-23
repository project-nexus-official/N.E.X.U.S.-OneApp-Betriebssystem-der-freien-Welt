import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:nexus_oneapp/core/identity/bip39_wordlist.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';

/// Screen to restore an existing NEXUS identity from a 12-word seed phrase.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  /// One controller per word slot.
  final List<TextEditingController> _controllers =
      List.generate(12, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(12, (_) => FocusNode());

  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  bool _isWordValid(String word) {
    return bip39Wordlist.contains(word.trim().toLowerCase());
  }

  bool get _allWordsValid {
    return _controllers
        .every((c) => _isWordValid(c.text));
  }

  Future<void> _submit() async {
    if (!_allWordsValid) {
      setState(() => _errorMessage =
          'Bitte stelle sicher, dass alle 12 Wörter gültig sind.');
      return;
    }

    final mnemonic =
        _controllers.map((c) => c.text.trim().toLowerCase()).join(' ');

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await IdentityService.instance.restoreFromMnemonic(mnemonic);
      if (mounted) context.go('/chat');
    } on ArgumentError catch (e) {
      setState(() => _errorMessage = e.message.toString());
    } catch (e) {
      setState(() => _errorMessage = 'Fehler beim Wiederherstellen: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      appBar: AppBar(
        title: const Text('Konto wiederherstellen'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.gold,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => context.go('/onboarding'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Gib deine 12 Wörter ein',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Gib die Wörter in der richtigen Reihenfolge ein.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.onDark, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 24),
              // 2-column × 6-row grid of word inputs
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 3.0,
                ),
                itemCount: 12,
                itemBuilder: (context, index) {
                  return _WordField(
                    index: index,
                    controller: _controllers[index],
                    focusNode: _focusNodes[index],
                    nextFocusNode: index < 11 ? _focusNodes[index + 1] : null,
                    isValid: _controllers[index].text.isEmpty
                        ? null
                        : _isWordValid(_controllers[index].text),
                    onChanged: (_) => setState(() {}),
                  );
                },
              ),
              const SizedBox(height: 16),
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3D0000),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Colors.red.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: (_allWordsValid && !_loading) ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.deepBlue,
                  disabledBackgroundColor:
                      AppColors.gold.withValues(alpha: 0.4),
                  disabledForegroundColor:
                      AppColors.deepBlue.withValues(alpha: 0.6),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
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
                        'Konto wiederherstellen',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _WordField extends StatelessWidget {
  final int index;
  final TextEditingController controller;
  final FocusNode focusNode;
  final FocusNode? nextFocusNode;
  final bool? isValid;
  final ValueChanged<String> onChanged;

  const _WordField({
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.nextFocusNode,
    required this.isValid,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Color borderColor;
    if (isValid == null) {
      borderColor = AppColors.gold.withValues(alpha: 0.3);
    } else if (isValid!) {
      borderColor = Colors.greenAccent;
    } else {
      borderColor = Colors.redAccent;
    }

    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: const TextStyle(color: AppColors.onDark, fontSize: 14),
      textInputAction:
          nextFocusNode != null ? TextInputAction.next : TextInputAction.done,
      autocorrect: false,
      onChanged: onChanged,
      onSubmitted: (_) {
        if (nextFocusNode != null) {
          FocusScope.of(context).requestFocus(nextFocusNode);
        } else {
          focusNode.unfocus();
        }
      },
      decoration: InputDecoration(
        prefixText: '${index + 1}. ',
        prefixStyle: const TextStyle(
            color: AppColors.gold,
            fontSize: 12,
            fontWeight: FontWeight.bold),
        hintText: 'Wort…',
        hintStyle:
            TextStyle(color: AppColors.onDark.withValues(alpha: 0.35), fontSize: 12),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: isValid == true ? Colors.greenAccent : AppColors.gold),
        ),
        suffixIcon: isValid != null
            ? Icon(
                isValid! ? Icons.check_circle_outline : Icons.cancel_outlined,
                color: isValid! ? Colors.greenAccent : Colors.redAccent,
                size: 16,
              )
            : null,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
    );
  }
}
