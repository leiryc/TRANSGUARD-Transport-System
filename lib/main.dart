import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'models/user_model.dart';
import 'services/auth_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/passenger/passenger_home_screen.dart';
import 'screens/passenger/rate_ride_screen.dart';
import 'screens/driver/driver_home_screen.dart';
import 'screens/passenger/ride_tracking_screen.dart';
import 'screens/driver/driver_tracking_screen.dart';
import 'screens/driver/driver_approval_screen.dart';
import 'screens/admin/admin_dashboard_screen.dart';

final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: const [SystemUiOverlay.bottom],
  );

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('stay_signed_in') == false) {
      await FirebaseAuth.instance.signOut();
    }
  } catch (e) {
    debugPrint('Firebase initialization skipped: $e');
  }

  if (!kDebugMode &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: const AndroidPlayIntegrityProvider(),
        providerApple: const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
    } on FirebaseException catch (error) {
      debugPrint('Firebase App Check activation failed: $error');
    }
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [Provider<AuthService>(create: (_) => AuthService())],
      child: MaterialApp(
        scaffoldMessengerKey: _scaffoldMessengerKey,
        debugShowCheckedModeBanner: false,
        title: 'TRANSGUARD',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF168A5B),
            primary: const Color(0xFF168A5B),
            secondary: const Color(0xFF55B88A),
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xFFF5F8F6),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF5F8F6),
            foregroundColor: Color(0xFF17352A),
            elevation: 0,
            centerTitle: false,
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFE6EEE9)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF7F9F8),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE1EAE5)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE1EAE5)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: Color(0xFF168A5B),
                width: 1.5,
              ),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF168A5B),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          useMaterial3: true,
        ),
        home: const AuthWrapper(),
        routes: {
          '/login': (context) => LoginScreen(),
          '/passenger_home': (context) => PassengerHomeScreen(),
          '/driver_home': (context) => const AuthWrapper(),
          '/driver_approval': (context) => const DriverApprovalScreen(),
          '/admin_home': (context) => const AdminDashboardScreen(),
          '/ride_tracking': (context) {
            final rideId =
                (ModalRoute.of(context)?.settings.arguments as String?) ?? '';
            return RideTrackingScreen(rideId: rideId);
          },
          '/rate_ride': (context) {
            final rideId =
                (ModalRoute.of(context)?.settings.arguments as String?) ?? '';
            return RateRideScreen(rideId: rideId);
          },
          '/driver_tracking': (context) {
            final rideId =
                (ModalRoute.of(context)?.settings.arguments as String?) ?? '';
            return DriverTrackingScreen(rideId: rideId);
          },
        },
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context, listen: false);
    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingScreen();
        }
        final user = snapshot.data;
        if (user == null) return LoginScreen();
        return StreamBuilder<UserModel?>(
          stream: authService.watchUserProfile(user.uid),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Text(
                    'Could not load your account profile: '
                    '${profileSnapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!profileSnapshot.hasData) return const _AuthLoadingScreen();
            final profile = profileSnapshot.data;
            if (profile == null) return LoginScreen();
            switch (profile.userType) {
              case 'admin':
                return const AdminDashboardScreen();
              case 'driver':
                return profile.isApproved
                    ? DriverHomeScreen()
                    : const DriverApprovalScreen();
              default:
                return PassengerHomeScreen();
            }
          },
        );
      },
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('TRANSGUARD'),
          ],
        ),
      ),
    );
  }
}
