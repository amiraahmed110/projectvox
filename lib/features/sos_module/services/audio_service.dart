import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Records ambient audio to a single continuous local file for the duration of
/// an SOS, then returns that file's path so it can be attached to the final
/// "Safe" message.
///
/// This differs on purpose from the existing chunked-upload background recorder
/// (`lib/screens/sos/background_service.dart`): here we keep ONE file that
/// survives until the user marks themselves safe.
class AudioService {
  AudioService([AudioRecorder? recorder])
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  String? _currentPath;

  /// Starts a new continuous recording in the app documents directory.
  /// Returns the file path being written to.
  Future<String> start() async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/sos_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _currentPath = path;
    debugPrint('[AUDIO] recording started → $path');
    return path;
  }

  /// Stops recording and returns the saved file path (null if nothing was
  /// recorded or the file is missing). Safe to call when not recording.
  Future<String?> stop() async {
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (e) {
      debugPrint('[AUDIO] stop error: $e');
    }

    final path = _currentPath;
    _currentPath = null;
    if (path == null) return null;
    final exists = await File(path).exists();
    debugPrint('[AUDIO] recording stopped → $path (exists=$exists)');
    return exists ? path : null;
  }

  Future<bool> isRecording() => _recorder.isRecording();

  /// Releases the underlying recorder. Call when the owning object is disposed.
  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {/* ignore */}
  }
}
