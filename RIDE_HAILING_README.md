# TransGuard - Ride Hailing App

A comprehensive Flutter-based ride-hailing application with Firebase backend, supporting both passenger and driver functionality.

## Features

### 🚗 Passenger Features
- **User Authentication**: Secure login/signup with email
- **Ride Booking**: Request rides with pickup and dropoff locations
- **Road Routing**: Passenger pickup and dropoff selections are connected with a road-following route; displayed road distance drives the fare estimate
- **Location Search**: Auto-detect current location or search for addresses
- **Ride Types**: Choose from Economy, Comfort, and Premium rides
- **Price Estimation**: Real-time price calculation based on distance
- **Ride Tracking**: Live tracking of driver and ride status
- **Ride History**: View completed rides and statistics
- **Rating & Reviews**: Rate drivers and leave feedback after rides
- **Ride Status Updates**: Real-time status notifications (requested, accepted, in-progress, completed)
- **Offline Ride and Profile Cache**: Previously loaded ride and profile details remain available for read-only viewing without a network connection
- **Digital Receipt**: Completed cash-fare details can be viewed and copied from the passenger ride screen
- **Trip Start QR**: A temporary passenger-generated QR is consumed once by the driver's app before the trip starts. It is a coordination feature, not secure identity verification.

### 🚖 Driver Features
- **Driver Authentication**: Secure signup and login
- **Driver Accreditation**: Driver applications require a franchise/permit number and LTO plate number; administrators verify the numbers before approving driver access
- **Approval Monitoring**: Administrators can approve, reject, or revoke driver access and monitor approved drivers as Online, En-Route, In-Transit, or Offline
- **Automatic Driver Availability**: Drivers start sharing their location and appear online when their driver screen opens; they are marked offline when signing out or leaving the app
- **Available Rides**: View all pending ride requests nearby
- **Ride Acceptance**: Accept or decline ride requests
- **Navigation**: Get pickup and dropoff locations
- **Ride Tracking**: Track ride progress with passenger
- **Cash Fare Records**: Review completed rides and driver-confirmed cash fare records
- **Rating & Reviews**: View passenger ratings and reviews
- **Driver Analytics**: Statistics on completed rides and ratings
- **Offline Ride Cache**: Previously loaded ride details remain available for read-only viewing without a network connection
- **Cash Fare Records**: Drivers confirm cash collection at trip completion; the app records the fare without processing or transferring funds
- **Dispatch Queue**: Unmatched passenger requests are listed in request order; online drivers receive an in-app alert while the driver screen is open
- **Driver Request Map**: While online, drivers see a full-screen map with their location and pickup pins for open requests, plus an accept-ride panel
- **Proximity Filtering**: The driver app filters pickup pins and ride offers to a 5 km straight-line radius from the driver's latest GPS location. This is client-side convenience filtering only; it is not server-enforced and can be bypassed by a modified client.
- **Live In-App Ride Alerts**: Firestore listeners update ride status and show alerts while the relevant screen is open. Background push notifications are unavailable without a trusted server sender.
- **Location Sharing**: Driver location is written directly to Firestore during an active ride. Client-reported GPS can be spoofed.
- **Request Ordering**: Requests are displayed oldest-first, but a modified client can bypass FIFO ordering.

### 💰 Fare Records
- **Distance Fare**: ₱15 flat when both stops are within the 1 km town-center radius; otherwise ₱15 + ₱8 per road-route kilometer
- **Admin Demand Outlook**: Reports include a simple historical weekday/hour estimate alongside recent ride volumes; it is not machine-learning forecasting
- **Transaction Audit**: Admin reports summarize daily ride totals and immutable cash-fare ledger allocations; no online payments or transfers are processed
- **Cash Collection**: Driver confirms cash collection when completing a ride
- **Digital Records**: Ride and fare are stored in the ledger; no online payment or fund transfer is processed

### 📍 Location Services
- **GPS Integration**: Real-time location tracking
- **Address Search**: Geocoding for location search
- **Distance Calculation**: Road distance and route geometry from the public OSRM routing service
- **Map Display**: Visual representation of pickup and dropoff

### 🔐 Security
- **Firebase Authentication**: Secure user authentication
- **Firestore Database**: Secure cloud data storage
- **User Roles**: Passenger, driver, and provisioned admin roles
- **Firestore Role Guardrails**: Rules restrict reads and writes by role, ownership, driver approval, ride state, and allowed fields; database writes not explicitly permitted by a rule are denied
- **Security Audit Feed**: The admin dashboard displays recent client-reported App Check token errors, Android root/emulator indicators, mock-location signals, and driver Firestore permission denials
- **Data Encryption**: All sensitive data encrypted in transit

## Project Structure

```
lib/
├── main.dart                          # App entry point
├── models/
│   ├── user_model.dart               # User data model
│   └── ride_model.dart               # Ride data model
├── services/
│   ├── auth_service.dart             # Authentication logic
│   ├── ride_service.dart             # Ride management logic
│   ├── location_service.dart         # Location services
│   └── payment_service.dart          # Payment calculations
└── screens/
    ├── auth/
    │   └── login_screen.dart         # Login/Signup UI
    ├── passenger/
    │   ├── passenger_home_screen.dart # Passenger home
    │   └── ride_tracking_screen.dart # Ride tracking
    └── driver/
        └── driver_home_screen.dart   # Driver home
```

