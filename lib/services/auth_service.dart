import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/user_model.dart';
import 'passenger_id_service.dart';

class AuthService {
  AuthService() {
    if (Firebase.apps.isNotEmpty) {
      _firebaseAuth = FirebaseAuth.instance;
      _firestore = FirebaseFirestore.instance;
    }
  }

  FirebaseAuth? _firebaseAuth;
  FirebaseFirestore? _firestore;

  bool get isAvailable => _firebaseAuth != null && _firestore != null;

  User? get currentUser => _firebaseAuth?.currentUser;

  Stream<User?> get authStateChanges =>
      _firebaseAuth?.authStateChanges() ?? Stream.value(null);

  Future<UserModel?> signup(
    String email,
    String password,
    String name,
    String phone,
    String userType, {
    String? franchiseNumber,
    String? plateNumber,
    PassengerIdUpload? idUpload,
  }) async {
    if (!RegExp(r'^\d{11}$').hasMatch(phone)) {
      throw const FormatException(
        'Phone number must contain exactly 11 digits.',
      );
    }
    if (!isAvailable) return null;
    final passengerIdUpload = userType == 'passenger' ? idUpload : null;

    try {
      UserCredential result = await _firebaseAuth!
          .createUserWithEmailAndPassword(email: email, password: password);

      User? user = result.user;

      if (user != null) {
        try {
          final userModel = UserModel(
            id: user.uid,
            name: name,
            email: email,
            phone: phone,
            userType: userType,
            createdAt: DateTime.now(),
            franchiseNumber: franchiseNumber,
            plateNumber: plateNumber,
            isApproved: userType != 'driver',
            approvalStatus: userType == 'driver' ? 'pending' : null,
            idVerificationStatus: passengerIdUpload != null ? 'pending' : null,
            idType: passengerIdUpload?.idType,
          );
          final userData = userModel.toFirestore();
          final batch = _firestore!.batch();
          if (passengerIdUpload != null) {
            userData.addAll(
              PassengerIdService.pendingProfileFields(passengerIdUpload),
            );
            // Written in the same batch so the account is never created
            // without its ID (or vice versa).
            batch.set(
              PassengerIdService.collection(_firestore!).doc(user.uid),
              PassengerIdService.documentData(passengerIdUpload),
            );
          }
          batch.set(
            _firestore!.collection('users').doc(user.uid),
            userData,
          );
          batch.set(_firestore!.collection('public_profiles').doc(user.uid), {
            'name': name,
          });
          await batch.commit();
          return userModel;
        } catch (error, stackTrace) {
          try {
            await user.delete();
          } on FirebaseException catch (cleanupError) {
            debugPrint(
              'Could not clean up failed signup account: $cleanupError',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    } catch (error) {
      debugPrint('Signup Error: $error');
      rethrow;
    }
    return null;
  }

  Future<UserModel?> signin(String email, String password) async {
    if (!isAvailable) return null;

    try {
      UserCredential result = await _firebaseAuth!.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      User? user = result.user;

      if (user != null) {
        DocumentSnapshot doc = await _firestore!
            .collection('users')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          return UserModel.fromFirestore(doc);
        }
      }
    } catch (e) {
      debugPrint('Signin Error: $e');
    }
    return null;
  }

  Future<void> sendPasswordResetEmail(String email) async {
    if (!isAvailable) {
      throw StateError('Account recovery is currently unavailable.');
    }
    await _firebaseAuth!.sendPasswordResetEmail(email: email.trim());
  }

  Future<void> signout() async {
    if (!isAvailable) return;
    try {
      await _firebaseAuth!.signOut();
    } catch (e) {
      debugPrint('Signout Error: $e');
    }
  }

  Future<UserModel?> getCurrentUserData() async {
    if (!isAvailable) return null;

    final user = currentUser;
    if (user == null) return null;

    final userRef = _firestore!.collection('users').doc(user.uid);
    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await userRef.get();
    } catch (error) {
      debugPrint('Get User Data Error: $error');
      try {
        final cachedDoc = await userRef.get(
          const GetOptions(source: Source.cache),
        );
        return cachedDoc.exists ? UserModel.fromFirestore(cachedDoc) : null;
      } catch (cacheError) {
        debugPrint('Get Cached User Data Error: $cacheError');
        return null;
      }
    }
    return doc.exists ? UserModel.fromFirestore(doc) : null;
  }

  Stream<UserModel?> watchUserProfile(String userId) {
    return _firestore!
        .collection('users')
        .doc(userId)
        .snapshots(includeMetadataChanges: true)
        .map(
          (document) =>
              document.exists ? UserModel.fromFirestore(document) : null,
        );
  }

  Stream<String?> watchPublicName(String userId) {
    return _firestore!
        .collection('public_profiles')
        .doc(userId)
        .snapshots(includeMetadataChanges: true)
        .map((document) {
          final name = document.data()?['name'];
          return name is String && name.trim().isNotEmpty ? name.trim() : null;
        });
  }

  Future<void> ensurePublicName({
    required String userId,
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 100) {
      throw ArgumentError.value(name, 'name', 'Must be 1 to 100 characters.');
    }
    final profileRef = _firestore!.collection('public_profiles').doc(userId);
    final profile = await profileRef.get();
    if (profile.data()?['name'] == normalizedName) return;
    await profileRef.set({'name': normalizedName});
  }

  Future<void> updateUserProfile(
    String userId,
    Map<String, dynamic> data,
  ) async {
    if (!isAvailable) return;

    try {
      await _firestore!.collection('users').doc(userId).update(data);
    } catch (e) {
      debugPrint('Update Profile Error: $e');
    }
  }

  Future<UserModel> updateUserDetails({
    required String name,
    required String phone,
  }) async {
    final user = currentUser;
    if (!isAvailable || user == null) {
      throw StateError('You must be signed in to update your profile.');
    }

    final userRef = _firestore!.collection('users').doc(user.uid);
    final batch = _firestore!.batch();
    batch.update(userRef, {'name': name, 'phone': phone});
    batch.set(_firestore!.collection('public_profiles').doc(user.uid), {
      'name': name,
    });
    await batch.commit();
    final updatedProfile = await userRef.get();
    final data = updatedProfile.data();
    if (data == null) {
      throw StateError('Your profile could not be found.');
    }
    return UserModel.fromFirestore(updatedProfile);
  }
}
