import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/identicon.dart';

/// Data for a single in-app notification banner.
class InAppBannerData {
  final String senderName;
  final String preview;
  final String conversationId;
  final bool isBroadcast;

  const InAppBannerData({
    required this.senderName,
    required this.preview,
    required this.conversationId,
    this.isBroadcast = false,
  });
}

/// Singleton controller.  ChatProvider calls [show]; the root widget tree
/// wraps content in [NotificationBannerOverlay].
class InAppNotificationController extends ChangeNotifier {
  static final instance = InAppNotificationController._();
  InAppNotificationController._();

  InAppBannerData? _current;
  Timer? _timer;

  InAppBannerData? get current => _current;

  void show(InAppBannerData data) {
    _timer?.cancel();
    _current = data;
    notifyListeners();
    _timer = Timer(const Duration(seconds: 3), dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _current = null;
    notifyListeners();
  }
}

/// Wrap the app's body with this to get the banner overlay.
class NotificationBannerOverlay extends StatelessWidget {
  const NotificationBannerOverlay({super.key, required this.child, this.onTap});
  final Widget child;
  final void Function(String conversationId)? onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        _BannerLayer(onTap: onTap),
      ],
    );
  }
}

class _BannerLayer extends StatefulWidget {
  const _BannerLayer({this.onTap});
  final void Function(String)? onTap;

  @override
  State<_BannerLayer> createState() => _BannerLayerState();
}

class _BannerLayerState extends State<_BannerLayer>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<Offset> _slide;
  InAppBannerData? _data;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    InAppNotificationController.instance.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final d = InAppNotificationController.instance.current;
    if (d != null) {
      setState(() => _data = d);
      _anim.forward(from: 0);
    } else {
      _anim.reverse().then((_) {
        if (mounted) setState(() => _data = null);
      });
    }
  }

  @override
  void dispose() {
    InAppNotificationController.instance.removeListener(_onControllerChanged);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: _BannerCard(
          data: _data!,
          onTap: () {
            InAppNotificationController.instance.dismiss();
            widget.onTap?.call(_data!.conversationId);
          },
          onDismiss: InAppNotificationController.instance.dismiss,
        ),
      ),
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.data,
    required this.onTap,
    required this.onDismiss,
  });
  final InAppBannerData data;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return GestureDetector(
      onTap: onTap,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy < -4) onDismiss();
      },
      child: Container(
        margin: EdgeInsets.fromLTRB(8, topPadding + 8, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipOval(
              child: Identicon(
                bytes: data.senderName.codeUnits,
                size: 40,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.senderName,
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.preview,
                    style: const TextStyle(
                      color: AppColors.onDark,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.grey),
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }
}