## Installation

### Prerequisites
- Flutter SDK (3.13.2 or higher)
- Dart SDK
- Android Studio or Xcode
- Firebase project account

### Setup Steps

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd ride_hailing_app
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure Firebase**
   - Create a Firebase project at https://console.firebase.google.com
   - Add your Android and iOS apps to the Firebase project
   - Download the configuration files and place them in the appropriate directories
   - Enable Authentication (Email/Password)
   - Enable Firestore Database

4. **Run the app**
   ```bash
   flutter run
   ```

## Dependencies

- **firebase_core**: Firebase core library
- **firebase_auth**: Authentication service
- **cloud_firestore**: Cloud database
- **google_maps_flutter**: Map display
- **geolocator**: Location tracking
- **geocoding**: Address to coordinates conversion
- **provider**: State management
- **stripe_sdk**: Payment processing
- **google_fonts**: Custom fonts

## API Endpoints

### Authentication
- Sign Up: Create new user account
- Sign In: Authenticate existing user
- Sign Out: Logout user

### Rides
- Request Ride: Create new ride request
- Accept Ride: Driver accepts ride
- Cancel Ride: Cancel pending ride
- Complete Ride: Mark ride as complete
- Get Available Rides: List pending rides for driver
- Get Ride History: View user's ride history

### Users
- Get User Profile: Retrieve user data
- Update Profile: Update user information
- Get User Rating: View user's average rating

## Database Schema

### Users Collection
```
{
  id: string (uid)
  name: string
  email: string
  phone: string
  userType: string ('passenger' | 'driver')
  profileImage: string (URL)
  rating: number (0-5)
  totalRides: number
  createdAt: timestamp
  isActive: boolean
}
```

### Rides Collection
```
{
  id: string (auto-generated)
  passengerId: string
  driverId: string (optional)
  pickupLocation: string
  dropoffLocation: string
  pickupLat: number
  pickupLng: number
  dropoffLat: number
  dropoffLng: number
  estimatedPrice: number
  finalPrice: number (optional)
  status: string ('requested' | 'accepted' | 'in_progress' | 'completed' | 'cancelled')
  rideType: string ('economy' | 'comfort' | 'premium')
  createdAt: timestamp
  startTime: timestamp (optional)
  endTime: timestamp (optional)
  passengerRating: number (optional, 0-5)
  driverRating: number (optional, 0-5)
  passengerReview: string (optional)
  driverReview: string (optional)
  distance: number (km)
  duration: number (minutes)
}
```

## Usage

### For Passengers
1. Sign up with email and password
2. Select "Passenger" as user type
3. On home screen, enter pickup and dropoff locations
4. Choose ride type (Economy, Comfort, Premium)
5. View estimated price
6. Click "Request Ride"
7. Wait for driver to accept
8. Track driver's real-time location
9. Complete the ride
10. Rate the driver

### For Drivers
1. Sign up with email and password
2. Select "Driver" as user type
3. Click "Go Online" to receive ride requests
4. Browse available ride requests
5. Accept a ride
6. Navigate to pickup location
7. Pick up passenger
8. Navigate to dropoff location
9. Complete the ride
10. Get rated by passenger

## Features Coming Soon

- [ ] Real-time map tracking with Google Maps
- [ ] In-app messaging between driver and passenger
- [ ] Multiple payment methods
- [ ] Scheduled rides
- [ ] Ride sharing (multiple passengers)
- [ ] Loyalty program
- [ ] Emergency button
- [ ] Driver insurance information
- [ ] Ride cancellation penalties

## Configuration

### Offline Data
Firestore persistence is enabled for local caching. Ride and profile data must be loaded at least once while online to be available offline. Cached data is identified in the UI, and actions that change ride state or profile details are unavailable while displaying cached ride/profile data.

### Stay Signed In
The login screen includes a device-level "Stay signed in" option, enabled by default. If turned off, the account is signed out the next time the app starts; users can still sign out immediately from the app.

### Admin Reports
The admin dashboard reads ride documents directly from Firestore and computes ride counts, recorded cash fares, average completed distance, daily volume, and a simple historical demand estimate on the device. The estimate averages ride counts from comparable UTC weekday/hour buckets; it is not a trained forecasting model. Reports are capped to the latest 1,000 rides across the 35-day read window. Admin access must be provisioned by a trusted project administrator: update the account's `users/{uid}` document so `userType` is `admin` using the Firebase console or Admin SDK. Admin access exposes ride details and must not be granted to passenger or driver clients.

### Transaction Audit and Fare Allocation
Ride completion writes its cash-fare record atomically with the completed ride to `wallet_ledger/{rideId}`. Firestore rules allow the assigned approved driver to create the record only as part of completing that ride and reject later updates or deletion; administrators can read ledger entries for reporting. The admin report aggregates up to the latest 1,000 ledger records across 35 days into UTC daily ride counts, completed cash fares, and allocations.

