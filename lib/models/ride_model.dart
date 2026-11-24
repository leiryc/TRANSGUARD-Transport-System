import 'package:cloud_firestore/cloud_firestore.dart';

class RideModel {
  final String id;
  final String passengerId;
  final String? driverId;
  final String? driverName;
  final String pickupLocation;
  final String dropoffLocation;
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;
  final double estimatedPrice;
  final double? finalPrice;
  final String currency;
  final String
  status; // 'requested', 'accepted', 'in_progress', 'completed', 'cancelled'
  final DateTime createdAt;
  final DateTime? startTime;
  final DateTime? endTime;
  final double? passengerRating;
  final double? driverRating;
  final String? passengerReview;
  final String? driverReview;
  final double? distance;
  final double? duration;
  final double? driverLat;
  final double? driverLng;
  final DateTime? driverLocationUpdatedAt;
  final DateTime? qrValidatedAt;
  final String? paymentMethod;
  final bool cashCollectedByDriver;
  // Snapshot of the passenger's ID verification when the ride was requested.
  // Firestore rules only accept true if the passenger's ID is verified.
  final bool passengerIdVerified;
  // How the fare and distance were calculated, e.g. the current road-route
  // basis or the legacy straight-line 'base_plus_distance'. Null on very old
  // rides, which predate road routing.
  final String? fareBasis;
  final bool isFromCache;

  RideModel({
    required this.id,
    required this.passengerId,
    this.driverId,
    this.driverName,
    required this.pickupLocation,
    required this.dropoffLocation,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.estimatedPrice,
    this.finalPrice,
    this.currency = 'PHP',
    this.status = 'requested',
    required this.createdAt,
    this.startTime,
    this.endTime,
    this.passengerRating,
    this.driverRating,
    this.passengerReview,
    this.driverReview,
    this.distance,
    this.duration,
    this.driverLat,
    this.driverLng,
    this.driverLocationUpdatedAt,
    this.qrValidatedAt,
    this.paymentMethod,
    this.cashCollectedByDriver = false,
    this.passengerIdVerified = false,
    this.fareBasis,
    this.isFromCache = false,
  });

  factory RideModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return RideModel(
      id: doc.id,
      passengerId: data['passengerId'] ?? '',
      driverId: data['driverId'],
      driverName: data['driverName'] as String?,
      pickupLocation: data['pickupLocation'] ?? '',
      dropoffLocation: data['dropoffLocation'] ?? '',
      pickupLat: (data['pickupLat'] ?? 0.0).toDouble(),
      pickupLng: (data['pickupLng'] ?? 0.0).toDouble(),
      dropoffLat: (data['dropoffLat'] ?? 0.0).toDouble(),
      dropoffLng: (data['dropoffLng'] ?? 0.0).toDouble(),
      estimatedPrice: (data['estimatedPrice'] ?? 0.0).toDouble(),
      finalPrice: data['finalPrice']?.toDouble(),
      currency: data['currency'] ?? 'PHP',
      status: data['status'] ?? 'requested',
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      startTime: data['startTime'] != null
          ? (data['startTime'] as Timestamp).toDate()
          : null,
      endTime: data['endTime'] != null
          ? (data['endTime'] as Timestamp).toDate()
          : null,
      passengerRating: data['passengerRating']?.toDouble(),
      driverRating: data['driverRating']?.toDouble(),
      passengerReview: data['passengerReview'],
      driverReview: data['driverReview'],
      distance: data['distance']?.toDouble(),
      duration: data['duration']?.toDouble(),
      driverLat: data['driverLocation'] is GeoPoint
          ? (data['driverLocation'] as GeoPoint).latitude
          : null,
      driverLng: data['driverLocation'] is GeoPoint
          ? (data['driverLocation'] as GeoPoint).longitude
          : null,
      driverLocationUpdatedAt: data['driverLocationUpdatedAt'] is Timestamp
          ? (data['driverLocationUpdatedAt'] as Timestamp).toDate()
          : null,
      qrValidatedAt: data['qrValidatedAt'] is Timestamp
          ? (data['qrValidatedAt'] as Timestamp).toDate()
          : null,
      paymentMethod: data['paymentMethod'] as String?,
      cashCollectedByDriver: data['cashCollectedByDriver'] == true,
      passengerIdVerified: data['passengerIdVerified'] == true,
      fareBasis: data['fareBasis'] as String?,
      isFromCache: doc.metadata.isFromCache,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'passengerId': passengerId,
      'driverId': driverId,
      if (driverName != null) 'driverName': driverName,
      'pickupLocation': pickupLocation,
      'dropoffLocation': dropoffLocation,
      'pickupLat': pickupLat,
      'pickupLng': pickupLng,
      'dropoffLat': dropoffLat,
      'dropoffLng': dropoffLng,
      'estimatedPrice': estimatedPrice,
      'finalPrice': finalPrice,
      'currency': currency,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
      'startTime': startTime != null ? Timestamp.fromDate(startTime!) : null,
      'endTime': endTime != null ? Timestamp.fromDate(endTime!) : null,
      'passengerRating': passengerRating,
      'driverRating': driverRating,
      'passengerReview': passengerReview,
      'driverReview': driverReview,
      'distance': distance,
      'duration': duration,
      'qrValidatedAt': qrValidatedAt != null
          ? Timestamp.fromDate(qrValidatedAt!)
          : null,
      'paymentMethod': paymentMethod,
      'cashCollectedByDriver': cashCollectedByDriver,
      'passengerIdVerified': passengerIdVerified,
    };
  }
}
