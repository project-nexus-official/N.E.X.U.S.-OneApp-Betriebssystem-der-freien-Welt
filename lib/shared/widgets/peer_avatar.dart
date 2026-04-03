import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/profile/profile_image_service.dart';
import 'identicon.dart';

/// A circular avatar that shows a cached profile image when available,
/// falling back to an [Identicon] derived from the peer's DID.
///
/// Usage:
/// ```dart
/// PeerAvatar(did: contact.did, profileImage: contact.profileImage, size: 48)
/// ```
class PeerAvatar extends StatefulWidget {
  const PeerAvatar({
    super.key,
    required this.did,
    this.profileImage,
    this.size = 48,
  });

  final String did;

  /// Local file path to a cached JPEG (e.g. from a received Kind-0 event).
  /// When null or the file is missing the Identicon is shown instead.
  final String? profileImage;

  final double size;

  @override
  State<PeerAvatar> createState() => _PeerAvatarState();
}

class _PeerAvatarState extends State<PeerAvatar> {
  String? _resolvedPath;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolvePath();
  }

  @override
  void didUpdateWidget(PeerAvatar old) {
    super.didUpdateWidget(old);
    if (old.profileImage != widget.profileImage) _resolvePath();
  }

  Future<void> _resolvePath() async {
    if (widget.profileImage == null) {
      debugPrint('[PeerAvatar] did=…${_shortDid()}  profileImage=null → identicon');
      if (mounted) setState(() { _resolvedPath = null; _resolved = true; });
      return;
    }

    // Fast path: file already exists at stored path.
    if (File(widget.profileImage!).existsSync()) {
      debugPrint('[PeerAvatar] did=…${_shortDid()}  '
          'imagePath=${widget.profileImage}  file exists: true');
      if (mounted) setState(() { _resolvedPath = widget.profileImage; _resolved = true; });
      return;
    }

    // Slow path: reconstruct path (handles Android path changes after reinstall).
    debugPrint('[PeerAvatar] did=…${_shortDid()}  '
        'imagePath=${widget.profileImage}  file exists: false → resolving…');
    final resolved =
        await ProfileImageService.instance.resolveLocalPath(widget.profileImage);
    debugPrint('[PeerAvatar] did=…${_shortDid()}  resolved=$resolved');
    if (mounted) setState(() { _resolvedPath = resolved; _resolved = true; });
  }

  String _shortDid() {
    final d = widget.did;
    return d.length > 8 ? d.substring(d.length - 8) : d;
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved) {
      // Show identicon while async resolution is in progress.
      return ClipOval(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Identicon(bytes: widget.did.codeUnits, size: widget.size),
        ),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _resolvedPath != null
            ? Image.file(
                File(_resolvedPath!),
                fit: BoxFit.cover,
                width: widget.size,
                height: widget.size,
                errorBuilder: (_, __, ___) =>
                    Identicon(bytes: widget.did.codeUnits, size: widget.size),
              )
            : Identicon(bytes: widget.did.codeUnits, size: widget.size),
      ),
    );
  }
}
