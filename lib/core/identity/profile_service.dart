import 'package:nexus_oneapp/core/storage/pod_database.dart';
import 'profile.dart';

const _podKey = 'user_profile';

/// Loads and persists the user's [UserProfile] in the encrypted local POD.
class ProfileService {
  static final ProfileService instance = ProfileService._();
  ProfileService._();

  UserProfile? _profile;
  UserProfile? get currentProfile => _profile;
  bool get isLoaded => _profile != null;

  /// Loads the profile from the POD. Falls back to a default profile
  /// seeded with [pseudonym] if no profile has been saved yet.
  Future<void> load(String pseudonym) async {
    try {
      final data = await PodDatabase.instance.getIdentityValue(_podKey);
      _profile = data != null
          ? UserProfile.fromJson(data)
          : UserProfile.defaults(pseudonym);
    } catch (_) {
      _profile = UserProfile.defaults(pseudonym);
    }
  }

  /// Persists [profile] to the POD and updates the in-memory cache.
  Future<void> save(UserProfile profile) async {
    _profile = profile;
    await PodDatabase.instance.setIdentityValue(_podKey, profile.toJson());
  }
}
