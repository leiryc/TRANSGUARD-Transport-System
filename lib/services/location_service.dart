import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as geo;

class LocationAccessException implements Exception {
  final String message;
  final bool openLocationSettings;
  final bool openAppSettings;

  const LocationAccessException(
    this.message, {
    this.openLocationSettings = false,
    this.openAppSettings = false,
  });

  @override
  String toString() => message;
}

class LocationService {
  static const double serviceAreaCenterLatitude = 8.5050281;
  static const double serviceAreaCenterLongitude = 125.9771179;
  static const double serviceAreaRadiusMeters = 5000;

  final geo.Geocoding _geocoding = geo.Geocoding();

  bool isWithinPickupServiceArea(double latitude, double longitude) {
    final distanceMeters = Geolocator.distanceBetween(
      serviceAreaCenterLatitude,
      serviceAreaCenterLongitude,
      latitude,
      longitude,
    );
    return distanceMeters <= serviceAreaRadiusMeters;
  }

  String? detectSuspiciousDriverPosition(
    Position position, {
    Position? previousPosition,
  }) {
    if (position.isMocked) {
      return 'The platform marked the GPS fix as mocked.';
    }
    if (!position.latitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        !position.longitude.isFinite ||
        position.longitude < -180 ||
        position.longitude > 180) {
      return 'The GPS fix contains invalid coordinates.';
    }
    if (!position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > 1000) {
      return 'The GPS fix has invalid or insufficient accuracy.';
    }
    final age = DateTime.now().difference(position.timestamp);
    if (age < const Duration(seconds: -30) ||
        age > const Duration(minutes: 2)) {
      return 'The GPS fix timestamp is outside the accepted freshness window.';
    }
    if (position.speed.isFinite && position.speed > 55) {
      return 'The reported GPS speed exceeded 55 m/s.';
    }

    if (previousPosition != null) {
      final elapsed = position.timestamp
          .difference(previousPosition.timestamp)
          .inMilliseconds;
      if (elapsed > 0) {
        final distance = Geolocator.distanceBetween(
          previousPosition.latitude,
          previousPosition.longitude,
          position.latitude,
          position.longitude,
        );
        final minimumDistance =
            (distance - previousPosition.accuracy - position.accuracy).clamp(
              0.0,
              double.infinity,
            );
        final minimumSpeed = minimumDistance / (elapsed / 1000);
        if (minimumSpeed > 55) {
          return 'Consecutive GPS fixes imply travel above 55 m/s.';
        }
      }
    }
    return null;
  }

  Future<void> ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationAccessException(
        'Turn on location services to share your live location.',
        openLocationSettings: true,
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationAccessException(
        'Location access is blocked. Enable it for TRANSGUARD in app settings.',
        openAppSettings: true,
      );
    }
    if (permission == LocationPermission.denied) {
      throw const LocationAccessException(
        'Allow location access to share your live location.',
      );
    }
  }

  Future<Position> getRequiredCurrentLocation() async {
    await ensureLocationPermission();
    Position? lastKnownPosition;
    try {
      lastKnownPosition = await Geolocator.getLastKnownPosition().timeout(
        const Duration(seconds: 2),
      );
    } on TimeoutException {
      debugPrint('Timed out checking the cached device location.');
    }

    if (_isRecentUsablePosition(lastKnownPosition)) {
      return lastKnownPosition!;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      ).timeout(const Duration(seconds: 10));
      if (position.accuracy > 1000) {
        throw LocationAccessException(
          'Your location was found, but its accuracy is too low '
          '(${position.accuracy.round()} m). TransGuard requires a fix within '
          '1,000 m. Turn on precise location and try outdoors.',
        );
      }
      return position;
    } on TimeoutException {
      if (_isRecentUsablePosition(lastKnownPosition)) {
        return lastKnownPosition!;
      }
      throw TimeoutException(
        'No usable GPS fix was available. Turn on Location and try again '
        'near a window or outdoors.',
        const Duration(seconds: 10),
      );
    }
  }

  bool _isRecentUsablePosition(Position? position) {
    if (position == null || position.accuracy > 1000) return false;
    final age = DateTime.now().difference(position.timestamp);
    return !age.isNegative && age <= const Duration(minutes: 2);
  }

  Stream<Position> getLocationUpdates() async* {
    await ensureLocationPermission();
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    );
  }

  Future<bool> requestLocationPermission() async {
    final status = await Geolocator.requestPermission();
    return status == LocationPermission.always ||
        status == LocationPermission.whileInUse;
  }

  Future<Position?> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (e) {
      debugPrint('Get Location Error: $e');
      return null;
    }
  }

  Future<String?> getAddressFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    try {
      final placemarks = await _geocoding.placemarkFromCoordinates(
        latitude,
        longitude,
      );
      if (placemarks.isNotEmpty) {
        final place = placemarks[0];
        return '${place.street}, ${place.locality}, ${place.administrativeArea}';
      }
    } catch (e) {
      debugPrint('Get Address Error: $e');
    }
    return null;
  }

  Future<geo.Location?> getCoordinatesFromAddress(String address) async {
    try {
      final locations = await _geocoding.locationFromAddress(address);
      if (locations.isNotEmpty) {
        return locations[0];
      }
    } catch (e) {
      debugPrint('Get Coordinates Error: $e');
    }
    return null;
  }

  double calculateDistance(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    return Geolocator.distanceBetween(startLat, startLng, endLat, endLng) /
        1000; // in km
  }
}
