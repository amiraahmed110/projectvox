import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
import 'emergency_screen.dart';
import 'ai_monitor.dart';
import '../fake_call/fake_call_screen.dart';
import '../map/map_screen.dart';
import '../profile/profile_screen.dart';
import '../reports/create_report_screen.dart';
import '../safety/trusted_contacts_screen.dart' show TrustedContactsScreen;
import '../voice_password/voice_password_intro_screen.dart';
import '../profile/settings_screen.dart';
import '../safety/start_trip_screen.dart';

/// What the foreground AI monitor is currently doing. Drives the status card.
enum _MonitorStatus {
  /// AI auto-mode is off, paused (safe zone / SOS active / app backgrounded),
  /// or simply between cycles.
  idle,

  /// Stage 1 — recording a short window and screening it for danger keywords.
  listening,

  /// Stage 2 — a keyword was hit; recording the 2-minute clip and running the
  /// emotion model.
  analyzing,

  /// A danger was confirmed (or the user pressed SOS) and an alert is running.
  alert,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _selectedIndex = 0;
  late AnimationController _waveController;
  final AudioRecorder _audioRecorder = AudioRecorder();

  // Location.
  LatLng _currentLatLng = const LatLng(30.0444, 31.2357);
  String _locationText = "Locating...";
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionSub;
  LatLng? _lastGeocoded;

