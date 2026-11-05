import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/ride_model.dart';
import 'payment_service.dart';
import 'security_audit_service.dart';

class RideService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<RideModel?> requestRide(RideModel ride) async {
    final passengerId = FirebaseAuth.instance.currentUser?.uid;
    if (passengerId == null || passengerId != ride.passengerId) {
      throw StateError('Sign in as the passenger requesting this ride.');
    }

    final rideRef = _firestore.collection('rides').doc();
    final activeRideRef = _firestore
        .collection('passenger_active')
        .doc(passengerId);
    await _clearStalePassengerRide(activeRideRef);
    final distanceKm =
        ride.distance ??
        _distanceKm(
          ride.pickupLat,
          ride.pickupLng,
          ride.dropoffLat,
          ride.dropoffLng,
        );
    final paymentService = PaymentService();
    final estimatedFare = paymentService.calculateRidePrice(
      distanceKm,
      pickupLatitude: ride.pickupLat,
      pickupLongitude: ride.pickupLng,
      dropoffLatitude: ride.dropoffLat,
      dropoffLongitude: ride.dropoffLng,
    );

    await _firestore.runTransaction((transaction) async {
      final activeRide = await transaction.get(activeRideRef);
      if (activeRide.exists) {
        throw StateError('You already have an active ride.');
      }
      transaction.set(rideRef, {
        'passengerId': passengerId,
        'driverId': null,
        'pickupLocation': ride.pickupLocation,
        'dropoffLocation': ride.dropoffLocation,
        'pickupLat': ride.pickupLat,
        'pickupLng': ride.pickupLng,
        'dropoffLat': ride.dropoffLat,
        'dropoffLng': ride.dropoffLng,
        'estimatedPrice': estimatedFare,
        'finalPrice': null,
        'currency': 'PHP',
        'fareBasis': PaymentService.flatFareBasis,
        'distance': distanceKm,
        'status': 'requested',
        'dispatchState': 'queued',
        'rideType': ride.rideType,
        'createdAt': FieldValue.serverTimestamp(),
        'passengerIdVerified': ride.passengerIdVerified,
      });
      transaction.set(activeRideRef, {'rideId': rideRef.id});
    });

