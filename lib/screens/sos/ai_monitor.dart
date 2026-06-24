import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/api_config.dart';

/// Stage-1 listen window: a short clip is continuously transcribed and checked
/// against the danger dictionary. Cheap, runs constantly.
const Duration kListenWindow = Duration(seconds: 12);

/// Stage-2 evidence clip: recorded only AFTER a danger keyword is detected,
/// then passed to the emotion model (and stored as evidence). Heavy, rare.
const Duration kAiChunkDuration = Duration(minutes: 2);

/// SharedPreferences flag set by the background service while an SOS is active.
/// The foreground monitor checks it and steps aside so the two isolates never
/// fight over the microphone.
const String kSosActiveKey = 'sos_active';

/// SharedPreferences flag for the master "AI Auto Mode" toggle in Settings.
/// When false, the whole auto-detection pipeline is disabled (manual SOS still
/// works).
const String kAiAutoModeKey = 'ai_auto_mode_enabled';

/// SharedPreferences flag for the "Emotion Detection" toggle in Settings.
/// When false, the emotion model is skipped and a danger-word hit triggers the
/// SOS directly.
const String kEmotionDetectionKey = 'emotion_detection_enabled';

/// SharedPreferences flag tracking whether the app is currently in the
/// foreground. Written by the home screen's lifecycle observer (true on resume,
/// false once truly backgrounded). The background isolate's pre-SOS danger
/// monitor reads it so it only grabs the microphone while the app is closed,
/// handing the mic back to the foreground monitor when the app is open. This
/// mirrors the [kSosActiveKey] handshake — both prevent the two monitors from
/// fighting over RECORD_AUDIO.
const String kAppForegroundKey = 'app_in_foreground';

/// SharedPreferences key for cached custom zones (shared with the map screen).
/// Each entry is a JSON object: `{id, name, isDanger, lat, lng, radius}`.
const String _kCustomZonesKey = 'user_custom_zones_local';

/// Stage 1 — cheap & constant. Transcribes [filePath] (speech-to-text) and
/// checks the text against the backend danger dictionary. Returns true when a
/// danger keyword/phrase is found.
Future<bool> screenForDanger(
  String filePath, {
  required String locationText,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('auth_token');

    // Speech-to-text.
    final sttReq = http.MultipartRequest('POST', Uri.parse(ApiConfig.sttUrl));
    sttReq.files.add(await http.MultipartFile.fromPath('audio', filePath));
    final sttResp = await http.Response.fromStream(await sttReq.send());
    final String text = jsonDecode(sttResp.body)['text']?.toString() ?? 'nothing';
    if (text == 'nothing' || text == 'null' || text.trim().isEmpty) {
      return false;
    }

    // Danger-word dictionary check (backend).
    final dangerResp = await http.post(
      Uri.parse(ApiConfig.dictionaryCheckUrl),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      body: {'text': text, 'location_text': locationText},
    );
    return dangerResp.statusCode == 200 &&
        jsonDecode(dangerResp.body)['danger_detected'] == true;
  } catch (e) {
    debugPrint('[AI-MONITOR] stage-1 screen error: $e');
    return false;
  }
}

/// Stage 2 — heavy & rare. Runs the emotion / voice-stress model on [filePath]
/// (a ~2-minute clip). This model is the final decision-maker: returns true
/// when it confirms distress and the SOS should fire.
Future<bool> confirmEmotion(String filePath) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final String userId = prefs.getString('user_id') ?? '0';

    final emoReq = http.MultipartRequest('POST', Uri.parse(ApiConfig.emotionUrl));
    emoReq.files.add(await http.MultipartFile.fromPath('file', filePath));
    emoReq.fields['user_id'] = userId;
    final emoResp = await http.Response.fromStream(await emoReq.send());
    return jsonDecode(emoResp.body)['trigger_sos'] == true;
  } catch (e) {
    debugPrint('[AI-MONITOR] stage-2 emotion error: $e');
    return false;
  }
}

/// Runs the full two-stage pipeline on a single clip: stage 1 (STT + danger
/// dictionary) and, on a keyword hit, stage 2 (emotion model). Honors the
/// Emotion Detection toggle — when it is off a danger-word hit triggers
/// directly. Used by the background evidence loop during an active SOS.
Future<bool> analyzeAudioChunk(
  String filePath, {
  required String locationText,
}) async {
  if (!await screenForDanger(filePath, locationText: locationText)) {
    return false;
  }
  final prefs = await SharedPreferences.getInstance();
  final bool emotionEnabled = prefs.getBool(kEmotionDetectionKey) ?? true;
  if (!emotionEnabled) {
    debugPrint('[AI-MONITOR] emotion off; danger words trigger SOS directly.');
    return true;
  }
  return confirmEmotion(filePath);
}

/// Returns true when [lat]/[lng] falls inside any user-defined SAFE zone (a
/// custom zone with `isDanger != true`). The AI auto pipeline pauses inside
/// safe zones; manual SOS is unaffected.
Future<bool> isInsideSafeZone(double lat, double lng) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_kCustomZonesKey) ?? const [];
    for (final entry in raw) {
      final Map<String, dynamic> z = jsonDecode(entry) as Map<String, dynamic>;
      if (z['isDanger'] == true) continue; // danger zones don't pause the AI
      final double zlat = (z['lat'] as num).toDouble();
      final double zlng = (z['lng'] as num).toDouble();
      final double radius = (z['radius'] as num).toDouble();
      if (Geolocator.distanceBetween(lat, lng, zlat, zlng) <= radius) {
        return true;
      }
    }
  } catch (e) {
    debugPrint('[AI-MONITOR] safe-zone check error: $e');
  }
  return false;
}

/// Best-effort upload of a monitoring recording to the backend so the audio is
/// stored as evidence. During an active SOS ([sosId] > 0) it attaches to that
/// session's `uploadAudio` endpoint; otherwise it posts to the general monitor
/// endpoint. Failures are swallowed so monitoring never breaks.
Future<void> uploadRecordingToBackend(
  String filePath, {
  int? sosId,
  String? token,
}) async {
  try {
    if (!await File(filePath).exists()) return;

    final prefs = await SharedPreferences.getInstance();
    token ??= prefs.getString('auth_token');

    final bool hasSos = sosId != null && sosId > 0;
    final Uri uri = hasSos
        ? Uri.parse('${ApiConfig.sosBaseUrl}/$sosId/uploadAudio')
        : Uri.parse(ApiConfig.monitorAudioUrl);

    final req = http.MultipartRequest('POST', uri);
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(
      await http.MultipartFile.fromPath(hasSos ? 'audio_file' : 'audio', filePath),
    );
    final resp = await req.send().timeout(const Duration(seconds: 30));
    debugPrint('[AI-MONITOR] recording uploaded (${resp.statusCode}) → $uri');
  } catch (e) {
    debugPrint('[AI-MONITOR] recording upload failed: $e');
  }
}
