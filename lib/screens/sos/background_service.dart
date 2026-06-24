import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/api_config.dart';
import 'ai_monitor.dart';
import 'sos_service.dart';

/// SharedPreferences key holding the rolling background diagnostic log.
/// Single source of truth shared with the in-app log viewer.
const String kSosBgLogKey = 'sos_bg_log';

/// Max number of entries kept in the on-device log before old ones roll off.
const int _kSosLogMaxEntries = 500;

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'voxguard_emergency',
      initialNotificationTitle: 'VoxGuard Active',
      initialNotificationContent: 'Protection running in background',
      foregroundServiceTypes: [
        AndroidForegroundType.location,
        AndroidForegroundType.microphone,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  await _log('🟢 onStart: background isolate launched.');

  // تعريف المتغيرات في الأعلى لتكون متاحة داخل الـ Listeners
  final AudioRecorder audioRecorder = AudioRecorder();
  StreamSubscription<Position>? locationSub;
  Timer? chunkTimer;

  // حالة الجلسة الحالية، تُملأ عند استقبال إشارة الـ SOS.
  int? sosId;
  String? token;
  bool shareLocation = false;
  bool recordAudio = false;
  bool audioEnabled = false; // مفعّل عندما يكون المايك مسموحاً والتسجيل جارياً
  bool processingChunk = false; // لمنع تداخل معالجة المقاطع
  int locationPoints = 0;
  String lastLocationText = '';
  double? lastLat; // آخر إحداثيات معروفة — لفحص المناطق الآمنة في مراقبة ما قبل الـ SOS
  double? lastLng;

  // يبدأ تسجيل مقطع جديد (مدة المقطع يحكمها مؤقّت الـ 2 دقيقة).
  Future<void> startChunk() async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/sos_${sosId}_${DateTime.now().millisecondsSinceEpoch}.wav';
    await audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    await _log('🎙️ Recording chunk started → $path');
  }

  // يوقف المقطع الحالي، يرسله للـ AI model + الباك-إند، ثم يبدأ المقطع التالي
  // (عند restart). هذه هي نفس معالجة الواجهة لكنها تعمل في الخلفية أثناء الـ SOS.
  Future<void> processChunk({required bool restart}) async {
    if (processingChunk) return;
    processingChunk = true;
    try {
      String? path;
      if (await audioRecorder.isRecording()) {
        path = await audioRecorder.stop();
      }
      if (path != null) {
        int sizeBytes = -1;
        try {
          final f = File(path);
          if (await f.exists()) sizeBytes = await f.length();
        } catch (_) {/* diagnostic only */}
        await _log('🎙️ Chunk captured → $path '
            '(${sizeBytes >= 0 ? '$sizeBytes bytes' : 'size unknown'})');

        // إرسال المقطع للباك-إند (دليل) ثم تحليله بالـ AI model.
        await uploadRecordingToBackend(path, sosId: sosId, token: token);
        final bool flagged =
            await analyzeAudioChunk(path, locationText: lastLocationText);
        await _log(flagged
            ? '🚨 AI re-flagged danger during active SOS.'
            : '🤖 AI chunk analysed (no new trigger).');

        // تم رفع المقطع — نحذف النسخة المحلية لتوفير المساحة.
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {/* ignore */}
      }
    } catch (e) {
      await _log('❌ Chunk processing error: $e');
    } finally {
      processingChunk = false;
    }

    if (restart && audioEnabled) {
      try {
        await startChunk();
      } catch (e) {
        await _log('❌ Failed to restart chunk: $e');
      }
    }
  }

  // تفعيل جلسة SOS — يُستدعى من الواجهة (عبر startSOS) ومن المراقبة التلقائية في
  // الخلفية على حدٍّ سواء: يضبط حالة الجلسة، يرفع علم النشاط، ويبدأ تسجيل/تحليل
  // الصوت بالمقاطع. تسجيل الموقع يبدأ تلقائياً من مُستمع الموقع بمجرد ضبط sosId.
  Future<void> activateSos({
    required int? newSosId,
    required String? newToken,
    required bool newShareLocation,
    required bool newRecordAudio,
  }) async {
    sosId = newSosId;
    token = newToken;
    shareLocation = newShareLocation;
    recordAudio = newRecordAudio;
    locationPoints = 0;

    // علم يخبر مراقب الواجهة أن الـ SOS نشط فيتنحّى عن المايك.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kSosActiveKey, true);

    // معرف سالب => جلسة وهمية (السيرفر غير متاح) فلا نرفع البيانات للسيرفر.
    final bool isMock = sosId != null && sosId! < 0;

    await _log('📡 START | id=$sosId | mock=$isMock | '
        'share_location=$shareLocation | record_audio=$recordAudio | '
        'token=${token == null ? 'null' : 'present(len=${token!.length})'}');

    // تسجيل حالة إذن المايك الفعلية على مستوى النظام (قيمة تشخيصية مهمة).
    try {
      final micStatus = await Permission.microphone.status;
      await _log('🔐 mic permission status = $micStatus');
    } catch (e) {
      await _log('🔐 mic permission check failed: $e');
    }

    // تأكيد مرئي للمستخدم بأن التقاط البيانات يعمل فعلياً في الخلفية.
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'VoxGuard — SOS Active',
        content: 'Capturing location'
            '${recordAudio ? ' & recording audio' : ''} in background…',
      );
    }

    // بدء تسجيل/تحليل الصوت في الخلفية على شكل مقاطع كل دقيقتين.
    //
    // ملاحظة: AudioRecorder.hasPermission() من حزمة record غير موثوق داخل عزلة
    // الخلفية (يحتاج Activity ليستعلم/يطلب الإذن فيرجع false حتى وإن كان الإذن
    // ممنوحاً فعلاً). نعتمد بدلاً منه على حالة permission_handler التي تقرأ حالة
    // النظام الحقيقية.
    if (recordAudio) {
      final bool micGranted = await Permission.microphone.isGranted;
      if (micGranted) {
        try {
          audioEnabled = true;
          await startChunk();
          chunkTimer?.cancel();
          chunkTimer = Timer.periodic(
            kAiChunkDuration,
            (_) => processChunk(restart: true),
          );
          await _log('⏱️ Chunk monitor started (every ${kAiChunkDuration.inMinutes}m).');
        } catch (e) {
          await _log('❌ Failed to start recording: $e');
        }
      } else {
        await _log('⚠️ Microphone permission denied (OS status); not recording.');
      }
    } else {
      await _log('🔇 record_audio=false; audio capture disabled this session.');
    }
  }

  // الاستماع لإشارة الـ SOS القادمة من الواجهة (تشغيل يدوي / ذكاء عند فتح
  // التطبيق): تُمرَّر بيانات الجلسة الجاهزة فنفعّلها كما هي.
  service.on('startSOS').listen((event) async {
    if (event == null) {
      await _log('⚠️ startSOS received a null payload; ignoring.');
      return;
    }
    await activateSos(
      newSosId: event['sos_id'] as int?,
      newToken: event['token'] as String?,
      newShareLocation: event['share_location'] ?? true,
      newRecordAudio: event['record_audio'] ?? false,
    );
  });

  // يسجّل مقطعاً قصيراً للاستماع (مرحلة ما قبل الـ SOS) ويعيد مساره. يتوقّف مبكراً
  // إذا بدأت جلسة SOS أو عاد التطبيق إلى المقدمة، كي يسلّم المايك للواجهة فوراً.
  Future<String?> recordListenClip(Duration duration) async {
    try {
      if (!await Permission.microphone.isGranted) return null;

      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/presos_${DateTime.now().millisecondsSinceEpoch}.wav';
      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      final prefs = await SharedPreferences.getInstance();
      final sw = Stopwatch()..start();
      while (sw.elapsed < duration) {
        // إعادة تحميل القيم عبر العزلات لرصد تغيّر الحالة من واجهة المستخدم.
        await prefs.reload();
        if ((prefs.getBool(kSosActiveKey) ?? false) ||
            (prefs.getBool(kAppForegroundKey) ?? false)) {
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!await audioRecorder.isRecording()) return null;
      return await audioRecorder.stop();
    } catch (e) {
      await _log('⚠️ pre-SOS listen clip error: $e');
      try {
        if (await audioRecorder.isRecording()) await audioRecorder.stop();
      } catch (_) {}
      return null;
    }
  }

  // عند تأكيد الخطر في الخلفية: نفتح جلسة SOS حقيقية (أو وهمية عند تعذّر السيرفر)
  // ثم نفعّلها لبدء بث الموقع وتسجيل الأدلة — نفس مسار الـ SOS اليدوي تماماً.
  Future<void> triggerAutoSos() async {
    await _log('🚨 AI confirmed danger in background — auto-starting SOS.');
    const SosService sos = SosService();
    final session = await sos.startSession(triggerType: 'ai_auto');
    if (session == null) {
      await _log('❌ auto-SOS: could not open a session; will keep listening.');
      return;
    }
    await activateSos(
      newSosId: session.sosId,
      newToken: session.token,
      newShareLocation: true,
      newRecordAudio: true,
    );
  }

  // حلقة المراقبة المستمرة قبل الـ SOS. تعمل فقط عندما يكون التطبيق في الخلفية
  // (مراقبُ الواجهة يملك المايك عند فتح التطبيق) ولا توجد جلسة SOS نشطة. تنفّذ
  // نفس خط الأنابيب ذي المرحلتين، وعند التأكيد تُطلق الـ SOS تلقائياً.
  Future<void> preSosMonitorLoop() async {
    await _log('👂 Pre-SOS background monitor active (continuous).');
    final prefs = await SharedPreferences.getInstance();
    while (true) {
      try {
        await prefs.reload();
        final bool sosActive = prefs.getBool(kSosActiveKey) ?? false;
        // الافتراضي true: حتى أول مرة يُؤكَّد فيها أن التطبيق في الخلفية لا نستمع،
        // فيبقى المايك لمراقب الواجهة عند الإقلاع/التشغيل في المقدمة.
        final bool appForeground = prefs.getBool(kAppForegroundKey) ?? true;
        final bool aiOn = prefs.getBool(kAiAutoModeKey) ?? true;
        final bool micGranted = await Permission.microphone.isGranted;

        // نستمع فقط عندما: التطبيق في الخلفية، ولا SOS نشط، والوضع التلقائي مفعّل،
        // والمايك مسموح.
        if (sosActive || appForeground || !aiOn || !micGranted) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        // احترام المناطق الآمنة التي عرّفها المستخدم (كما في مراقب الواجهة).
        if (lastLat != null &&
            lastLng != null &&
            await isInsideSafeZone(lastLat!, lastLng!)) {
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }

        // المرحلة 1 — نافذة استماع قصيرة وفحص كلمات الخطر.
        final String? clip = await recordListenClip(kListenWindow);
        if (clip == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        final bool danger =
            await screenForDanger(clip, locationText: lastLocationText);
        try {
          final f = File(clip);
          if (await f.exists()) await f.delete();
        } catch (_) {}
        if (!danger) continue;

        // تأكّد أننا ما زلنا نملك المايك قبل المرحلة الثقيلة.
        await prefs.reload();
        if ((prefs.getBool(kSosActiveKey) ?? false) ||
            (prefs.getBool(kAppForegroundKey) ?? false)) {
          continue;
        }

        // إيقاف كشف المشاعر => كلمة خطر تُطلق الـ SOS مباشرة.
        final bool emotionEnabled =
            prefs.getBool(kEmotionDetectionKey) ?? true;
        if (!emotionEnabled) {
          await _log('🚨 Danger word detected in background (emotion off).');
          await triggerAutoSos();
          continue;
        }

        // المرحلة 2 — مقطع دليل (دقيقتان) + نموذج المشاعر (القرار النهائي).
        await _log('🔎 Danger word hit in background — confirming with emotion.');
        final String? evidence = await recordListenClip(kAiChunkDuration);
        if (evidence == null) continue;
        await uploadRecordingToBackend(evidence); // ما قبل الـ SOS => مسار المراقبة
        final bool confirmed = await confirmEmotion(evidence);
        try {
          final f = File(evidence);
          if (await f.exists()) await f.delete();
        } catch (_) {}

        if (confirmed) {
          await triggerAutoSos();
        } else {
          await _log('🤖 Emotion model did not confirm; staying in listen mode.');
        }
      } catch (e) {
        await _log('❌ pre-SOS monitor loop error: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  // بث الموقع المباشر وتسجيله في الخلفية أثناء عمل الـ SOS.
  locationSub = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
  ).listen((pos) async {
    lastLocationText = '${pos.latitude}, ${pos.longitude}';
    lastLat = pos.latitude;
    lastLng = pos.longitude;

    // قبل بدء الـ SOS أو عند إيقاف مشاركة الموقع: طباعة خفيفة فقط (بدون حفظ)
    // لتفادي إغراق السجل الدائم بنقاط الخمول.
    if (sosId == null || !shareLocation) {
      debugPrint('[BG-SOS] 📍 location (idle) ${pos.latitude}, ${pos.longitude}');
      return;
    }

    locationPoints++;
    final String stamp = DateTime.now().toIso8601String();
    await _log('📍 #$locationPoints | $stamp | '
        'lat=${pos.latitude}, lng=${pos.longitude}, '
        'acc=${pos.accuracy.toStringAsFixed(1)}m, '
        'speed=${pos.speed.toStringAsFixed(1)}m/s');

    // إرسال الموقع للسيرفر (أفضل جهد) — يُتخطّى للجلسات الوهمية أو عند فشل الاتصال،
    // مع بقاء البيانات محفوظة في السجل المحلي للتأكد من التقاطها.
    if (sosId! > 0 && token != null) {
      try {
        final res = await http
            .post(
              Uri.parse('${ApiConfig.sosBaseUrl}/$sosId/location'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                'latitude': pos.latitude,
                'longitude': pos.longitude,
              }),
            )
            .timeout(const Duration(seconds: 8));
        await _log('📤 location uploaded (${res.statusCode})');
      } catch (e) {
        await _log('⚠️ location upload failed (kept in local log): $e');
      }
    }
  });

  // إيقاف الخدمة: إيقاف المؤقّت ورفع آخر مقطع ثم تنظيف الموارد.
  service.on('stopService').listen((event) async {
    await _log('🛑 STOP | captured $locationPoints location point(s)');

    audioEnabled = false;
    chunkTimer?.cancel();
    await locationSub?.cancel();

    // إنهاء/رفع آخر مقطع صوتي دون إعادة تشغيل.
    await processChunk(restart: false);

    // رفع السجل الخلفي الملتقط إلى السيرفر (أفضل جهد) للجلسات الحقيقية فقط.
    if (sosId != null && sosId! > 0 && token != null) {
      await uploadBackgroundLog(sosId!, token!);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kSosActiveKey, false);

    await audioRecorder.dispose();
    service.stopSelf();
  });

  // إطلاق حلقة المراقبة المستمرة قبل الـ SOS — تستمع للخطر بينما التطبيق في
  // الخلفية وتطلق الـ SOS تلقائياً عند التأكيد. لا ننتظرها (حلقة لا نهائية).
  unawaited(preSosMonitorLoop());
}

/// Best-effort upload of the captured background log to the backend so the
/// values logged by the isolate can be inspected remotely.
///
/// NOTE: assumes a `POST $sosBaseUrl/$sosId/log` endpoint accepting
/// `{ "entries": [ "<line>", ... ] }`. Adjust the path/shape to match your API.
Future<void> uploadBackgroundLog(int sosId, String token) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final List<String> entries = prefs.getStringList(kSosBgLogKey) ?? <String>[];
    if (entries.isEmpty) {
      await _log('📋 background log empty; nothing to upload.');
      return;
    }

    final res = await http
        .post(
          Uri.parse('${ApiConfig.sosBaseUrl}/$sosId/log'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'entries': entries}),
        )
        .timeout(const Duration(seconds: 15));
    await _log('📋 background log uploaded '
        '(${res.statusCode}, ${entries.length} entries)');
  } catch (e) {
    await _log('⚠️ background log upload failed (kept locally): $e');
  }
}

/// Unified background logger.
///
/// Writes every captured value to BOTH:
///  * logcat (`debugPrint`) for live debugging while attached, and
///  * a rolling on-device log in SharedPreferences (`kSosBgLogKey`) so the
///    same values survive app restarts and can be reviewed from the in-app
///    log screen with no debugger attached.
Future<void> _log(String message) async {
  debugPrint('[BG-SOS] $message');
  try {
    final prefs = await SharedPreferences.getInstance();
    final List<String> log = prefs.getStringList(kSosBgLogKey) ?? <String>[];
    log.add('${DateTime.now().toIso8601String()} | $message');
    // الاحتفاظ بآخر N سطر فقط لتجنّب تضخّم التخزين.
    if (log.length > _kSosLogMaxEntries) {
      log.removeRange(0, log.length - _kSosLogMaxEntries);
    }
    await prefs.setStringList(kSosBgLogKey, log);
  } catch (_) {
    // التسجيل تشخيصي فقط — يُتجاهل أي فشل بصمت حتى لا يُعطّل تدفق الـ SOS.
  }
}
