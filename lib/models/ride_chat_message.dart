import 'package:cloud_firestore/cloud_firestore.dart';

/// A message in a ride's passenger-driver chat (`rides/{rideId}/messages`).
class RideChatMessage {
  const RideChatMessage({
    required this.id,
    required this.senderId,
    required this.senderRole,
    required this.text,
    this.createdAt,
    this.isPending = false,
  });

  final String id;
  final String senderId;

  /// 'passenger' or 'driver'.
  final String senderRole;
  final String text;

  /// Null until the server has confirmed the message.
  final DateTime? createdAt;

  /// True while the message is still being sent from this device.
  final bool isPending;

  factory RideChatMessage.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final createdAt = data['createdAt'];
    return RideChatMessage(
      id: doc.id,
      senderId: data['senderId'] as String? ?? '',
      senderRole: data['senderRole'] as String? ?? '',
      text: data['text'] as String? ?? '',
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
      isPending: doc.metadata.hasPendingWrites,
    );
  }
}
