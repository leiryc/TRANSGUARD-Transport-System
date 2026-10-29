import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return const FirebaseOptions(
        apiKey: 'AIzaSyBeIredi2T3n1qm7GXaW3dhwW4ygYoS7nI',
        appId: '1:537582635604:web:954141065377189ff53bc1',
        messagingSenderId: '537582635604',
        projectId: 'capstone-9e2bc',
        authDomain: 'capstone-9e2bc.firebaseapp.com',
        storageBucket: 'capstone-9e2bc.firebasestorage.app',
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return const FirebaseOptions(
          apiKey: 'AIzaSyBeIredi2T3n1qm7GXaW3dhwW4ygYoS7nI',
          appId: '1:537582635604:android:954141065377189ff53bc1',
          messagingSenderId: '537582635604',
          projectId: 'capstone-9e2bc',
          storageBucket: 'capstone-9e2bc.firebasestorage.app',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }
}
