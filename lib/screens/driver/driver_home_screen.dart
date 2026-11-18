import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/location_service.dart';
import '../../services/payment_service.dart';
import '../../services/ride_service.dart';
import '../../services/security_audit_service.dart';
import '../../models/ride_model.dart';
import '../../widgets/verified_passenger_badge.dart';
import '../assistant_chat_screen.dart';
import '../profile_screen.dart';
import 'driver_wallet_screen.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with WidgetsBindingObserver {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dropoffOrange = Color(0xFFE58A3A);
  static const Color _dangerRed = Color(0xFFD64545);
  static const Color _infoBlue = Color(0xFF3D7EDB);
  static const double _pickupDispatchRadiusMeters = 5000;

  final RideService _rideService = RideService();
  final LocationService _locationService = LocationService();
  final SecurityAuditService _securityAuditService = SecurityAuditService();
  StreamSubscription<Position>? _presenceSubscription;
  StreamSubscription<List<RideModel>>? _rideAlertsSubscription;
  Timer? _presenceHeartbeat;
  Set<String> _knownRequestIds = {};
  bool _hasLoadedRequests = false;
  LatLng? _driverCoordinates;
  Position? _lastPresencePosition;
  bool _isOnline = false;
  bool _isChangingAvailability = false;
  bool _isRideSheetCollapsed = false;
  double _rideSheetDragDistance = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _securityAuditService.inspectDriverDevice();
    _rideAlertsSubscription = _rideService.getAvailableRides().listen(
      (rides) {
        final currentIds = rides.map((ride) => ride.id).toSet();
        if (_hasLoadedRequests && _isOnline && mounted) {
          final newRide = rides.where(
            (ride) => !_knownRequestIds.contains(ride.id) && !ride.isFromCache,
          );
          if (newRide.isNotEmpty) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text('A new passenger ride request is available.'),
                ),
              );
          }
        }
        _knownRequestIds = currentIds;
        _hasLoadedRequests = true;
      },
      onError: (Object error) {
        debugPrint('Ride request alerts unavailable: $error');
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _goOnline();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPresenceUpdates();
    _rideAlertsSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _isOnline) {
      _goOffline(showErrors: false);
    } else if (state == AppLifecycleState.resumed && !_isOnline) {
      _goOnline();
    }
  }

  Future<void> _goOnline() async {
    if (_isChangingAvailability || _isOnline) return;

    setState(() => _isChangingAvailability = true);
    _lastPresencePosition = null;
    try {
      final position = await _locationService
          .getRequiredCurrentLocation()
          .timeout(const Duration(seconds: 15));
      final suspiciousReason = _locationService.detectSuspiciousDriverPosition(
        position,
      );
      if (suspiciousReason != null) {
        await _reportSuspiciousPosition(suspiciousReason);
        throw StateError(
          '$suspiciousReason Disable mock-location tools and retry with a '
          'fresh GPS fix.',
        );
      }
      final location = LatLng(position.latitude, position.longitude);
      _driverCoordinates = location;
      await _rideService.setDriverAvailability(
        isOnline: true,
        latitude: location.latitude,
        longitude: location.longitude,
        accuracyMeters: position.accuracy,
      );
      _lastPresencePosition = position;
      if (!mounted) return;
      setState(() {
        _isOnline = true;
      });
      _startPresenceUpdates();
    } on LocationAccessException catch (error) {
      if (!mounted) return;
      setState(() => _isChangingAvailability = false);
      await _showLocationAccessDialog(error);
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isChangingAvailability = false);
      await _showLocationAccessDialog(
        const LocationAccessException(
          'TransGuard could not get a GPS fix within 15 seconds. Check that Location is on and allowed for TransGuard, then retry near a window or outdoors.',
          openLocationSettings: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isChangingAvailability = false);
      _showSnackBar('Could not go online: $error', isError: true);
    } finally {
      if (mounted) setState(() => _isChangingAvailability = false);
    }
  }

  Future<void> _showLocationAccessDialog(LocationAccessException error) async {
    final openSettings = error.openLocationSettings || error.openAppSettings;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _dropoffOrange.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.location_off_outlined,
            size: 32,
            color: _dropoffOrange,
          ),
        ),
        title: const Text(
          'Location access needed',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Text(
          '${error.message}\n\nTransGuard needs your location to show your position and nearby passenger pickups.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: TextButton.styleFrom(foregroundColor: _brandDark),
            child: const Text(
              'Not now',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              if (error.openLocationSettings) {
                await Geolocator.openLocationSettings();
              } else if (error.openAppSettings) {
                await Geolocator.openAppSettings();
              } else {
                await _goOnline();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: _brandGreen,
              shape: const StadiumBorder(),
            ),
            child: Text(openSettings ? 'Open settings' : 'Try again'),
          ),
        ],
      ),
    );
  }

  void _startPresenceUpdates() {
    _stopPresenceUpdates();
    _presenceSubscription = _locationService.getLocationUpdates().listen(
      (position) => _publishPresence(position),
      onError: (Object error) {
        if (mounted) {
          _showSnackBar('Location updates stopped: $error', isError: true);
        }
        _goOffline(showErrors: false);
      },
    );
    _presenceHeartbeat = Timer.periodic(const Duration(minutes: 1), (_) async {
      try {
        final position = await _locationService.getRequiredCurrentLocation();
        await _publishPresence(position);
      } catch (error) {
        if (mounted) {
          _showSnackBar(
            'Could not refresh driver location: $error',
            isError: true,
          );
        }
      }
    });
  }

  Future<void> _publishPresence(Position position) async {
    if (!_isOnline) return;
    final suspiciousReason = _locationService.detectSuspiciousDriverPosition(
      position,
      previousPosition: _lastPresencePosition,
    );
    if (suspiciousReason != null) {
      await _reportSuspiciousPosition(suspiciousReason);
      _showSnackBar(
        'Suspicious GPS activity detected. You have been taken offline.',
        isError: true,
      );
      await _goOffline(showErrors: false);
      return;
    }
    try {
      _driverCoordinates = LatLng(position.latitude, position.longitude);
      await _rideService.updateDriverPresence(
        position.latitude,
        position.longitude,
        position.accuracy,
      );
      _lastPresencePosition = position;
      if (mounted) setState(() {});
    } catch (error) {
      if (error is FirebaseException && error.code == 'permission-denied') {
        await _securityAuditService.reportPermissionDenied(
          'driver presence update',
        );
      }
      if (mounted) {
        _showSnackBar(
          'Could not update driver location: $error',
          isError: true,
        );
      }
    }
  }

  Future<void> _reportSuspiciousPosition(String reason) async {
    if (reason.startsWith('The platform marked')) {
      await _securityAuditService.reportMockLocation();
    } else {
      await _securityAuditService.reportEvent('gps_anomaly_detected', reason);
    }
  }

  void _stopPresenceUpdates() {
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    _presenceSubscription?.cancel();
    _presenceSubscription = null;
  }

  Future<void> _goOffline({bool showErrors = true}) async {
    if (_isChangingAvailability && showErrors) return;
    _stopPresenceUpdates();
    _lastPresencePosition = null;
    if (mounted) {
      setState(() {
        _isOnline = false;
        _isChangingAvailability = true;
      });
    }
    try {
      await _rideService.setDriverAvailability(isOnline: false);
    } catch (error) {
      if (showErrors && mounted) {
        _showSnackBar('Could not update availability: $error', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isChangingAvailability = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: _dangerRed, size: 22),
            SizedBox(width: 10),
            Text('Sign out?', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        content: const Text(
          'You will go offline and stop receiving ride requests. Are you sure you want to sign out?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: _brandDark),
            child: const Text(
              'Cancel',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _dangerRed),
            child: const Text(
              'Sign out',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    final authService = Provider.of<AuthService>(context, listen: false);
    await _goOffline(showErrors: false);
    await authService.signout();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _acceptRide(RideModel ride) async {
    try {
      final distanceMeters = _distanceToPickupMeters(ride);
      if (distanceMeters == null ||
          distanceMeters > _pickupDispatchRadiusMeters) {
        _showSnackBar(
          'This pickup is outside the 5 km dispatch radius.',
          isError: true,
        );
        return;
      }
      await _rideService.acceptRide(ride.id);
      if (!mounted) return;
      _stopPresenceUpdates();
      setState(() => _isOnline = false);
      await Navigator.of(context)
          .pushNamed('/driver_tracking', arguments: ride.id);
      if (mounted) await _goOnline();
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('Could not accept ride: $error', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: isError ? _dangerRed : _brandDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F8),
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(authService),
      body: _buildOnlineMap(),
    );
  }

  PreferredSizeWidget _buildAppBar(AuthService authService) {
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 12,
      title: _buildBrandChip(),
      actions: [_buildActionGroup(authService), const SizedBox(width: 10)],
    );
  }

  Widget _buildBrandChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1AA36B), _brandGreen],
              ),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.shield_outlined,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          const Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TRANSGUARD',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0.6,
                    color: _brandDark,
                    height: 1.1,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Driver',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: Colors.black54,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionGroup(AuthService authService) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildGroupedAction(
            tooltip: 'Ask TRANSGUARD Help',
            icon: Icons.help_outline_rounded,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AssistantChatScreen(userRole: 'driver'),
              ),
            ),
            isFirst: true,
          ),
          _buildDivider(),
          _buildGroupedAction(
            tooltip: 'My profile',
            icon: Icons.account_circle_outlined,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
          _buildDivider(),
          _buildGroupedAction(
            tooltip: 'Driver ledger',
            icon: Icons.account_balance_wallet_outlined,
            onPressed: authService.currentUser == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverWalletScreen(
                        driverId: authService.currentUser!.uid,
                      ),
                    ),
                  ),
          ),
          _buildDivider(),
          _buildGroupedAction(
            tooltip: 'More options',
            icon: Icons.more_horiz_rounded,
            onPressed: _showOverflowMenu,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 20,
      color: Colors.black.withValues(alpha: 0.06),
    );
  }

  Widget _buildGroupedAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(isFirst ? 22 : 0),
            right: Radius.circular(isLast ? 22 : 0),
          ),
        ),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 42,
            height: 44,
            child: Icon(
              icon,
              size: 20,
              color: enabled ? _brandDark : Colors.black26,
            ),
          ),
        ),
      ),
    );
  }

  void _showOverflowMenu() {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.topRight(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        PopupMenuItem<String>(
          value: 'profile',
          child: Row(
            children: [
              const Icon(
                Icons.account_circle_outlined,
                size: 20,
                color: _brandDark,
              ),
              const SizedBox(width: 12),
              Text(
                'My profile',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _brandDark,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              const Icon(Icons.logout_rounded, size: 20, color: _dangerRed),
              const SizedBox(width: 12),
              Text(
                'Sign out',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _dangerRed,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (!mounted) return;
      if (value == 'profile') {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
      } else if (value == 'logout') {
        _logout();
      }
    });
  }

  Widget _buildOnlineMap() {
    final driverPosition =
        _driverCoordinates ??
        const LatLng(
          LocationService.serviceAreaCenterLatitude,
          LocationService.serviceAreaCenterLongitude,
        );

    return StreamBuilder<List<RideModel>>(
      stream: _rideService.getAvailableRides(),
      builder: (context, snapshot) {
        final allRides = snapshot.data ?? const <RideModel>[];
        final rides = allRides.where((ride) {
          final distance = _distanceToPickupMeters(ride);
          return distance != null && distance <= _pickupDispatchRadiusMeters;
        }).toList();
        final markers = <Marker>{
          Marker(
            markerId: const MarkerId('driver-location'),
            position: driverPosition,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            infoWindow: const InfoWindow(title: 'Your location'),
          ),
          for (final ride in rides)
            Marker(
              markerId: MarkerId('passenger-${ride.id}'),
              position: LatLng(ride.pickupLat, ride.pickupLng),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
              infoWindow: InfoWindow(
                title: 'Passenger pickup',
                snippet: ride.pickupLocation,
              ),
            ),
        };

        final driverId = Provider.of<AuthService>(
          context,
          listen: false,
        ).currentUser?.uid;

        return StreamBuilder<RideModel?>(
          stream: driverId == null
              ? const Stream<RideModel?>.empty()
              : _rideService.getDriverCurrentRide(driverId),
          builder: (context, activeRideSnapshot) {
            final activeRide = activeRideSnapshot.data;
            return Stack(
              children: [
                Positioned.fill(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: driverPosition,
                      zoom: 14,
                    ),
                    markers: markers,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                  ),
                ),
                if (activeRide == null)
                  _buildStatusBanner(
                    rides,
                    hasRequestsOutsideRadius:
                        allRides.isNotEmpty && rides.isEmpty,
                  )
                else
                  _buildActiveRideBanner(activeRide),
                _buildRideRequestsSheet(
                  snapshot,
                  rides,
                  hasRequestsOutsideRadius:
                      allRides.isNotEmpty && rides.isEmpty,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildActiveRideBanner(RideModel ride) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        elevation: 5,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () =>
              Navigator.of(context)
                  .pushNamed('/driver_tracking', arguments: ride.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.directions_bike_rounded,
                    color: _brandGreen,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Active ride',
                            style: TextStyle(
                              color: _brandDark,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          if (ride.passengerIdVerified) ...[
                            const SizedBox(width: 8),
                            const Flexible(child: VerifiedPassengerBadge()),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ride.status == 'accepted'
                            ? 'Accepted · tap to resume or cancel'
                            : 'In progress · tap to continue',
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: _brandGreen),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double? _distanceToPickupMeters(RideModel ride) {
    final driverPosition = _driverCoordinates;
    if (driverPosition == null) return null;
    return Geolocator.distanceBetween(
      driverPosition.latitude,
      driverPosition.longitude,
      ride.pickupLat,
      ride.pickupLng,
    );
  }

  Widget _buildStatusBanner(
    List<RideModel> rides, {
    required bool hasRequestsOutsideRadius,
  }) {
    final Color bannerColor;
    final IconData bannerIcon;
    final String bannerText;

    if (_isChangingAvailability) {
      bannerColor = _infoBlue;
      bannerIcon = Icons.sync_rounded;
      bannerText = 'Getting your location…';
    } else if (!_isOnline) {
      bannerColor = _dropoffOrange;
      bannerIcon = Icons.location_off_outlined;
      bannerText = 'Offline · Tap Go online to retry';
    } else if (rides.isEmpty && hasRequestsOutsideRadius) {
      bannerColor = _infoBlue;
      bannerIcon = Icons.near_me_outlined;
      bannerText = 'Ride requests are outside your 5 km dispatch radius';
    } else if (rides.isEmpty) {
      bannerColor = _brandGreen;
      bannerIcon = Icons.wifi_tethering_rounded;
      bannerText = 'You are online · Waiting for ride requests';
    } else {
      bannerColor = _brandGreen;
      bannerIcon = Icons.directions_car_filled_rounded;
      bannerText =
          '${rides.length} passenger ${rides.length == 1 ? 'pickup' : 'pickups'} nearby';
    }

    return Positioned(
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: bannerColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: bannerColor.withValues(alpha: 0.4),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(bannerIcon, size: 16, color: bannerColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bannerText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: _brandDark,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRideRequestsSheet(
    AsyncSnapshot<List<RideModel>> snapshot,
    List<RideModel> rides, {
    required bool hasRequestsOutsideRadius,
  }) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.42,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _isRideSheetCollapsed = !_isRideSheetCollapsed,
                ),
                onVerticalDragStart: (_) => _rideSheetDragDistance = 0,
                onVerticalDragUpdate: (details) {
                  _rideSheetDragDistance += details.primaryDelta ?? 0;
                },
                onVerticalDragEnd: (details) {
                  final distance = _rideSheetDragDistance;
                  _rideSheetDragDistance = 0;
                  final velocity = details.primaryVelocity ?? 0;
                  if (distance.abs() > 20) {
                    setState(() => _isRideSheetCollapsed = distance > 0);
                  } else if (velocity.abs() >= 150) {
                    setState(() => _isRideSheetCollapsed = velocity > 0);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD9E2DC),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      if (_isRideSheetCollapsed) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Nearby ride requests (${rides.length}) · Tap or swipe up',
                          style: const TextStyle(
                            color: _brandDark,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_isRideSheetCollapsed)
                snapshot.hasError
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: _dangerRed,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Could not load ride requests: ${snapshot.error}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                            if (!_isOnline) ...[
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: _buildGoOnlineButton(),
                              ),
                            ],
                          ],
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: _brandGreen.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.list_alt_rounded,
                                    size: 18,
                                    color: _brandGreen,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Nearby ride requests',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      color: _brandDark,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                                if (!_isOnline) _buildGoOnlineButton(),
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting)
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _brandGreen,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (rides.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              child: Column(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: _brandGreen.withValues(
                                        alpha: 0.08,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.hourglass_empty_rounded,
                                      color: _brandGreen,
                                      size: 26,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    hasRequestsOutsideRadius
                                        ? 'No pickups within 5 km'
                                        : 'No ride requests yet',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: _brandDark,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    hasRequestsOutsideRadius
                                        ? 'Farther requests are hidden. Nearby pickups will appear here.'
                                        : 'Passenger pickup locations will appear here.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.black54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Flexible(
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                shrinkWrap: true,
                                itemCount: rides.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final ride = rides[index];
                                  return _buildRideCard(
                                    ride,
                                    _distanceToPickupMeters(ride)! / 1000,
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoOnlineButton() {
    return FilledButton.icon(
      onPressed: _isChangingAvailability ? null : _goOnline,
      icon: _isChangingAvailability
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.wifi_tethering_rounded, size: 18),
      label: Text(_isChangingAvailability ? 'Connecting…' : 'Go online'),
      style: FilledButton.styleFrom(
        backgroundColor: _brandGreen,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildRideCard(RideModel ride, double pickupDistanceKm) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F8),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6EEE9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.trip_origin,
                  size: 18,
                  color: _brandGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pickup',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ride.pickupLocation,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: _brandDark,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${pickupDistanceKm.toStringAsFixed(1)} km away',
                      style: const TextStyle(
                        color: _brandGreen,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (ride.passengerIdVerified) ...[
                      const SizedBox(height: 6),
                      const VerifiedPassengerBadge(),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  PaymentService().formatPrice(ride.estimatedPrice),
                  style: const TextStyle(
                    color: _brandGreen,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(width: 4),
              Container(
                width: 2,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFFD9E2DC),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 34),
              Expanded(
                child: Text(
                  'To ${ride.dropoffLocation}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: () => _acceptRide(ride),
              style: ElevatedButton.styleFrom(
                backgroundColor: _brandGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0.3,
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Accept ride'),
                  SizedBox(width: 6),
                  Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
