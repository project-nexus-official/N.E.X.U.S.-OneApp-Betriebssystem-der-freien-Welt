import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_oneapp/core/contacts/contact_service.dart';
import 'package:nexus_oneapp/core/crypto/encryption_keys.dart';
import 'package:nexus_oneapp/core/identity/identity_service.dart';
import 'package:nexus_oneapp/core/identity/profile_service.dart';
import 'package:nexus_oneapp/features/chat/conversation_service.dart';
import 'package:nexus_oneapp/features/dashboard/node_counter_service.dart';
import 'package:nexus_oneapp/core/router.dart';
import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'package:nexus_oneapp/core/storage/retention_service.dart';
import 'package:nexus_oneapp/features/chat/chat_provider.dart';
import 'package:nexus_oneapp/services/background_service.dart';
import 'package:nexus_oneapp/services/notification_service.dart';
import 'package:nexus_oneapp/services/notification_settings_service.dart';
import 'package:nexus_oneapp/services/principles_service.dart';
import 'package:nexus_oneapp/shared/theme/app_theme.dart';
import 'package:nexus_oneapp/shared/widgets/notification_banner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── Crash logging ─────────────────────────────────────────────────────────────
//
// Crash logging writes errors to a file for debugging purposes.
// It does NOT trigger any "safe mode" or restricted startup — the app always
// starts normally regardless of what the log contains.

File? _crashLogFile;

/// Fallback log path using environment variables, before path_provider is ready.
String _fallbackLogPath() {
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      return '$localAppData\\nexus_oneapp\\nexus_crash.log';
    }
    final profile =
        Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$profile\\AppData\\Local\\nexus_oneapp\\nexus_crash.log';
  }
  return '${Directory.systemTemp.path}/nexus_crash.log';
}

void _logCrash(String source, Object error, StackTrace? stack) {
  try {
    final timestamp = DateTime.now().toIso8601String();
    final platformInfo =
        'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    final entry = '[$timestamp] [$source]\n'
        '$platformInfo\n'
        'Dart SDK: ${Platform.version}\n'
        'ERROR: $error\n'
        '${stack ?? "(no stack trace)"}\n'
        '${"─" * 60}\n';

    final logFile = _crashLogFile;
    if (logFile != null) {
      logFile.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } else {
      // Early-crash fallback: write to known path without path_provider.
      try {
        final fallback = File(_fallbackLogPath());
        fallback.parent.createSync(recursive: true);
        fallback.writeAsStringSync(entry, mode: FileMode.append, flush: true);
      } catch (_) {}
    }
    debugPrint('[NEXUS CRASH] $source: $error');
  } catch (_) {
    // Never throw from a crash handler.
  }
}

/// Initialises the crash log file. Clears any previous log on a clean start
/// so stale entries don't accumulate. Does NOT affect startup behaviour.
Future<void> _initCrashLog() async {
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    _crashLogFile = File('${docsDir.path}/nexus_crash.log');
    // Clear old log each fresh launch so the file stays small.
    if (await _crashLogFile!.exists()) {
      await _crashLogFile!.writeAsString('');
    }
  } catch (e) {
    // If path_provider fails, fall back to the env-based path.
    try {
      final fallback = File(_fallbackLogPath());
      fallback.parent.createSync(recursive: true);
      _crashLogFile = fallback;
    } catch (_) {}
    debugPrint('[NEXUS] Could not init crash log: $e');
  }
}

// ── Entry point ───────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Install Flutter/Dart error handlers before any other work.
  // These log to file for debugging but never alter startup behaviour.
  FlutterError.onError = (details) {
    _logCrash('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logCrash('PlatformDispatcher', error, stack);
    return false; // let Flutter handle the error normally
  };

  await _initCrashLog();

  Object? startupError;
  StackTrace? startupStack;

  try {
    // sqflite on desktop requires FFI initialisation.
    // On Android/iOS the default factory is already correct – skip this block.
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    await IdentityService.instance.init();
    await PrinciplesService.instance.load();
    if (IdentityService.instance.hasIdentity) {
      await initServicesAfterIdentity();
    }
  } catch (e, st) {
    _logCrash('main.startup', e, st);
    startupError = e;
    startupStack = st;
  }

  if (startupError != null) {
    // Show a visible error screen instead of a silent crash.
    // This only fires when startup itself throws — not on routine Flutter errors.
    runApp(_CrashReportApp(
      error: startupError,
      stackTrace: startupStack,
      logPath: _crashLogFile?.path ?? _fallbackLogPath(),
    ));
  } else {
    runApp(const NexusApp());
  }
}