  // AI monitor state.
  _MonitorStatus _status = _MonitorStatus.idle;
  bool _aiAutoMode = true; // mirror of the Settings toggle, for the UI
  bool _inSafeZone = false; // whether we're currently inside a safe zone
  bool _loopActive = false; // monitor should keep cycling
  bool _loopBusy = false; // a monitor loop is currently running (re-entrancy guard)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setAppForeground(true);
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _initLocation();
    _startMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setAppForeground(false);
    _loopActive = false;
    _positionSub?.cancel();
    _audioRecorder.dispose();
    _waveController.dispose();
    super.dispose();
  }

  // The foreground monitor must not hold the mic while the app is backgrounded
  // (the background SOS service handles that case). Pause on background, resume
  // on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App is back in front: reclaim the mic from the background monitor.
      _setAppForeground(true);
      _startMonitor();
    } else if (state == AppLifecycleState.paused) {
      // Truly backgrounded: release the mic and let the background isolate's
      // pre-SOS monitor take over listening for danger.
      _setAppForeground(false);
      _stopMonitor();
    } else if (state == AppLifecycleState.inactive) {
      // Transient (system dialog / transition): release the mic but DON'T hand
      // it to the background isolate — we're still in the foreground.
      _stopMonitor();
    }
  }

  /// Tells the background isolate whether the app is in the foreground so its
  /// pre-SOS danger monitor only grabs the mic while the app is closed. See
  /// [kAppForegroundKey].
  Future<void> _setAppForeground(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAppForegroundKey, value);
  }

  // ---------------------------------------------------------------------------
  // AI auto-detection — two-stage pipeline
  // ---------------------------------------------------------------------------

  /// Starts (or resumes) the monitor loop if one isn't already running.
  void _startMonitor() {
    _loopActive = true;
    if (!_loopBusy) _monitorLoop();
  }

  /// Stops the loop and releases the mic.
  Future<void> _stopMonitor() async {
    _loopActive = false;
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
    _setStatus(_MonitorStatus.idle);
  }

  /// The continuous monitoring loop. Per the brief it is intentionally
  /// two-stage: a cheap keyword screen runs constantly, and the heavy emotion
  /// model only runs after a keyword hit.
  Future<void> _monitorLoop() async {
    if (_loopBusy) return;
    _loopBusy = true;
    try {
      while (mounted && _loopActive) {
        if (await _shouldPauseAi()) {
          _setStatus(_MonitorStatus.idle);
          if (await _audioRecorder.isRecording()) {
            await _audioRecorder.stop();
          }
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        // Stage 1 — listen in a short window, screen for danger keywords.
        _setStatus(_MonitorStatus.listening);
        final String? listenClip = await _recordClip(kListenWindow);
        if (listenClip == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        final bool danger =
            await screenForDanger(listenClip, locationText: _locationText);
        await _deleteQuietly(listenClip);
        if (!danger || !mounted || !_loopActive) continue;

        // Danger keyword hit. If emotion detection is off, fire immediately.
        final prefs = await SharedPreferences.getInstance();
        final bool emotionEnabled = prefs.getBool(kEmotionDetectionKey) ?? true;
        if (!emotionEnabled) {
          await _onDangerConfirmed();
          continue;
        }

        // Stage 2 — record the 2-minute evidence clip and run the emotion
        // model, the final decision-maker. Store the clip as evidence too.
        _setStatus(_MonitorStatus.analyzing);
        final String? evidence = await _recordClip(kAiChunkDuration);
        if (evidence == null) continue;
        await uploadRecordingToBackend(evidence);
        final bool confirmed = await confirmEmotion(evidence);
        await _deleteQuietly(evidence);

        if (confirmed) {
          await _onDangerConfirmed();
        } else {
          // Not confirmed → discard and return to listening.
          _setStatus(_MonitorStatus.idle);
        }
      }
    } finally {
      _loopBusy = false;
      if (mounted && _status != _MonitorStatus.alert) {
        _setStatus(_MonitorStatus.idle);
      }
    }
  }

  /// True when the AI pipeline should not run right now: not on the home tab,
  /// an SOS already active (the background service owns the mic), the master
  /// AI toggle off, or the user is inside a safe zone.
  Future<bool> _shouldPauseAi() async {
    if (_selectedIndex != 0) return true;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kSosActiveKey) ?? false) return true;

    final bool aiOn = prefs.getBool(kAiAutoModeKey) ?? true;
    if (aiOn != _aiAutoMode && mounted) {
      setState(() => _aiAutoMode = aiOn);
    }
    if (!aiOn) return true;

    final bool inZone =
        await isInsideSafeZone(_currentLatLng.latitude, _currentLatLng.longitude);
    if (inZone != _inSafeZone && mounted) {
      setState(() => _inSafeZone = inZone);
    }
    return inZone;
  }

  /// Records a clip of [duration] to a temp file, bailing out early if the
  /// monitor gets paused/stopped mid-recording. Returns the path or null.
  Future<String?> _recordClip(Duration duration) async {
    try {
      if (!await _audioRecorder.hasPermission()) return null;

      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/aiclip_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      final sw = Stopwatch()..start();
      while (sw.elapsed < duration) {
        if (!mounted || !_loopActive) break;
        await Future.delayed(const Duration(milliseconds: 300));
      }

      if (!await _audioRecorder.isRecording()) return null;
      return await _audioRecorder.stop();
    } catch (e) {
      debugPrint('[HOME] record clip error: $e');
      try {
        if (await _audioRecorder.isRecording()) await _audioRecorder.stop();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}
  }

  /// A danger was confirmed by the AI — open the active-alert flow (same
  /// outcome as a manual SOS).
  Future<void> _onDangerConfirmed() async {
    _setStatus(_MonitorStatus.alert);
    await _openActiveAlert();
  }

  // ---------------------------------------------------------------------------
  // Manual SOS / active alert
  // ---------------------------------------------------------------------------

  /// Opens the [EmergencyScreen] grace flow (3-second cancel countdown → start
  /// background guard: live location + recording → SafeHomeScreen). Pauses the
  /// foreground monitor so it doesn't fight the SOS service for the mic, then
  /// resumes when the alert screen is dismissed.
  Future<void> _openActiveAlert() async {
    _loopActive = false;
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EmergencyScreen()),
    );

    if (!mounted) return;
    // Resume monitoring. If the previous loop already exited (manual entry),
    // start a fresh one; if we're still nested inside it, it resumes itself.
    _setStatus(_MonitorStatus.idle);
    _startMonitor();
  }

  void _setStatus(_MonitorStatus status) {
    if (!mounted || _status == status) return;
    setState(() => _status = status);
  }

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  Future<void> _initLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    try {
      final Position position = await Geolocator.getCurrentPosition();
      _onPosition(position, animate: true, forceGeocode: true);
    } catch (_) {/* will be covered by the stream */}

    // Continuous (live) location updates keep the map, the safe-zone check and
    // the shareable location fresh.
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20,
      ),
    ).listen((pos) => _onPosition(pos));
  }

  void _onPosition(Position position,
      {bool animate = false, bool forceGeocode = false}) {
    final latLng = LatLng(position.latitude, position.longitude);
    if (mounted) setState(() => _currentLatLng = latLng);

    if (animate) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
    }

    // Reverse-geocode sparingly (only initially or after moving ~150m) to keep
    // within the Nominatim usage policy.
    final bool movedFar = _lastGeocoded == null ||
        Geolocator.distanceBetween(
              _lastGeocoded!.latitude,
              _lastGeocoded!.longitude,
              latLng.latitude,
              latLng.longitude,
            ) >
            150;
    if (forceGeocode || movedFar) {
      _lastGeocoded = latLng;
      _getAddressFromLatLng(latLng.latitude, latLng.longitude);
    }
  }

  Future<void> _getAddressFromLatLng(double lat, double lon) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=18&addressdetails=1');
    try {
      final response = await http
          .get(url, headers: {'User-Agent': 'voxGuard', 'Accept-Language': 'en'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        String displayName = data['display_name'] ?? "Unknown Location";
        List<String> parts = displayName.split(',');
        if (mounted) {
          setState(() => _locationText =
              parts.length > 2 ? "${parts[0]}, ${parts[1]}" : displayName);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _locationText = "${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}");
      }
    }
  }

  Future<Map<String, String>> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? "User",
      'image': prefs.getString('user_image') ?? "",
    };
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  void _onTabSelected(int index) {
    setState(() => _selectedIndex = index);
    // Leaving/returning to Home pauses/resumes monitoring via _shouldPauseAi;
    // make sure a loop is alive to react.
    if (index == 0) _startMonitor();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      _buildHomeContent(),
      const TrustedContactsScreen(),
      const CreateReportScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFF8E9EFE), Color(0xFFD546F3)])),
        child: _selectedIndex == 0 ? _buildHomeContent() : pages[_selectedIndex],
      ),
      bottomNavigationBar: _bottomNav(),
    );
  }

  Widget _buildHomeContent() {
    return Column(
      children: [
        const SizedBox(height: 40),
        _header(),
        const SizedBox(height: 30),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30), topRight: Radius.circular(30))),
            padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 25),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 5),
                _sos(),
                const SizedBox(height: 25),
                _quickActions(),
                const SizedBox(height: 30),
                _safetyStatusCard(),
                const SizedBox(height: 25),
                _locationCard(),
                const SizedBox(height: 90),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: FutureBuilder<Map<String, String>>(
        future: _loadUserData(),
        builder: (context, snapshot) {
          String userName = snapshot.data?['name'] ?? "User";
          String imageUrl = snapshot.data?['image'] ?? "";
          return Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.white24,
                backgroundImage: imageUrl.isNotEmpty
                    ? NetworkImage(imageUrl)
                    : const AssetImage('images/person.png') as ImageProvider,
              ),
              const SizedBox(width: 12),
              Text('Hi, $userName',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (context) => const ProfileScreen())),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5)),
                  child: const Icon(Icons.person_outline,
                      color: Colors.white, size: 22),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sos() {
    return Center(
      child: SizedBox(
        height: 220,
        width: 220,
        child: AnimatedBuilder(
          animation: _waveController,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                _buildWave(0.0),
                _buildWave(0.33),
                _buildWave(0.66),
                GestureDetector(
                  onTap: _openActiveAlert,
                  child: Container(
                    height: 110,
                    width: 110,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Color(0xFFD32F2F)),
                    child: const Center(
                        child: Text('SOS',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.bold))),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildWave(double delay) {
    double progress = (_waveController.value + delay) % 1;
    double size = 110 + (progress * 120);
    double opacity = (1 - progress).clamp(0.0, 1.0);
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFE53935).withOpacity(0.3 * opacity)),
    );
  }

  Widget _quickActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _actionItem(
              'call.png',
              'Fake call',
              () => Navigator.push(context,
                  MaterialPageRoute(builder: (context) => const FakeCallScreen()))),
          _actionItem(
              'location.png',
              'Start Trip',
              () => Navigator.push(context,
                  MaterialPageRoute(builder: (context) => const StartTripScreen()))),
          _actionItem(
              'mic.png',
              'Voice password',
              () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const VoicePasswordIntroScreen()))),
        ],
      ),
    );
  }

  Widget _actionItem(String imageName, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: CornerBorderPainter(),
        child: Container(
          height: 95,
          width: 95,
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('images/$imageName', width: 38, height: 38),
              const SizedBox(height: 8),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.grey,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  /// Live status card: reflects the real monitor state and the AI-mode /
  /// safe-zone flags instead of a hard-coded "You Are Safe".
  Widget _safetyStatusCard() {
    final ({String label, Color color, IconData icon}) info = switch (_status) {
      _MonitorStatus.alert => (
          label: 'Alert active',
          color: const Color(0xFFD32F2F),
          icon: Icons.warning_amber_rounded
        ),
      _MonitorStatus.analyzing => (
          label: 'Analyzing audio…',
          color: const Color(0xFFF59E0B),
          icon: Icons.graphic_eq
        ),
      _MonitorStatus.listening => (
          label: 'Listening for danger',
          color: const Color(0xFF2563EB),
          icon: Icons.hearing
        ),
      _MonitorStatus.idle => _inSafeZone
          ? (
              label: 'In safe zone — AI paused',
              color: const Color(0xFF4CAF50),
              icon: Icons.shield_outlined
            )
          : !_aiAutoMode
              ? (
                  label: 'AI auto mode off',
                  color: Colors.grey,
                  icon: Icons.pause_circle_outline
                )
              : (
                  label: 'You Are Safe',
                  color: const Color(0xFF4CAF50),
                  icon: Icons.check_circle_outline
                ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 15,
                  offset: const Offset(0, 5))
            ]),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Today's Safety Status",
                    style: TextStyle(fontSize: 17)),
                _aiModeChip(),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(info.icon, color: info.color, size: 16),
                const SizedBox(width: 10),
                Text(info.label,
                    style: TextStyle(
                        color: info.color,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _aiModeChip() {
    final bool on = _aiAutoMode;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (on ? const Color(0xFFCB30E0) : Colors.grey).withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(on ? Icons.auto_awesome : Icons.do_not_disturb_on_outlined,
              size: 13, color: on ? const Color(0xFFCB30E0) : Colors.grey),
          const SizedBox(width: 5),
          Text('AI ${on ? 'On' : 'Off'}',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: on ? const Color(0xFFCB30E0) : Colors.grey)),
        ],
      ),
    );
  }

  Widget _locationCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (context) => const FullMapScreen())),
        child: Container(
          height: 200,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(26), boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 20,
                offset: const Offset(0, 8))
          ]),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: GoogleMap(
                    initialCameraPosition:
                        CameraPosition(target: _currentLatLng, zoom: 15),
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                    onMapCreated: (c) => _mapController = c),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18)),
                  child: Row(
                    children: [
                      const Icon(Icons.location_on_outlined,
                          color: Colors.blue, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(_locationText,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomNav() {
    return Container(
      height: 70,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)
      ]),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _bottomItem(Icons.home_rounded, "Home", 0),
          _bottomItem(Icons.account_circle_outlined, "Contacts", 1),
          _bottomItem(Icons.file_copy_sharp, "Reports", 2),
          _bottomItem(Icons.settings_rounded, "Settings", 3),
        ],
      ),
    );
  }

  Widget _bottomItem(IconData icon, String label, int index) {
    bool isSelected = _selectedIndex == index;
    return InkWell(
      onTap: () => _onTabSelected(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFCB30E0) : Colors.transparent,
            borderRadius: BorderRadius.circular(30)),
        child: Row(
          children: [
            Icon(icon,
                size: 22, color: isSelected ? Colors.white : Colors.grey.shade400),
            if (isSelected) ...[
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12))
            ],
          ],
        ),
      ),
    );
  }
}

class CornerBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCB30E0).withOpacity(0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    double c = 12;
    canvas.drawPath(
        ui.Path()
          ..moveTo(0, c)
          ..lineTo(0, 0)
          ..lineTo(c, 0),
        paint);
    canvas.drawPath(
        ui.Path()
          ..moveTo(size.width - c, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width, c),
        paint);
    canvas.drawPath(
        ui.Path()
          ..moveTo(0, size.height - c)
          ..lineTo(0, size.height)
          ..lineTo(c, size.height),
        paint);
    canvas.drawPath(
        ui.Path()
          ..moveTo(size.width - c, size.height)
          ..lineTo(size.width, size.height)
          ..lineTo(size.width, size.height - c),
        paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
