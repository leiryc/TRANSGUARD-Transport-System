import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/user_model.dart';

class DriverAccreditationService {
  DriverAccreditationService()
    : _firestore = FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  Stream<List<UserModel>> watchDrivers() {
    return _firestore
        .collection('users')
        .where('userType', isEqualTo: 'driver')
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) =>
              snapshot.docs.map(UserModel.fromFirestore).toList()..sort((a, b) {
                final aApproved = a.isApproved ? 1 : 0;
                final bApproved = b.isApproved ? 1 : 0;
                return aApproved.compareTo(bApproved);
              }),
        );
  }

  Future<void> setApproval(
    String driverId, {
    required bool approved,
    required bool rejected,
  }) async {
    final adminId = _auth.currentUser?.uid;
    if (adminId == null) {
      throw StateError('Sign in as an administrator to review drivers.');
    }

    var stage = 'checking the driver presence record';
    try {
      final presence = await _firestore
          .collection('driver_presence')
          .doc(driverId)
          .get();
      final activeRideId = presence.data()?['activeRideId'];
      stage = 'checking for active rides';
      final activeRides = await _firestore
          .collection('rides')
          .where('driverId', isEqualTo: driverId)
          .where('status', whereIn: ['accepted', 'in_progress'])
          .limit(1)
          .get();
      if (activeRideId != null || activeRides.docs.isNotEmpty) {
        throw StateError(
          'This driver has an active ride. Wait for it to finish before '
          'changing approval.',
        );
      }

      stage = 'saving the approval decision';
      await _firestore.collection('users').doc(driverId).update({
        'isApproved': approved,
        'approvalStatus': approved
            ? 'approved'
            : rejected
            ? 'rejected'
            : 'revoked',
        'approvalUpdatedAt': FieldValue.serverTimestamp(),
        'approvalUpdatedBy': adminId,
      });

      if (!approved) {
        final presenceRef = _firestore
            .collection('driver_presence')
            .doc(driverId);
        stage = 'setting the driver offline';
        final currentPresence = await presenceRef.get();
        if (currentPresence.exists &&
            currentPresence.data()?['isOnline'] == true) {
          await presenceRef.update({
            'isOnline': false,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
    } on FirebaseException catch (error) {
      throw StateError(
        'Firestore denied while $stage (${error.code}). '
        'Confirm this account has userType "admin"; approval also requires '
        'the driver profile to contain their franchise and plate numbers.',
      );
    }
  }
}
