import 'package:permission_handler/permission_handler.dart';

/// Result of a permission check, so the UI can decide what to show.
class SosPermissionResult {
  const SosPermissionResult({
    required this.microphoneGranted,
    required this.locationGranted,
  });

  final bool microphoneGranted;
  final bool locationGranted;

  bool get allGranted => microphoneGranted && locationGranted;

  /// Human-readable list of what's still missing, for the dialog body.
  String get missingSummary {
    final missing = <String>[];
    if (!microphoneGranted) missing.add('Microphone');
    if (!locationGranted) missing.add('Location (Always)');
    return missing.join(' and ');
  }
}

/// Requests and reports the permissions the SOS flow needs (microphone for
/// recording, "always" location for background tracking). The caller (the
/// cubit / UI) decides how to react — we never crash on denial.
class SosPermissions {
  const SosPermissions();

  Future<SosPermissionResult> ensure() async {
    final micStatus = await Permission.microphone.request();

    // Ask for foreground location first; "always" is requested on top so the
    // background service can keep tracking when the app is minimized/locked.
    await Permission.locationWhenInUse.request();
    final locStatus = await Permission.locationAlways.request();

    return SosPermissionResult(
      microphoneGranted: micStatus.isGranted,
      locationGranted: locStatus.isGranted || locStatus.isLimited,
    );
  }

  /// Opens the OS settings page so a user who permanently denied a permission
  /// can re-enable it.
  Future<void> openSettings() => openAppSettings();
}
