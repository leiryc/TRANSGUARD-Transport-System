import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SecurityAuditService {
  SecurityAuditService()
    : _firestore = FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

  static const MethodChannel _deviceChannel = MethodChannel(
    'transguard/security',
  );
  static final Set<String> _reportedThisSession = {};

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  Stream<List<Map<String, dynamic>>> watchEvents() {
    return _firestore
        .collection('security_events')
        .orderBy('occurredAt', descending: true)
        .limit(100)
        .snapshots(includeMetadataChanges: true)
        .map(
          (snapshot) => snapshot.docs
              .map((document) => {'id': document.id, ...document.data()})
              .toList(),
        );
  }

  Future<void> inspectDriverDevice() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      final signals = await _deviceChannel.invokeMapMethod<String, bool>(
        'getDeviceSignals',
      );
      if (signals?['rootIndicator'] == true) {
        await reportEvent(
          'root_indicator_detected',
          'Android device matched a local root indicator.',
        );
      }
      if (signals?['emulatorIndicator'] == true) {
        await reportEvent(
          'emulator_indicator_detected',
          'Android device matched a local emulator indicator.',
        );
      }
    } on MissingPluginException {
      // Native device indicators are implemented only for Android.
    } on PlatformException catch (error) {
      debugPrint('Could not inspect local device signals: $error');
    }

    try {
      final token = await FirebaseAppCheck.instance.getToken();
      if (token == null || token.isEmpty) {
        await reportEvent(
          'app_check_token_unavailable',
          'The client could not obtain an App Check token.',
        );
      }
    } on FirebaseException catch (error) {
      await reportEvent(
        'app_check_token_unavailable',
        'App Check token request failed (${error.code}).',
      );
    } on PlatformException catch (error) {
      await reportEvent(
        'app_check_token_unavailable',
        'App Check token request failed (${error.code}).',
      );
    }
  }

  Future<void> reportMockLocation() => reportEvent(
    'mock_location_detected',
    'The platform location provider marked this position as mocked.',
  );

  Future<void> reportPermissionDenied(String operation) => reportEvent(
    'firestore_permission_denied',
    'A driver operation was rejected by Firestore rules: $operation.',
  );

  Future<void> reportEvent(String eventType, String details) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final dedupeKey = '${user.uid}:$eventType';
    if (!_reportedThisSession.add(dedupeKey)) return;

    try {
      await _firestore.collection('security_events').add({
        'actorUid': user.uid,
        'eventType': eventType,
        'source': 'client',
        'details': details,
        'occurredAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      _reportedThisSession.remove(dedupeKey);
      debugPrint('Could not save client-reported security event: $error');
    }
  }
}
