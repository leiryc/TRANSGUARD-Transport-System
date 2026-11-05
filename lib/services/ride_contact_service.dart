import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ride_chat_message.dart';

/// Passenger-driver contact while the driver is on the way: in-app chat
/// (`rides/{rideId}/messages`) and the driver's number for the call button.
///
/// Messages are never edited or deleted, so administrators can review them if
/// a passenger or driver reports a problem. Enforced in firestore.rules.
class RideContactService {
  RideContactService()
    : _firestore = FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Mirrored in firestore.rules.
  static const int maxMessageLength = 500;

  /// One-tap replies so drivers don't have to type while driving.
  static const List<String> driverQuickReplies = [
    'On my way',
    "I'm at the pickup point",
    'Running a few minutes late',
    'Where exactly are you?',
  ];

  static const List<String> passengerQuickReplies = [
    "I'm at the pickup point",
    "Please wait, I'm coming",
    'Where are you now?',
    'Okay, thank you!',
  ];

  CollectionReference<Map<String, dynamic>> _messages(String rideId) =>
      _firestore.collection('rides').doc(rideId).collection('messages');

  /// The ride's messages, oldest first.
  Stream<List<RideChatMessage>> watchMessages(String rideId) {
    return _messages(rideId)
        .orderBy('createdAt')
        .limitToLast(200)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map(RideChatMessage.fromFirestore).toList(),
        );
  }

  /// Sends [text] as [senderRole] ('passenger' or 'driver'). Only allowed
  /// while the driver is on the way (ride status 'accepted').
  Future<void> sendMessage(
    String rideId, {
    required String senderRole,
    required String text,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw StateError('Sign in again to send messages.');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > maxMessageLength) {
      throw StateError(
        'Messages can be up to $maxMessageLength characters long.',
      );
    }
    try {
      await _messages(rideId).add({
        'senderId': userId,
        'senderRole': senderRole,
        'text': trimmed,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw StateError(
        error.code == 'permission-denied'
            ? 'Chat is closed for this ride.'
            : 'Could not send the message (${error.code}).',
      );
    }
  }

  /// The assigned driver's phone number. Passengers can read it while the
  /// driver is on the way or the trip is in progress.
  Future<String?> fetchDriverPhone(String driverId) async {
    final doc = await _firestore.collection('users').doc(driverId).get();
    final phone = doc.data()?['phone'];
    return phone is String && phone.trim().isNotEmpty ? phone.trim() : null;
  }

  String _lastReadKey(String rideId) =>
      'ride_chat_last_read_${_auth.currentUser?.uid}_$rideId';

  /// When this device last showed the other person's messages for [rideId].
  Future<DateTime?> lastReadAt(String rideId) async {
    final preferences = await SharedPreferences.getInstance();
    final millis = preferences.getInt(_lastReadKey(rideId));
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> markRead(String rideId, DateTime readAt) async {
    final preferences = await SharedPreferences.getInstance();
    final key = _lastReadKey(rideId);
    final current = preferences.getInt(key);
    final millis = readAt.millisecondsSinceEpoch;
    if (current == null || millis > current) {
      await preferences.setInt(key, millis);
    }
  }
}
