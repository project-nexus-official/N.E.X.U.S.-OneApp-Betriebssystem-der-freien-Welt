import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/profile_service.dart';
import 'package:nexus_oneapp/features/chat/conversation_service.dart';
import 'package:nexus_oneapp/core/router.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/storage/retention_service.dart';
import 'package:nexus_oneapp/features/chat/chat_provider.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // sqflite on desktop requires FFI initialisation.
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await IdentityService.instance.init();
  if (IdentityService.instance.hasIdentity) {
    await initServicesAfterIdentity();
  }
  runApp(const NexusApp());
}

/// Opens the encrypted POD and loads profile + contacts.
/// Call this once after identity is created or restored.
Future<void> initServicesAfterIdentity() async {
  try {
    final encKey = await IdentityService.instance.getPodEncryptionKey();
    await PodDatabase.instance.open(encKey);
    final pseudonym =
        IdentityService.instance.currentIdentity!.pseudonym;
    await ProfileService.instance.load(pseudonym);
    await ContactService.instance.load();
    await ConversationService.instance.load();
    await RetentionService.instance.load();
    RetentionService.instance.runCleanup(); // fire-and-forget
  } catch (e) {
    debugPrint('[NEXUS] Storage init error: $e');
  }
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: MaterialApp.router(
        title: 'NEXUS OneApp',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        routerConfig: router,
        builder: (context, child) {
          return _SplashWrapper(child: child!);
        },
      ),
    );
  }
}

class _SplashWrapper extends StatefulWidget {
  final Widget child;
  const _SplashWrapper({required this.child});

  @override
  State<_SplashWrapper> createState() => _SplashWrapperState();
}

class _SplashWrapperState extends State<_SplashWrapper>
    with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  late final AnimationController _controller;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _controller.forward().then((_) {
        if (mounted) setState(() => _showSplash = false);
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;

    return FadeTransition(
      opacity: _fadeOut,
      child: const _SplashScreen(),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NexusLogo(),
            SizedBox(height: 32),
            Text(
              'N.E.X.U.S. OneApp',
              style: TextStyle(
                color: AppColors.gold,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.0,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Für die Menschheitsfamilie',
              style: TextStyle(
                color: AppColors.onDark,
                fontSize: 14,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NexusLogo extends StatelessWidget {
  const _NexusLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}
