import 'package:geolocator/geolocator.dart';

/// Wraps the device location stream and builds shareable map links.
///
/// We use [Geolocator.getPositionStream] — geolocator's equivalent of the
/// `onLocationChanged` callback found in other packages — so the module keeps
/// a *live* view of the user's position while an SOS is active. The link sent
/// to contacts is a Google Maps pin built from the latest position.
class LocationService {
  const LocationService();

  /// Default streaming settings: high accuracy, emit when moved >= 10 m.
  static const LocationSettings _settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10,
  );

  /// Live position stream (the "onLocationChanged" equivalent in geolocator).
  /// Subscribe while the SOS is active; cancel on Safe.
  Stream<Position> watch() =>
      Geolocator.getPositionStream(locationSettings: _settings);

  /// Best-effort single fix used to seed the first message: a fresh
  /// high-accuracy position, falling back to the last known one, else null
  /// (e.g. permission denied or location services off).
  Future<Position?> currentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  /// A universal Google Maps "search" link that drops a pin at [position].
  /// Opens in the Maps app or any browser.
  String buildMapsLink(Position position) =>
      'https://www.google.com/maps/search/?api=1'
      '&query=${position.latitude},${position.longitude}';
}
