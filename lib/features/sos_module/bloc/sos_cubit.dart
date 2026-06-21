import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/sos_message.dart';
import '../services/location_service.dart';
import '../services/messaging_service.dart';
import '../services/sos_background_service.dart';
import '../services/sos_permissions.dart';
import 'sos_state.dart';

/// Orchestrates the Manual SOS + Safe Mode workflow.
///
/// All side-effecting work goes through injected services, so the cubit is
/// unit-testable with fakes and the delivery channel is swappable.
class SosCubit extends Cubit<SosState> {
  SosCubit({
    required List<String> recipients,
    MessagingService? messaging,
    LocationService location = const LocationService(),
    SosPermissions permissions = const SosPermissions(),
    SosBackgroundService background = const SosBackgroundService(),
  })  : _recipients = recipients,
        _messaging = messaging ?? const SmsMessagingService(),
        _location = location,
        _permissions = permissions,
        _background = background,
        super(const SosState()) {
    // The background isolate reports the saved recording path when it stops.
    _audioSavedSub = FlutterBackgroundService()
        .on('sosAudioSaved')
        .listen((event) {
      final path = event?['path'] as String?;
      _lastAudioPath = path;
      if (_audioWaiter != null && !_audioWaiter!.isCompleted) {
        _audioWaiter!.complete(path);
      }
    });
  }

  final List<String> _recipients;
  final MessagingService _messaging;
  final LocationService _location;
  final SosPermissions _permissions;
  final SosBackgroundService _background;

  StreamSubscription<Map<String, dynamic>?>? _audioSavedSub;
  Completer<String?>? _audioWaiter;
  String? _lastAudioPath;

  static const String _alertBody =
      '🚨 Emergency! I need help. This is my live location:';

  /// Step 1 of the workflow: triggered by the SOS button.
  ///
  /// Edge case: if an SOS is already dispatching/active, the press is ignored.
  Future<void> triggerSos() async {
    if (state.status != SosStatus.idle) {
      debugPrint('[SOS] triggerSos ignored (status=${state.status}).');
      return;
    }

    // Permission gate — never crash on denial; surface an error the UI turns
    // into a dialog.
    final perm = await _permissions.ensure();
    if (!perm.allGranted) {
      emit(state.copyWith(
        status: SosStatus.error,
        errorMessage:
            '${perm.missingSummary} permission is required to start SOS.',
      ));
      return;
    }

    emit(state.copyWith(status: SosStatus.dispatching));

    // Mandatory 3-second wait before anything is dispatched.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (state.status != SosStatus.dispatching) return; // safety re-check

    // Build the live-location link from a quick fix.
    final pos = await _location.currentPosition();
    final link = pos != null ? _location.buildMapsLink(pos) : null;

    // Notify contacts. A delivery failure must NOT abort the SOS.
    try {
      await _messaging.send(MessagePayload(
        recipients: _recipients,
        body: _alertBody,
        locationLink: link,
      ));
    } catch (e) {
      debugPrint('[SOS] initial message failed: $e');
    }

    // Start background recording + live location (survives lock/minimize).
    _lastAudioPath = null;
    await _background.start(recordAudio: true);

    emit(state.copyWith(status: SosStatus.active, locationLink: link));
  }

  /// Step 2 of the workflow: triggered by the Safe button.
  ///
  /// Edge case: ignored when no SOS is active.
  Future<void> markSafe() async {
    if (state.status != SosStatus.active) {
      debugPrint('[SOS] markSafe ignored (status=${state.status}).');
      return;
    }

    // Stop the background service and wait for it to flush the recording path.
    _audioWaiter = Completer<String?>();
    await _background.stop();
    final String? audioPath = await _audioWaiter!.future
        .timeout(const Duration(seconds: 4), onTimeout: () => _lastAudioPath);
    _audioWaiter = null;

    // Final "ok" message, with the recording attached (see SmsMessagingService
    // for the documented sms: attachment limitation).
    try {
      await _messaging.send(MessagePayload(
        recipients: _recipients,
        body: 'ok',
        attachmentPath: audioPath,
      ));
    } catch (e) {
      debugPrint('[SOS] final message failed: $e');
    }

    emit(const SosState()); // back to idle
  }

  /// Called by the UI after it has shown the error dialog, to return to idle.
  void clearError() {
    if (state.status == SosStatus.error) {
      emit(const SosState());
    }
  }

  @override
  Future<void> close() {
    _audioSavedSub?.cancel();
    return super.close();
  }
}