The current fare is ₱15 when both pickup and dropoff are within the 1 km radius around the San Francisco town center; if either stop is outside that zone, the fare is ₱15 plus ₱8 per road-route kilometer for the full route, rounded to cents. This is the app's configured formula, not a verified or certified MTFRB municipal fare matrix. Passenger pickup and dropoff coordinates are sent to the public OSRM routing service (`router.project-osrm.org`) to retrieve route geometry and distance. Its public service is rate-limited and has no app-specific availability guarantee; if routing is unavailable, a ride cannot be requested until a route is returned. The displayed route is an estimate and does not include live traffic. The recorded split allocates the full cash fare to the driver and ₱0 to the cooperative. These are bookkeeping allocations only: the driver records cash collected directly, and the app does not process, hold, transfer, or settle funds. Firestore immutability prevents post-write edits but cannot make a client-submitted cash collection independently verified or eliminate tampering by a modified client.

### Driver Accreditation
Driver signup stores franchise and plate numbers in the driver's Firestore profile. Administrators review those numbers in the admin dashboard, then approve or reject applications; approved drivers can be monitored and later revoked. Approval changes are observed live by the driver app, and active rides prevent revocation. This numbers-only workflow does not upload or store photos and does not require Firebase Storage. Legacy driver profiles without approval data are treated as unapproved; administrators should verify their permit and plate details before approving them.

Deploy `firestore.rules` before using registration and approval features. This client-side application gate works with Firebase Authentication and Firestore; it does not change the Firebase Auth account's disabled/enabled state.

### Trip Verification and Location Checks
Trip QR tokens are generated and stored by the passenger app in Firestore, expire after five minutes in normal app use, and are consumed once by the assigned driver's app. Firestore rules require a live token before a ride can start, but clients can inspect or imitate client-side data; this QR is not proof of identity or a tamper-resistant security control. Driver GPS is likewise client-reported.

### Free-Plan Security Monitoring Limits
The security feed is best-effort client telemetry, not a trusted security audit. Firebase App Check uses Play Integrity on Android and App Attest/device-check fallback on iOS in release builds, but the app cannot read Firebase's server-side enforcement verdicts or Cloud Logging records on Spark. An App Check token retrieval error is reported as a client observation; it does not prove that Firebase rejected or failed hardware attestation. Configure App Check enforcement in Firebase Console separately if server-side request rejection is required.

Android checks for a small set of root and emulator indicators; Geolocator's mock-position signal is checked before drivers go online and while they share location. These checks are heuristic, can be bypassed or produce false positives, and do not detect every rooted, jailbroken, emulator, or fake-GPS setup. iOS jailbreak heuristics and authoritative device integrity verification are not included. Drivers can submit misleading client events, so administrators must verify before revoking approval. App Check and Firestore Rules use Firebase's available free quotas; this implementation adds no paid backend service and stores no security-event photos or secrets.

### App Check and Push Notifications
The app configures Firebase App Check on supported mobile platforms. Register the debug token in Firebase App Check for development, and register the Android app's Play Integrity settings and iOS app's App Attest settings before release. Cloud Messaging background push notifications are not configured in the Spark-plan client-only design.

### Free Spark Plan Limitations
Driver online presence, passenger ride requests, driver acceptance, passenger cancellation, active-ride GPS updates, QR trip start, ride completion, and cash ledger recording use direct Firestore operations under restrictive security rules. Deploy the updated Firestore rules and indexes before using these flows. Booking, proximity filtering, fare calculation, QR issuance, and cash collection are client-driven; they are not tamper-proof or financially authoritative. In-app ride alerts require the app to be open and connected.

Admin reports are computed on the device from Firestore data and require the admin role to be provisioned by a trusted administrator. Direct Firestore location updates cannot provide server-side movement plausibility checks, and client-reported GPS may be spoofed. Reliable background notifications, server-verified matching/fare calculation, and fraud-resistant trip/payment verification require a trusted backend; those are intentionally not provided on Spark.

### Firebase Configuration
Create a `firebase_config.dart` file in `lib/` with your Firebase credentials:

```dart
import 'package:firebase_core/firebase_core.dart';

class FirebaseConfig {
  static const firebaseOptions = FirebaseOptions(
    apiKey: 'YOUR_API_KEY',
    appId: 'YOUR_APP_ID',
    messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    storageBucket: 'YOUR_STORAGE_BUCKET',
  );
}
```

## Testing

```bash
# Run all tests
flutter test

# Run tests with coverage
flutter test --coverage
```

## Troubleshooting

### Firebase Initialization Issues
- Ensure Firebase project is properly created
- Check that configuration files are in correct locations
- Verify Firebase services are enabled in console

### Location Permission Issues
- Grant location permissions in app settings
- Ensure device has GPS enabled
- Check platform-specific location permissions

### Build Issues
```bash
flutter clean
flutter pub get
flutter pub upgrade
flutter run
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see LICENSE file for details.

## Support

For support, email support@ridehub.com or open an issue on GitHub.

## Authors

- Development Team

## Acknowledgments

- Flutter community
- Firebase documentation
- Google Maps Platform
- All contributors and testers
