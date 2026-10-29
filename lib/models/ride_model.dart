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
  final String rideType; // 'economy', 'comfort', 'premium'
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
    this.rideType = 'economy',
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
      rideType: data['rideType'] ?? 'economy',
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
      'rideType': rideType,
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
    };
  }
}