    return getRideById(rideRef.id);
  }

  Future<void> _clearStalePassengerRide(
    DocumentReference<Map<String, dynamic>> activeRideRef,
  ) async {
    await _firestore.runTransaction((transaction) async {
      final activeRide = await transaction.get(activeRideRef);
      if (!activeRide.exists) return;

      final previousRideId = activeRide.data()?['rideId'];
      if (previousRideId is! String || previousRideId.isEmpty) {
        throw StateError(
          'Your active ride record is incomplete. Contact support to clear it.',
        );
      }

      final previousRideRef = _firestore
          .collection('rides')
          .doc(previousRideId);
      final previousRide = await transaction.get(previousRideRef);
      final previousStatus = previousRide.data()?['status'];
      if (previousRide.exists &&
          previousStatus != 'cancelled' &&
          previousStatus != 'completed') {
        throw StateError(
          'You already have a $previousStatus ride. Finish or cancel it '
          'before booking another.',
        );
      }

      transaction.delete(activeRideRef);
    });
  }

  Future<void> setDriverAvailability({
    required bool isOnline,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
  }) async {
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      throw StateError('Sign in as a driver before changing availability.');
    }

    final presenceRef = _firestore.collection('driver_presence').doc(driverId);
    if (!isOnline) {
      await presenceRef.set({
        'isOnline': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return;
    }
    if (latitude == null || longitude == null || accuracyMeters == null) {
      throw ArgumentError(
        'A current location and accuracy are required to go online.',
      );
    }
    if (!latitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        !longitude.isFinite ||
        longitude < -180 ||
        longitude > 180) {
      throw ArgumentError('The phone returned invalid location coordinates.');
    }
    if (!accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > 1000) {
      throw StateError(
        'Location accuracy is ${accuracyMeters.round()} m; it must be '
        '1,000 m or better. Turn on precise location and retry.',
      );
    }

    late final DocumentSnapshot<Map<String, dynamic>> user;
    try {
      user = await _firestore
          .collection('users')
          .doc(driverId)
          .get(const GetOptions(source: Source.server));
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        await SecurityAuditService().reportPermissionDenied(
          'reading driver account profile',
        );
        throw StateError(
          'Firestore denied reading your own user profile. Confirm this app '
          'is signed into the expected Firebase project and that its current '
          'rules allow users to read their own profile.',
        );
      }
      rethrow;
    }
    if (!user.exists) {
      throw StateError(
        'Your Firebase user profile is missing. Ask an administrator to '
        'restore your users profile.',
      );
    }
    if (user.data()?['userType'] != 'driver') {
      throw StateError(
        'This account is not marked as a driver in Firestore '
        '(userType must be exactly "driver").',
      );
    }

    var transactionStage = 'reading the driver presence record';
    var presenceExists = false;
    try {
      await _firestore.runTransaction((transaction) async {
        final presence = await transaction.get(presenceRef);
        presenceExists = presence.exists;
        final activeRideId = presence.data()?['activeRideId'];
        if (activeRideId != null) {
          throw StateError('Finish your assigned ride before going online.');
        }
        transactionStage = 'saving the driver presence update';
        transaction.set(presenceRef, {
          'isOnline': true,
          'location': GeoPoint(latitude, longitude),
          'locationAccuracyMeters': accuracyMeters,
          'updatedAt': FieldValue.serverTimestamp(),
          'activeRideId': null,
        }, SetOptions(merge: true));
      });
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        await SecurityAuditService().reportPermissionDenied(transactionStage);
        throw StateError(
          'Firestore denied $transactionStage. The presence record '
          '${presenceExists ? 'exists' : 'does not exist'}, the server profile '
          'is marked as driver, and GPS accuracy is '
          '${accuracyMeters.round()} m.',
        );
      }
      rethrow;
    }
  }

  Future<void> updateDriverPresence(
    double latitude,
    double longitude,
    double accuracyMeters,
  ) async {
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      throw StateError('Sign in as a driver before sharing your location.');
    }

    try {
      await _firestore.collection('driver_presence').doc(driverId).update({
        'location': GeoPoint(latitude, longitude),
        'locationAccuracyMeters': accuracyMeters,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        await SecurityAuditService().reportPermissionDenied(
          'updating driver presence',
        );
      }
      rethrow;
    }
  }

  // Driver accepts a ride
  Future<void> acceptRide(String rideId) async {
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      throw StateError('Sign in as a driver to accept a ride.');
    }

    final rideRef = _firestore.collection('rides').doc(rideId);
    final presenceRef = _firestore.collection('driver_presence').doc(driverId);
    final driverRef = _firestore.collection('users').doc(driverId);
    await _firestore.runTransaction((transaction) async {
      final rideSnapshot = await transaction.get(rideRef);
      final presenceSnapshot = await transaction.get(presenceRef);
      final driverSnapshot = await transaction.get(driverRef);
      if (!rideSnapshot.exists ||
          rideSnapshot.data()?['status'] != 'requested') {
        throw StateError('This ride is no longer available.');
      }
      if (!presenceSnapshot.exists ||
          presenceSnapshot.data()?['isOnline'] != true) {
        throw StateError('Go online before accepting a ride.');
      }
      if (presenceSnapshot.data()?['activeRideId'] != null) {
        throw StateError('You already have an active ride.');
      }
      final driverName = driverSnapshot.data()?['name'];
      if (driverName is! String || driverName.trim().isEmpty) {
        throw StateError('Your driver profile is missing a display name.');
      }

      final rideData = rideSnapshot.data()!;
      final passengerId = rideData['passengerId'];
      if (passengerId is! String) {
        throw StateError('This ride has invalid passenger details.');
      }
      final passengerActiveRef = _firestore
          .collection('passenger_active')
          .doc(passengerId);
      final passengerActive = await transaction.get(passengerActiveRef);
      if (!passengerActive.exists ||
          passengerActive.data()?['rideId'] != rideId) {
        throw StateError('This passenger ride is no longer active.');
      }

      transaction.update(rideRef, {
        'driverId': driverId,
        'driverName': driverName.trim(),
        'status': 'accepted',
        'dispatchState': 'assigned',
      });
      transaction.update(presenceRef, {
        'isOnline': false,
        'activeRideId': rideId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Stream<RideModel?> watchRide(String rideId) {
    return _firestore
        .collection('rides')
        .doc(rideId)
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) =>
              snapshot.exists ? RideModel.fromFirestore(snapshot) : null,
        );
  }

  Future<bool> cancelAcceptedRide(String rideId) async {
    try {
      final driverId = FirebaseAuth.instance.currentUser?.uid;
      if (driverId == null) {
        throw StateError('Sign in as the assigned driver to cancel this ride.');
      }

      final rideRef = _firestore.collection('rides').doc(rideId);
      final presenceRef = _firestore
          .collection('driver_presence')
          .doc(driverId);
      await _firestore.runTransaction((transaction) async {
        final ride = await transaction.get(rideRef);
        final presence = await transaction.get(presenceRef);
        if (!ride.exists ||
            ride.data()?['driverId'] != driverId ||
            ride.data()?['status'] != 'accepted') {
          throw StateError(
            'Only your assigned ride can be cancelled before the trip starts.',
          );
        }

        final passengerId = ride.data()?['passengerId'];
        if (passengerId is! String || passengerId.isEmpty) {
          throw StateError('The ride has invalid passenger details.');
        }
        final activeRideRef = _firestore
            .collection('passenger_active')
            .doc(passengerId);
        final activeRide = await transaction.get(activeRideRef);

        transaction.update(rideRef, {
          'status': 'cancelled',
          'dispatchState': 'cancelled',
        });
        if (activeRide.exists && activeRide.data()?['rideId'] == rideId) {
          transaction.delete(activeRideRef);
        }
        if (presence.exists && presence.data()?['activeRideId'] == rideId) {
          transaction.update(presenceRef, {
            'isOnline': false,
            'activeRideId': null,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      return true;
    } catch (error) {
      debugPrint('Cancel Accepted Ride Error: $error');
      return false;
    }
  }

  Future<void> updateDriverLocation(
    String rideId,
    double latitude,
    double longitude,
    double accuracyMeters,
  ) async {
    final driverId = FirebaseAuth.instance.currentUser?.uid;
    if (driverId == null) {
      throw StateError('Sign in as the assigned driver to share location.');
    }
    await _firestore.collection('rides').doc(rideId).update({
      'driverLocation': GeoPoint(latitude, longitude),
      'driverLocationAccuracyMeters': accuracyMeters,
      'driverLocationUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Cancel a ride
  Future<bool> cancelRide(String rideId) async {
    try {
      final passengerId = FirebaseAuth.instance.currentUser?.uid;
      if (passengerId == null) {
        throw StateError('Sign in to cancel this ride.');
      }
      final rideRef = _firestore.collection('rides').doc(rideId);
      final activeRideRef = _firestore
          .collection('passenger_active')
          .doc(passengerId);
      await _firestore.runTransaction((transaction) async {
        final ride = await transaction.get(rideRef);
        final activeRide = await transaction.get(activeRideRef);
        final rideData = ride.data();
        final status = rideData?['status'];
        if (!ride.exists ||
            rideData?['passengerId'] != passengerId ||
            (status != 'requested' && status != 'accepted') ||
            (activeRide.exists && activeRide.data()?['rideId'] != rideId)) {
          throw StateError('This ride can no longer be cancelled.');
        }

        final driverId = status == 'accepted' && rideData != null
            ? rideData['driverId']
            : null;
        DocumentReference<Map<String, dynamic>>? driverPresenceRef;
        DocumentSnapshot<Map<String, dynamic>>? driverPresence;
        if (driverId is String && driverId.isNotEmpty) {
          driverPresenceRef = _firestore
              .collection('driver_presence')
              .doc(driverId);
          driverPresence = await transaction.get(driverPresenceRef);
        } else if (status == 'accepted') {
          throw StateError('The assigned driver details are unavailable.');
        }

        transaction.update(rideRef, {
          'status': 'cancelled',
          'dispatchState': 'cancelled',
        });
        if (activeRide.exists) {
          transaction.delete(activeRideRef);
        }
        if (driverPresence?.data()?['activeRideId'] == rideId) {
          transaction.update(driverPresenceRef!, {
            'isOnline': false,
            'activeRideId': null,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      return true;
    } catch (e) {
      debugPrint('Cancel Ride Error: $e');
      return false;
    }
  }

  double _distanceKm(
    double firstLatitude,
    double firstLongitude,
    double secondLatitude,
    double secondLongitude,
  ) {
    const earthRadiusKm = 6371.0;
    double radians(double degrees) => degrees * pi / 180;
    final latitudeDelta = radians(secondLatitude - firstLatitude);
    final longitudeDelta = radians(secondLongitude - firstLongitude);
    final a =
        sin(latitudeDelta / 2) * sin(latitudeDelta / 2) +
        cos(radians(firstLatitude)) *
            cos(radians(secondLatitude)) *
            sin(longitudeDelta / 2) *
            sin(longitudeDelta / 2);
    return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // Complete ride
  Future<bool> completeRide(String rideId) async {
    try {
      final driverId = FirebaseAuth.instance.currentUser?.uid;
      if (driverId == null) {
        throw StateError(
          'Sign in as the assigned driver to complete the ride.',
        );
      }
      final rideRef = _firestore.collection('rides').doc(rideId);
      final presenceRef = _firestore
          .collection('driver_presence')
          .doc(driverId);
      final ledgerRef = _firestore.collection('wallet_ledger').doc(rideId);
      await _firestore.runTransaction((transaction) async {
        final ride = await transaction.get(rideRef);
        final presence = await transaction.get(presenceRef);
        if (!ride.exists ||
            ride.data()?['driverId'] != driverId ||
            ride.data()?['status'] != 'in_progress') {
          throw StateError('Only your in-progress ride can be completed.');
        }
        final data = ride.data()!;
        final passengerId = data['passengerId'];
        final fare = data['estimatedPrice'];
        final distanceKm = data['distance'];
        if (passengerId is! String ||
            fare is! num ||
            fare < 15 ||
            fare > 10000 ||
            distanceKm is! num ||
            !distanceKm.isFinite ||
            distanceKm < 0 ||
            distanceKm > 1000) {
          throw StateError(
            'Ride details are invalid; the fare record was not saved.',
          );
        }
        final activeRideRef = _firestore
            .collection('passenger_active')
            .doc(passengerId);
        final activeRide = await transaction.get(activeRideRef);
        final cooperativeFee = PaymentService().calculateCooperativeShare(
          fare.toDouble(),
        );
        final driverAllocation = fare.toDouble() - cooperativeFee;
        transaction.update(rideRef, {
          'status': 'completed',
          'endTime': FieldValue.serverTimestamp(),
          'finalPrice': fare,
          'currency': 'PHP',
          'fareBasis': data['fareBasis'] ?? PaymentService.legacyFareBasis,
          'paymentMethod': 'cash',
          'cashCollectedByDriver': true,
        });
        transaction.set(ledgerRef, {
          'rideId': rideId,
          'passengerId': passengerId,
          'driverId': driverId,
          'currency': 'PHP',
          'farePhp': fare,
          'baseFarePhp': 15,
          'distanceKm': distanceKm,
          'ratePerKmPhp': 8,
          'driverFareAllocationPhp': driverAllocation,
          'cooperativeFeePhp': cooperativeFee,
          'cooperativeSharePercent': PaymentService.cooperativeSharePercent,
          'allocationPolicyVersion': PaymentService.fareAllocationPolicyVersion,
          'driverCreditPhp': 0,
          'cashFarePhp': fare,
          'platformCreditPhp': 0,
          'fareBasis': data['fareBasis'] ?? PaymentService.legacyFareBasis,
          'fareCalculationVersion':
              data['fareBasis'] == PaymentService.flatFareBasis
              ? PaymentService.flatFareCalculationVersion
              : PaymentService.legacyFareCalculationVersion,
          'entryType': 'cash_fare_record',
          'paymentMethod': 'cash',
          'cashCollectedByDriver': true,
          'settlementStatus': 'cash_recorded',
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (presence.exists && presence.data()?['activeRideId'] == rideId) {
          transaction.update(presenceRef, {
            'activeRideId': null,
            'isOnline': false,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        if (activeRide.exists && activeRide.data()?['rideId'] == rideId) {
          transaction.delete(activeRideRef);
        }
      });
      return true;
    } catch (error, stackTrace) {
      debugPrint('Complete Ride Error: $error');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Stream<List<Map<String, dynamic>>> watchDriverLedger(String driverId) {
    return _firestore
        .collection('wallet_ledger')
        .where('driverId', isEqualTo: driverId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) => doc.data()).toList());
  }

  Future<Map<String, dynamic>> getAdminFinancialReport() async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 35));
    final snapshot = await _firestore
        .collection('wallet_ledger')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
        .orderBy('createdAt', descending: true)
        .limit(1001)
        .get();

    final daily = <String, Map<String, dynamic>>{};
    final recentTransactions = <Map<String, dynamic>>[];
    var totalFarePhp = 0.0;
    var driverAllocationPhp = 0.0;
    var cooperativeFeePhp = 0.0;
    var legacyEntries = 0;

    for (final document in snapshot.docs.take(1000)) {
      final entry = document.data();
      final timestamp = entry['createdAt'];
      final fare = entry['cashFarePhp'];
      if (timestamp is! Timestamp || fare is! num || !fare.isFinite) {
        legacyEntries++;
        continue;
      }
      final createdAt = timestamp.toDate().toUtc();
      final dateKey =
          '${createdAt.year.toString().padLeft(4, '0')}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')}';
      final day = daily.putIfAbsent(
        dateKey,
        () => {
          'transactions': 0,
          'cashFaresPhp': 0.0,
          'driverAllocationPhp': 0.0,
          'cooperativeFeePhp': 0.0,
        },
      );
      final fareAmount = fare.toDouble();
      final driverShare = entry['driverFareAllocationPhp'];
      final cooperativeShare = entry['cooperativeFeePhp'];
      if (recentTransactions.length < 30) {
        recentTransactions.add({
          'rideId': entry['rideId'] ?? document.id,
          'driverId': entry['driverId'],
          'passengerId': entry['passengerId'],
          'createdAt': createdAt,
          'cashFarePhp': fareAmount,
          'baseFarePhp': entry['baseFarePhp'],
          'distanceKm': entry['distanceKm'],
          'ratePerKmPhp': entry['ratePerKmPhp'],
          'driverAllocationPhp': driverShare is num
              ? driverShare.toDouble()
              : fareAmount,
          'cooperativeFeePhp': cooperativeShare is num
              ? cooperativeShare.toDouble()
              : 0.0,
          'cooperativeSharePercent': entry['cooperativeSharePercent'],
          'allocationPolicyVersion': entry['allocationPolicyVersion'],
          'fareCalculationVersion': entry['fareCalculationVersion'],
        });
      }
      day['transactions'] = (day['transactions'] as int) + 1;
      day['cashFaresPhp'] = (day['cashFaresPhp'] as double) + fareAmount;
      day['driverAllocationPhp'] =
          (day['driverAllocationPhp'] as double) +
          (driverShare is num ? driverShare.toDouble() : fareAmount);
      day['cooperativeFeePhp'] =
          (day['cooperativeFeePhp'] as double) +
          (cooperativeShare is num ? cooperativeShare.toDouble() : 0.0);
      totalFarePhp += fareAmount;
      driverAllocationPhp += driverShare is num
          ? driverShare.toDouble()
          : fareAmount;
      cooperativeFeePhp += cooperativeShare is num
          ? cooperativeShare.toDouble()
          : 0.0;
      if (driverShare is! num || cooperativeShare is! num) legacyEntries++;
    }

    return {
      'periodDays': 35,
      'transactionCount': snapshot.size > 1000 ? 1000 : snapshot.size,
      'completedTransactions': daily.values.fold<int>(
        0,
        (total, entry) => total + (entry['transactions'] as int),
      ),
      'totalCashFaresPhp': totalFarePhp,
      'driverAllocationPhp': driverAllocationPhp,
      'cooperativeFeePhp': cooperativeFeePhp,
      'legacyEntries': legacyEntries,
      'daily': daily,
      'recentTransactions': recentTransactions,
      'capped': snapshot.size > 1000,
    };
  }

  Future<Map<String, dynamic>> getAdminRideReport() async {
    final now = DateTime.now().toUtc();
    final todayDateKey =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final cutoff = now.subtract(const Duration(days: 35));
    final trainingCutoff = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 35));
    final snapshot = await _firestore
        .collection('rides')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
        .orderBy('createdAt', descending: true)
        .limit(1001)
        .get();

    final counts = <String, int>{
      'requested': 0,
      'accepted': 0,
      'in_progress': 0,
      'completed': 0,
      'cancelled': 0,
    };
    final ridesByDate = <String, int>{};
    final hourlyRequestsByDate = <String, int>{};
    final todayHourlyRequests = List<int>.filled(24, 0);
    final quarterHourRequestsByDate = <String, int>{};
    final zoneRequestsByDate = <String, int>{};
    final zoneRequestsByDateHour = <String, int>{};
    final recentRides = <Map<String, dynamic>>[];
    var completedDistanceTotal = 0.0;
    var completedDistanceCount = 0;
    var completedCashFarePhp = 0.0;
    DateTime? oldestIncludedRideAt;
    final reportCapped = snapshot.size > 1000;
    final trainingRequestsByDateHour = <String, int>{};

    for (final document in snapshot.docs.take(1000)) {
      final data = document.data();
      final createdAt = data['createdAt'];
      if (createdAt is! Timestamp) continue;
      final created = createdAt.toDate().toUtc();
      if (oldestIncludedRideAt == null ||
          created.isBefore(oldestIncludedRideAt)) {
        oldestIncludedRideAt = created;
      }
      final status = data['status'];
      if (status is String && counts.containsKey(status)) {
        counts[status] = counts[status]! + 1;
      }
      final dateKey =
          '${created.year.toString().padLeft(4, '0')}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}';
      final trainingHourKey = '$dateKey-${created.hour}';
      trainingRequestsByDateHour[trainingHourKey] =
          (trainingRequestsByDateHour[trainingHourKey] ?? 0) + 1;
      ridesByDate[dateKey] = (ridesByDate[dateKey] ?? 0) + 1;
      if (dateKey == todayDateKey) {
        todayHourlyRequests[created.hour]++;
      }
      final hourKey =
          '${created.year}-${created.month}-${created.day}-${created.weekday}-${created.hour}';
      hourlyRequestsByDate[hourKey] = (hourlyRequestsByDate[hourKey] ?? 0) + 1;
      final quarterHour = created.minute ~/ 15;
      final historicalTimeBucket =
          '${created.hour.toString().padLeft(2, '0')}:${(quarterHour * 15).toString().padLeft(2, '0')}';
      final quarterHourKey =
          '$dateKey-${created.weekday}-$historicalTimeBucket';
      quarterHourRequestsByDate[quarterHourKey] =
          (quarterHourRequestsByDate[quarterHourKey] ?? 0) + 1;
      final pickupLat = data['pickupLat'];
      final pickupLng = data['pickupLng'];
      if (pickupLat is num &&
          pickupLng is num &&
          pickupLat.isFinite &&
          pickupLng.isFinite &&
          pickupLat >= -90 &&
          pickupLat <= 90 &&
          pickupLng >= -180 &&
          pickupLng <= 180) {
        const gridStep = 0.01;
        final latitudeCell = (pickupLat / gridStep).floor();
        final longitudeCell = (pickupLng / gridStep).floor();
        final demandClusterId = 'lat_${latitudeCell}_lng_$longitudeCell';
        final zoneKey = '$dateKey-${created.weekday}-$demandClusterId';
        zoneRequestsByDate[zoneKey] = (zoneRequestsByDate[zoneKey] ?? 0) + 1;
        final zoneHourKey =
            '$dateKey-${created.weekday}-$demandClusterId-${created.hour}';
        zoneRequestsByDateHour[zoneHourKey] =
            (zoneRequestsByDateHour[zoneHourKey] ?? 0) + 1;
      }
      if (status == 'completed') {
        final distance = data['distance'];
        if (distance is num) {
          completedDistanceTotal += distance.toDouble();
          completedDistanceCount++;
        }
        if (data['paymentMethod'] == 'cash') {
          final fare = data['finalPrice'] ?? data['estimatedPrice'];
          if (fare is num) completedCashFarePhp += fare.toDouble();
        }
      }
      if (recentRides.length < 50) {
        recentRides.add({
          'id': document.id,
          'status': status,
          'createdAt': created.toIso8601String(),
          'pickupLocation': data['pickupLocation'],
          'dropoffLocation': data['dropoffLocation'],
          'farePhp': data['finalPrice'] ?? data['estimatedPrice'],
        });
      }
    }

    final comparableDateKeys = <String>[];
    for (var day = 1; day <= 35; day++) {
      final date = now.subtract(Duration(days: day));
      if (date.weekday != now.weekday) continue;
      final dateStart = DateTime.utc(date.year, date.month, date.day);
      if (dateStart.isBefore(cutoff)) continue;
      if (reportCapped && oldestIncludedRideAt != null) {
        final oldestCoveredDate = DateTime.utc(
          oldestIncludedRideAt.year,
          oldestIncludedRideAt.month,
          oldestIncludedRideAt.day,
        );
        if (dateStart.isBefore(oldestCoveredDate)) continue;
      }
      comparableDateKeys.add(
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      );
    }
    final comparableDates = comparableDateKeys.length;
    final quarterHourTrend = List<Map<String, dynamic>>.generate(96, (index) {
      final hour = index ~/ 4;
      final minute = (index % 4) * 15;
      final bucket =
          '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
      var total = 0;
      for (final dateKey in comparableDateKeys) {
        total +=
            quarterHourRequestsByDate['$dateKey-${now.weekday}-$bucket'] ?? 0;
      }
      return {
        'historicalTimeBucket': bucket,
        'averageRequests': comparableDates == 0 ? 0.0 : total / comparableDates,
        'totalRequests': total,
      };
    });
    final hourlyTrend = List<Map<String, dynamic>>.generate(24, (hour) {
      final firstBucket = hour * 4;
      final hourTotal = quarterHourTrend
          .skip(firstBucket)
          .take(4)
          .fold<double>(
            0,
            (total, bucket) => total + (bucket['averageRequests'] as double),
          );
      return {
        'hour': hour,
        'label': '${hour.toString().padLeft(2, '0')}:00',
        'averageRequests': hourTotal,
      };
    });
    final todayHourlyTrend = List<Map<String, dynamic>>.generate(
      24,
      (hour) => {
        'hour': hour,
        'label': '${hour.toString().padLeft(2, '0')}:00',
        'rideCount': todayHourlyRequests[hour],
      },
    );
    var currentHourCount = 0;
    for (final dateKey in comparableDateKeys) {
      final date = DateTime.parse('${dateKey}T00:00:00Z');
      final key =
          '${date.year}-${date.month}-${date.day}-${date.weekday}-${now.hour}';
      currentHourCount += hourlyRequestsByDate[key] ?? 0;
    }
    final averageRequests = comparableDates == 0
        ? 0.0
        : currentHourCount / comparableDates;

    final zoneTotals = <String, int>{};
    for (final dateKey in comparableDateKeys) {
      for (final entry in zoneRequestsByDate.entries) {
        if (entry.key.startsWith('$dateKey-${now.weekday}-')) {
          final clusterId = entry.key.substring(
            '$dateKey-${now.weekday}-'.length,
          );
          zoneTotals[clusterId] = (zoneTotals[clusterId] ?? 0) + entry.value;
        }
      }
    }
    final topDemandZones = zoneTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final demandZones = topDemandZones.take(5).map((entry) {
      final cells = RegExp(r'^lat_(-?\d+)_lng_(-?\d+)$').firstMatch(entry.key);
      final latitudeCell = int.tryParse(cells?.group(1) ?? '');
      final longitudeCell = int.tryParse(cells?.group(2) ?? '');
      final centerLatitude = latitudeCell == null
          ? null
          : (latitudeCell + 0.5) * 0.01;
      final centerLongitude = longitudeCell == null
          ? null
          : (longitudeCell + 0.5) * 0.01;
      final hourlyAverages = List<double>.generate(24, (hour) {
        var total = 0;
        for (final dateKey in comparableDateKeys) {
          total +=
              zoneRequestsByDateHour['$dateKey-${now.weekday}-${entry.key}-$hour'] ??
              0;
        }
        return comparableDates == 0 ? 0.0 : total / comparableDates;
      });
      final zoneHourlyAverage =
          hourlyAverages.fold<double>(0, (total, value) => total + value) /
          hourlyAverages.length;
      final surgeHours = [
        for (var hour = 0; hour < hourlyAverages.length; hour++)
          if (hourlyAverages[hour] >= 0.5 &&
              hourlyAverages[hour] >= zoneHourlyAverage * 1.5)
            hour,
      ];
      return {
        'demandClusterId': entry.key,
        'label': centerLatitude == null || centerLongitude == null
            ? entry.key
            : '${centerLatitude.toStringAsFixed(3)}, ${centerLongitude.toStringAsFixed(3)}',
        'averageRequests': comparableDates == 0
            ? 0.0
            : entry.value / comparableDates,
        'totalRequests': entry.value,
        'hourlyTrend': hourlyAverages,
        'surgeHours': surgeHours,
        'averageRequestsPerHour': zoneHourlyAverage,
      };
    }).toList();

    final peakHours =
        hourlyTrend
            .where((hour) => (hour['averageRequests'] as double) > 0)
            .toList()
          ..sort(
            (a, b) => (b['averageRequests'] as double).compareTo(
              a['averageRequests'] as double,
            ),
          );
    final recommendations = <String>[];
    if (comparableDates > 0 && peakHours.isNotEmpty) {
      final peakHour = peakHours.first;
      final hour = peakHour['hour'] as int;
      final average = peakHour['averageRequests'] as double;
      recommendations.add(
        'Consider staging available drivers before ${hour.toString().padLeft(2, '0')}:00 UTC, the busiest historical hour (${average.toStringAsFixed(1)} requests per comparable day).',
      );
      if (peakHours.length > 1) {
        final secondHour = peakHours[1]['hour'] as int;
        recommendations.add(
          'Keep some flexible coverage for ${secondHour.toString().padLeft(2, '0')}:00 UTC, the next strongest historical hour.',
        );
      }
    } else {
      recommendations.add(
        'There is not enough matching weekday history in this report to suggest a peak deployment window.',
      );
    }
    if (demandZones.isNotEmpty && peakHours.isNotEmpty) {
      final zone = demandZones.first;
      recommendations.add(
        'Prioritize monitoring approximate pickup grid ${zone['label']} near ${peakHours.first['label']} UTC; it had the most matching-weekday pickups.',
      );
    } else if (demandZones.isEmpty) {
      recommendations.add(
        'No valid pickup coordinates were available to rank approximate demand zones.',
      );
    }
    final mlDemandForecast = _buildDemandPrediction(
      now: now,
      trainingCutoff: trainingCutoff,
      trainingCapped: reportCapped,
      oldestTrainingRideAt: oldestIncludedRideAt,
      requestsByDateHour: trainingRequestsByDateHour,
    );
    return {
      'periodDays': 35,
      'totalRides': snapshot.size > 1000 ? 1000 : snapshot.size,
      'counts': counts,
      'completedCashFarePhp': completedCashFarePhp,
      'averageCompletedDistanceKm': completedDistanceCount == 0
          ? 0.0
          : completedDistanceTotal / completedDistanceCount,
      'demandForecast': {
        'level': averageRequests >= 5
            ? 'high'
            : averageRequests >= 2
            ? 'medium'
            : 'low',
        'averageRequestsPerHour': averageRequests,
        'matchingHistoricalHours': comparableDates,
        'comparableDates': comparableDates,
        'timezone': 'UTC',
        'quarterHourTrend': quarterHourTrend,
        'hourlyTrend': hourlyTrend,
        'todayHourlyTrend': todayHourlyTrend,
        'topDemandZones': demandZones,
        'recommendations': recommendations,
        'mlDemandForecast': mlDemandForecast,
        'method':
            'Historical zone trends use weekday-matched averages; the separate '
            'next-24-hour forecast uses regularized seasonal regression trained '
            'on the same recent ride records used by this report.',
      },
      'ridesByDate': ridesByDate,
      'capped': reportCapped,
      'recentRides': recentRides,
    };
  }

  Map<String, dynamic> _buildDemandPrediction({
    required DateTime now,
    required DateTime trainingCutoff,
    required bool trainingCapped,
    required DateTime? oldestTrainingRideAt,
    required Map<String, int> requestsByDateHour,
  }) {
    final today = DateTime.utc(now.year, now.month, now.day);
    final trainingStart = trainingCapped && oldestTrainingRideAt != null
        ? DateTime.utc(
            oldestTrainingRideAt.year,
            oldestTrainingRideAt.month,
            oldestTrainingRideAt.day,
          ).add(const Duration(days: 1))
        : trainingCutoff.add(const Duration(days: 1));
    final trainingEnd = today.subtract(const Duration(days: 1));
    final trainingDays = trainingEnd.difference(trainingStart).inDays + 1;
    if (trainingDays < 28) {
      return {
        'available': false,
        'reason':
            'At least 28 days of ride history are needed to train a forecast.',
        'trainingDays': trainingDays < 0 ? 0 : trainingDays,
        'trainingRideCount': 0,
        'trainingCapped': trainingCapped,
      };
    }

    final examples = <({List<double> features, double target})>[];
    var includedTrainingRideCount = 0;
    for (var dayOffset = 0; dayOffset < trainingDays; dayOffset++) {
      final date = trainingStart.add(Duration(days: dayOffset));
      final dateKey =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      for (var hour = 0; hour < 24; hour++) {
        final rideCount = requestsByDateHour['$dateKey-$hour'] ?? 0;
        includedTrainingRideCount += rideCount;
        examples.add((
          features: _demandModelFeatures(date, hour),
          target: rideCount.toDouble(),
        ));
      }
    }
    if (includedTrainingRideCount < 30) {
      return {
        'available': false,
        'reason': 'At least 30 recorded rides are needed to train a forecast.',
        'trainingDays': trainingDays,
        'trainingRideCount': includedTrainingRideCount,
        'trainingCapped': trainingCapped,
      };
    }

    final weights = List<double>.filled(8, 0);
    weights[0] =
        examples.fold<double>(0, (total, sample) => total + sample.target) /
        examples.length;
    const learningRate = 0.04;
    const regularization = 0.02;
    for (var iteration = 0; iteration < 600; iteration++) {
      final gradients = List<double>.filled(weights.length, 0);
      for (final sample in examples) {
        var prediction = 0.0;
        for (var feature = 0; feature < weights.length; feature++) {
          prediction += weights[feature] * sample.features[feature];
        }
        final error = prediction - sample.target;
        for (var feature = 0; feature < weights.length; feature++) {
          gradients[feature] += error * sample.features[feature];
        }
      }
      for (var feature = 0; feature < weights.length; feature++) {
        final gradient =
            gradients[feature] / examples.length +
            (feature == 0 ? 0 : regularization * weights[feature]);
        weights[feature] -= learningRate * gradient;
      }
    }

    final firstForecastHour = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
    ).add(const Duration(hours: 1));
    final predictions = List<Map<String, dynamic>>.generate(24, (index) {
      final dateTime = firstForecastHour.add(Duration(hours: index));
      final features = _demandModelFeatures(dateTime, dateTime.hour);
      var predictedRequests = 0.0;
      for (var feature = 0; feature < weights.length; feature++) {
        predictedRequests += weights[feature] * features[feature];
      }
      return {
        'timestamp': dateTime.toIso8601String(),
        'hour': dateTime.hour,
        'label':
            '${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')} '
            '${dateTime.hour.toString().padLeft(2, '0')}:00',
        'predictedRequests': predictedRequests.clamp(0.0, double.infinity),
      };
    });
    return {
      'available': true,
      'model': 'Regularized seasonal regression',
      'trainingDays': trainingDays,
      'trainingRideCount': includedTrainingRideCount,
      'trainingCapped': trainingCapped,
      'forecastStart': firstForecastHour.toIso8601String(),
      'predictions': predictions,
    };
  }

  List<double> _demandModelFeatures(DateTime date, int hour) {
    final dailyAngle = 2 * pi * hour / 24;
    final weeklyAngle = 2 * pi * (date.weekday - 1) / 7;
    return [
      1,
      sin(dailyAngle),
      cos(dailyAngle),
      sin(2 * dailyAngle),
      cos(2 * dailyAngle),
      sin(weeklyAngle),
      cos(weeklyAngle),
      date.weekday >= DateTime.saturday ? 1 : 0,
    ];
  }

  // Get available rides for drivers
  Stream<List<RideModel>> getAvailableRides() {
    return _firestore
        .collection('rides')
        .where('status', isEqualTo: 'requested')
        .orderBy('createdAt')
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) =>
              snapshot.docs.map((doc) => RideModel.fromFirestore(doc)).toList(),
        );
  }

  // Get passenger's current ride
  Stream<RideModel?> getPassengerCurrentRide(String passengerId) {
    return _firestore
        .collection('rides')
        .where('passengerId', isEqualTo: passengerId)
        .where('status', whereIn: ['requested', 'accepted', 'in_progress'])
        .limit(1)
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) => snapshot.docs.isNotEmpty
              ? RideModel.fromFirestore(snapshot.docs.first)
              : null,
        );
  }

  // Get driver's current ride
  Stream<RideModel?> getDriverCurrentRide(String driverId) {
    return _firestore
        .collection('rides')
        .where('driverId', isEqualTo: driverId)
        .where('status', whereIn: ['accepted', 'in_progress'])
        .limit(1)
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) => snapshot.docs.isNotEmpty
              ? RideModel.fromFirestore(snapshot.docs.first)
              : null,
        );
  }

  // Get ride by ID
  Future<RideModel?> getRideById(String rideId) async {
    final rideRef = _firestore.collection('rides').doc(rideId);
    try {
      final doc = await rideRef.get();
      return doc.exists ? RideModel.fromFirestore(doc) : null;
    } catch (e) {
      debugPrint('Get Ride Error: $e');
    }

    try {
      final cachedDoc = await rideRef.get(
        const GetOptions(source: Source.cache),
      );
      return cachedDoc.exists ? RideModel.fromFirestore(cachedDoc) : null;
    } catch (e) {
      debugPrint('Get Cached Ride Error: $e');
      return null;
    }
  }

  Future<String> issueTripVerificationCode(String rideId) async {
    final passengerId = FirebaseAuth.instance.currentUser?.uid;
    if (passengerId == null) {
      throw StateError('Sign in as the passenger to create a trip QR.');
    }
    final rideRef = _firestore.collection('rides').doc(rideId);
    final code = List<int>.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final expiry = DateTime.now().add(const Duration(minutes: 5));
    return _firestore.runTransaction<String>((transaction) async {
      final ride = await transaction.get(rideRef);
      if (!ride.exists ||
          ride.data()?['passengerId'] != passengerId ||
          ride.data()?['status'] != 'accepted') {
        throw StateError('A trip QR is available only for your accepted ride.');
      }
      final storedCode = ride.data()?['tripVerificationCode'];
      final storedExpiry = ride.data()?['tripVerificationExpiresAt'];
      if (storedCode is String &&
          storedExpiry is Timestamp &&
          storedExpiry.toDate().isAfter(DateTime.now())) {
        return storedCode;
      }
      transaction.update(rideRef, {
        'tripVerificationCode': code,
        'tripVerificationExpiresAt': Timestamp.fromDate(expiry),
      });
      return code;
    });
  }

  Future<bool> validatePassengerTripQr({
    required String rideId,
    required String scannedCode,
  }) async {
    try {
      final driverId = FirebaseAuth.instance.currentUser?.uid;
      if (driverId == null) return false;
      final rideRef = _firestore.collection('rides').doc(rideId);
      return await _firestore.runTransaction((transaction) async {
        final ride = await transaction.get(rideRef);
        final data = ride.data();
        final code = data?['tripVerificationCode'];
        final expiresAt = data?['tripVerificationExpiresAt'];
        if (!ride.exists ||
            data?['driverId'] != driverId ||
            data?['status'] != 'accepted' ||
            code != scannedCode ||
            expiresAt is! Timestamp ||
            !expiresAt.toDate().isAfter(DateTime.now())) {
          return false;
        }
        transaction.update(rideRef, {
          'status': 'in_progress',
          'startTime': FieldValue.serverTimestamp(),
          'qrValidatedAt': FieldValue.serverTimestamp(),
          'tripVerificationCode': FieldValue.delete(),
          'tripVerificationExpiresAt': FieldValue.delete(),
        });
        return true;
      });
    } catch (error) {
      debugPrint('Trip QR verification failed: $error');
      return false;
    }
  }

  // Add rating and review
  Future<void> addRating(
    String rideId,
    bool isPassenger,
    double rating,
    String review,
  ) async {
    if (rating < 1 || rating > 5 || rating != rating.roundToDouble()) {
      throw ArgumentError.value(rating, 'rating', 'Must be a whole star 1–5.');
    }
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      throw StateError('Sign in before rating this ride.');
    }
    final fields = isPassenger
        ? {'passengerRating': rating, 'passengerReview': review}
        : {'driverRating': rating, 'driverReview': review};
    await _firestore.collection('rides').doc(rideId).update(fields);
  }

  // Get ride history for user
  Future<List<RideModel>> getRideHistory(String userId, bool isDriver) async {
    final field = isDriver ? 'driverId' : 'passengerId';
    final query = _firestore
        .collection('rides')
        .where(field, isEqualTo: userId)
        .where('status', isEqualTo: 'completed')
        .orderBy('endTime', descending: true);

    try {
      final snapshot = await query.get();
      return snapshot.docs.map(RideModel.fromFirestore).toList();
    } catch (error) {
      debugPrint('Get Ride History Error: $error');
    }

    try {
      final cachedSnapshot = await query.get(
        const GetOptions(source: Source.cache),
      );
      return cachedSnapshot.docs.map(RideModel.fromFirestore).toList();
    } catch (error) {
      debugPrint('Get Cached Ride History Error: $error');
      return [];
    }
  }
}
