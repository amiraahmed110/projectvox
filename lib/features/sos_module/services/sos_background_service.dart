import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_service.dart';

/// Notification channel id for THIS module's foreground service. Deliberately
/// distinct from the existing app's `voxguard_emergency` channel.
const String kSosModuleChannelId = 'sos_module_channel';

/// Background foreground-service for the standalone SOS module. Keeps audio
/// recording + live location running while the screen is locked or the app is
/// minimized.
///
/// ⚠️ SINGLETON CAVEAT: `flutter_background_service` supports only ONE
/// configured service per app. This app already configures one in
/// `lib/screens/sos/background_service.dart` (called from `main.dart`). To run
/// THIS module standalone, call [SosBackgroundService.configure] from
/// `main.dart` and do NOT also call the existing `initializeBackgroundService`.
/// Wiring both flows into one build requires merging their `onStart` handlers
/// into a single router; that is intentionally out of scope for this module.
class SosBackgroundService {
  const SosBackgroundService();

  /// Configure the service. Call once at startup (e.g. in `main`).
  /// Does NOT auto-start — the service starts only when an SOS begins.
  static Future<void> configure() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: sosOnStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: kSosModuleChannelId,
        initialNotificationTitle: 'SOS',
        initialNotificationContent: 'Emergency mode active',
        foregroundServiceTypes: const [
          AndroidForegroundType.location,
          AndroidForegroundType.microphone,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: sosOnStart,
        onBackground: _iosOnBackground,
      ),
    );
  }

  /// Start the service and hand it the session flags.
  Future<void> start({required bool recordAudio}) async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    // Give the isolate a moment to spin up before delivering the payload.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    service.invoke('startSOS', {'record_audio': recordAudio});
  }

  /// Stop the service (triggers cleanup + final audio flush in the isolate).
  Future<void> stop() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopService');
    }
  }
}

@pragma('vm:entry-point')
Future<bool> _iosOnBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// Background isolate entry point. Records one continuous audio file and
/// streams location while the SOS is active.
@pragma('vm:entry-point')
void sosOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  final AudioService audio = AudioService();
  StreamSubscription<Position>? locationSub;
  String? audioPath;

  service.on('startSOS').listen((event) async {
    final bool recordAudio = (event?['record_audio'] as bool?) ?? false;

    // Live location stream (geolocator's onLocationChanged equivalent).
    locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      debugPrint('[SOS-BG] 📍 ${pos.latitude}, ${pos.longitude}');
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'SOS — Active',
          content: 'Sharing location'
              '${recordAudio ? ' & recording audio' : ''}…',
        );
      }
    });

    // Single continuous recording. permission_handler is the source of truth
    // for mic status inside the isolate (record's hasPermission() is
    // unreliable in a background isolate).
    if (recordAudio && await Permission.microphone.isGranted) {
      try {
        audioPath = await audio.start();
        debugPrint('[SOS-BG] 🎙️ recording → $audioPath');
      } catch (e) {
        debugPrint('[SOS-BG] recording failed: $e');
      }
    }
  });

  service.on('stopService').listen((event) async {
    await locationSub?.cancel();
    final String? saved = await audio.stop();
    await audio.dispose();
    debugPrint('[SOS-BG] 🛑 recording saved → $saved');
    // Surface the saved file path back to the UI isolate before shutting down.
    final String? path = saved ?? audioPath;
    if (path != null && await File(path).exists()) {
      service.invoke('sosAudioSaved', {'path': path});
    }
    service.stopSelf();
  });
}