/// Opens the encrypted POD and loads profile + contacts.
/// Call this once after identity is created or restored.
Future<void> initServicesAfterIdentity() async {
  final sw = Stopwatch()..start();
  debugPrint('[NEXUS] initServicesAfterIdentity starting…');
  try {
    final encKey = await IdentityService.instance.getPodEncryptionKey();
    // pod_database.dart logs: path, exists, size, message count, contact count
    await PodDatabase.instance.open(encKey);
    final identity = IdentityService.instance.currentIdentity!;
    debugPrint('[NEXUS] Identity loaded: ${identity.did}');
    await ProfileService.instance.load(identity.pseudonym);
    await ContactService.instance.load();
    debugPrint('[NEXUS] Contacts loaded: ${ContactService.instance.contacts.length}');
    await ConversationService.instance.load();
    await RetentionService.instance.load();
    RetentionService.instance.runCleanup(); // fire-and-forget
    await NotificationSettingsService.instance.load();
    await NotificationService.instance.init(
      onTap: (payload) {
        debugPrint('[NOTIF] Tapped: $payload');
      },
    );
    await BackgroundServiceManager.instance.init();
    // Initialize node counter (lazy – starts listening once transports run).
    NodeCounterService.instance.init();
    // Initialize X25519 encryption keys.
    try {
      final ed25519Bytes =
          await IdentityService.instance.getEd25519PrivateBytes();
      if (ed25519Bytes != null) {
        await EncryptionKeys.instance.initFromEd25519Private(ed25519Bytes);
      }
    } catch (e) {
      debugPrint('[CRYPTO] Encryption key init failed at startup: $e');
    }
    debugPrint('[NEXUS] Startup complete in ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    debugPrint('[NEXUS] initServicesAfterIdentity error: $e');
    rethrow; // propagate to main() so _CrashReportApp is shown
  }
}

// ── App widget ────────────────────────────────────────────────────────────────

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
          return NotificationBannerOverlay(
            onTap: (conversationId) {
              debugPrint('[NOTIF] Banner tap: $conversationId');
            },
            child: _SplashWrapper(child: child!),
          );
        },
      ),
    );
  }
}

// ── Crash report app ──────────────────────────────────────────────────────────

/// Shown instead of the main app when startup itself fails fatally.
/// Provides a "Retry" button (re-runs init), an "Export log" button
/// (copies crash log to clipboard), and an "Exit" button.
class _CrashReportApp extends StatefulWidget {
  final Object error;
  final StackTrace? stackTrace;
  final String logPath;

  const _CrashReportApp({
    required this.error,
    required this.logPath,
    this.stackTrace,
  });

  @override
  State<_CrashReportApp> createState() => _CrashReportAppState();
}

class _CrashReportAppState extends State<_CrashReportApp> {
  bool _retrying = false;
  Object? _lastError;
  bool _logCopied = false;

  @override
  void initState() {
    super.initState();
    _lastError = widget.error;
  }

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _lastError = null;
    });
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      await IdentityService.instance.init();
      if (IdentityService.instance.hasIdentity) {
        await initServicesAfterIdentity();
      }
      // Success – replace the crash screen with the real app.
      runApp(const NexusApp());
    } catch (e, st) {
      _logCrash('_CrashReportApp.retry', e, st);
      setState(() {
        _retrying = false;
        _lastError = e;
      });
    }
  }

  Future<void> _exportLog() async {
    try {
      final logFile = File(widget.logPath);
      final content = await logFile.exists()
          ? await logFile.readAsString()
          : 'Log file not found at: ${widget.logPath}';
      await Clipboard.setData(ClipboardData(text: content));
      setState(() => _logCopied = true);
      Future.delayed(const Duration(seconds: 3),
          () { if (mounted) setState(() => _logCopied = false); });
    } catch (e) {
      debugPrint('[NEXUS] Could not export log: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NEXUS OneApp',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        backgroundColor: const Color(0xFF0D1B2A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFFD4AF37), size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Beim Starten ist ein Fehler aufgetreten',
                  style: TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'NEXUS konnte nicht vollständig starten. '
                  'Versuche es erneut oder exportiere das Crash-Log '
                  'und sende es an den Support.',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 16),
                // Error detail box (collapsible feel via clipping)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2D3E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    (_lastError ?? widget.error).toString(),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                // Log path
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2D3E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: const Color(0xFFD4AF37).withAlpha(60)),
                  ),
                  child: Text(
                    widget.logPath,
                    style: const TextStyle(
                      color: Color(0xFFD4AF37),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // ── Action buttons ───────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4AF37),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _retrying ? null : _retry,
                    icon: _retrying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black54),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_retrying ? 'Wird gestartet…' : 'Erneut versuchen'),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD4AF37),
                          side: const BorderSide(color: Color(0xFFD4AF37)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _exportLog,
                        icon: Icon(_logCopied
                            ? Icons.check
                            : Icons.content_copy_outlined,
                            size: 18),
                        label: Text(_logCopied
                            ? 'Kopiert!'
                            : 'Crash-Log kopieren'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white54,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => exit(0),
                        child: const Text('App beenden'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Splash wrapper ────────────────────────────────────────────────────────────

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
    return Scaffold(
      backgroundColor: AppColors.deepBlue,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _NexusLogo(),
            const SizedBox(height: 32),
            const Text(
              'N.E.X.U.S. OneApp',
              style: TextStyle(
                color: AppColors.gold,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
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
