import 'location_service.dart';

class PaymentService {
  static const double baseFarePhp = 15;
  static const double perKilometerPhp = 8;
  static const double flatFareRadiusKm = 1;
  static const int cooperativeSharePercent = 30;
  static const double cooperativeShareRate = 0.30;
  static const String fareAllocationPolicyVersion =
      'cooperative_30_driver_70_v1';
  static const String flatFareBasis =
      'base15_flat_inside_1km_plus8_per_km_outside_v1';
  static const String flatFareCalculationVersion =
      'php_base15_flat_inside_1km_plus8_route_km_outside_v2';
  static const String legacyFareBasis = 'base_plus_distance';
  static const String legacyFareCalculationVersion = 'php_base15_per_km8_v1';

  bool isWithinFlatFareZone({
    required double pickupLatitude,
    required double pickupLongitude,
    required double dropoffLatitude,
    required double dropoffLongitude,
  }) {
    double approximateDistanceKm(double latitude, double longitude) {
      final northSouthKm =
          (latitude - LocationService.serviceAreaCenterLatitude) * 110.62;
      final eastWestKm =
          (longitude - LocationService.serviceAreaCenterLongitude) * 110.29;
      return northSouthKm * northSouthKm + eastWestKm * eastWestKm;
    }

    final radiusSquared = flatFareRadiusKm * flatFareRadiusKm;
    return approximateDistanceKm(pickupLatitude, pickupLongitude) <=
            radiusSquared &&
        approximateDistanceKm(dropoffLatitude, dropoffLongitude) <=
            radiusSquared;
  }

  double calculateRidePrice(
    double distanceKm, {
    required double pickupLatitude,
    required double pickupLongitude,
    required double dropoffLatitude,
    required double dropoffLongitude,
  }) {
    if (!distanceKm.isFinite || distanceKm < 0) {
      throw ArgumentError.value(distanceKm, 'distanceKm');
    }
    final fare =
        isWithinFlatFareZone(
          pickupLatitude: pickupLatitude,
          pickupLongitude: pickupLongitude,
          dropoffLatitude: dropoffLatitude,
          dropoffLongitude: dropoffLongitude,
        )
        ? baseFarePhp
        : baseFarePhp + perKilometerPhp * distanceKm;
    return fare.roundToDouble();
  }

  double calculateCooperativeShare(double farePhp) =>
      farePhp * cooperativeShareRate;

  double calculateDriverAllocation(double farePhp) =>
      farePhp - calculateCooperativeShare(farePhp);

  // Calculate estimated time (in minutes)
  double calculateEstimatedTime(double distanceKm) {
    // Average speed: 30 km/h in city
    const double averageSpeed = 30;
    return (distanceKm / averageSpeed) * 60;
  }

  // Format price for display
  String formatPrice(double price) {
    return '₱${price.round()}';
  }
}
