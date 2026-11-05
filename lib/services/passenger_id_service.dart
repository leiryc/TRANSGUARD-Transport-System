import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

import '../models/user_model.dart';

/// A validated ID photo, ready to be stored in Firestore.
class IdImage {
  const IdImage({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// An ID photo plus the kind of ID it shows.
class PassengerIdUpload {
  const PassengerIdUpload({required this.idType, required this.image});

  final String idType;
  final IdImage image;
}

/// Stores passenger ID photos in Firestore (`passenger_ids/{uid}`) and lets
/// administrators review them. Photos live in their own collection so the
/// large image bytes are never downloaded together with the user profile.
class PassengerIdService {
  PassengerIdService()
    : _firestore = FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Must stay below Firestore's 1 MiB document limit. Mirrored in
  /// firestore.rules.
  static const int maxImageBytes = 900 * 1024;

  /// Accepted ID types. Keys are stored in Firestore and mirrored in
  /// firestore.rules.
  static const Map<String, String> idTypes = {
    'philsys': 'PhilSys National ID',
    'drivers_license': "Driver's License",
    'passport': 'Passport',
    'umid': 'UMID',
    'postal': 'Postal ID',
    'voters': "Voter's ID",
    'prc': 'PRC ID',
    'senior_citizen': 'Senior Citizen ID',
    'pwd': 'PWD ID',
    'student': 'School / Student ID',
  };

  static String labelFor(String? idType) => idTypes[idType] ?? 'Valid ID';

  static CollectionReference<Map<String, dynamic>> collection(
    FirebaseFirestore firestore,
  ) => firestore.collection('passenger_ids');

  /// Data for a `passenger_ids/{uid}` document.
  static Map<String, dynamic> documentData(PassengerIdUpload upload) => {
    'idType': upload.idType,
    'image': Blob(upload.image.bytes),
    'contentType': upload.image.contentType,
    'uploadedAt': FieldValue.serverTimestamp(),
  };

  /// User profile fields that mark an ID as submitted and awaiting review.
  static Map<String, dynamic> pendingProfileFields(PassengerIdUpload upload) =>
      {
        'idVerificationStatus': 'pending',
        'idType': upload.idType,
        'idSubmittedAt': FieldValue.serverTimestamp(),
      };

  /// Opens the camera or gallery and returns a downscaled, validated photo,
  /// or null if the user cancelled. Throws [FormatException] with a
  /// user-facing message if the photo can't be used.
  static Future<IdImage?> pickImage(ImageSource source) async {
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    final contentType = detectContentType(bytes);
    if (contentType == null) {
      throw const FormatException('Use a JPEG, PNG, or WebP photo of your ID.');
    }
    if (bytes.length > maxImageBytes) {
      throw const FormatException(
        'That photo is too large (max 900 KB). Take a new photo with the '
        'camera, or choose a smaller image.',
      );
    }
    return IdImage(bytes: bytes, contentType: contentType);
  }

  /// Identifies JPEG, PNG and WebP images from their magic bytes.
  static String? detectContentType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }

  /// Uploads the signed-in passenger's ID and puts it in the review queue.
  /// Only allowed when no ID is on file or the last one was rejected
  /// (enforced by firestore.rules).
  Future<void> submitForCurrentUser(PassengerIdUpload upload) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw StateError('Sign in again before uploading your ID.');
    }
    final batch = _firestore.batch();
    batch.set(collection(_firestore).doc(userId), documentData(upload));
    batch.update(_firestore.collection('users').doc(userId), {
      ...pendingProfileFields(upload),
      'idRejectionReason': FieldValue.delete(),
    });
    try {
      await batch.commit();
    } on FirebaseException catch (error) {
      throw StateError('Could not upload your ID (${error.code}).');
    }
  }

  /// Admin: passengers whose ID status is [status] ('pending', 'verified' or
  /// 'rejected'). Pending IDs are listed oldest first, in review-queue order;
  /// reviewed IDs are listed most recently reviewed first.
  Stream<List<UserModel>> watchPassengersByIdStatus(String status) {
    return _firestore
        .collection('users')
        .where('userType', isEqualTo: 'passenger')
        .where('idVerificationStatus', isEqualTo: status)
        .snapshots()
        .map((snapshot) {
          final passengers = snapshot.docs
              .map(UserModel.fromFirestore)
              .toList();
          final epoch = DateTime.fromMillisecondsSinceEpoch(0);
          if (status == 'pending') {
            passengers.sort(
              (a, b) => (a.idSubmittedAt ?? epoch).compareTo(
                b.idSubmittedAt ?? epoch,
              ),
            );
          } else {
            passengers.sort(
              (a, b) =>
                  (b.idReviewedAt ?? epoch).compareTo(a.idReviewedAt ?? epoch),
            );
          }
          return passengers;
        });
  }

  /// Admin or owner: loads the stored ID photo.
  Future<IdImage?> loadIdImage(String userId) async {
    final doc = await collection(_firestore).doc(userId).get();
    final data = doc.data();
    final image = data?['image'];
    if (image is! Blob) return null;
    return IdImage(
      bytes: image.bytes,
      contentType: data?['contentType'] as String? ?? 'image/jpeg',
    );
  }

  /// Admin: marks a passenger's ID as verified or rejected.
  Future<void> review(
    String userId, {
    required bool verified,
    String? rejectionReason,
  }) async {
    final adminId = _auth.currentUser?.uid;
    if (adminId == null) {
      throw StateError('Sign in as an administrator to review IDs.');
    }
    final reason = rejectionReason?.trim() ?? '';
    try {
      await _firestore.collection('users').doc(userId).update({
        'idVerificationStatus': verified ? 'verified' : 'rejected',
        'idReviewedAt': FieldValue.serverTimestamp(),
        'idReviewedBy': adminId,
        'idRejectionReason': verified || reason.isEmpty
            ? FieldValue.delete()
            : reason,
      });
    } on FirebaseException catch (error) {
      throw StateError(
        'Firestore denied the review (${error.code}). Confirm this account '
        'has userType "admin" and the ID is still pending.',
      );
    }
  }
}
