import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_app/services/location_service.dart';
import 'package:ride_hailing_app/services/payment_service.dart';

void main() {
  final paymentService = PaymentService();
  const centerLatitude = LocationService.serviceAreaCenterLatitude;
  const centerLongitude = LocationService.serviceAreaCenterLongitude;

  test('charges a flat PHP 15 when both stops are inside the 1 km zone', () {
    final fare = paymentService.calculateRidePrice(
      12,
      pickupLatitude: centerLatitude + 0.002,
      pickupLongitude: centerLongitude,
      dropoffLatitude: centerLatitude - 0.006,
      dropoffLongitude: centerLongitude,
    );

    expect(fare, 15);
  });

  test(
    'charges PHP 15 plus PHP 8 per road km if a stop is outside the zone',
    () {
      final fare = paymentService.calculateRidePrice(
        2.5,
        pickupLatitude: centerLatitude,
        pickupLongitude: centerLongitude,
        dropoffLatitude: centerLatitude + 0.02,
        dropoffLongitude: centerLongitude,
      );

      expect(fare, 35);
    },
  );

  test('rounds distance fares to whole pesos', () {
    final fare = paymentService.calculateRidePrice(
      1.234,
      pickupLatitude: centerLatitude + 0.02,
      pickupLongitude: centerLongitude,
      dropoffLatitude: centerLatitude + 0.03,
      dropoffLongitude: centerLongitude,
    );

    expect(fare, 25);
  });

  test('formats fares without centavos', () {
    expect(paymentService.formatPrice(15.07), '₱15');
  });
}
