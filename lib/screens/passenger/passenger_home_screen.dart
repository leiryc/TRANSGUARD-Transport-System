import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/ride_service.dart';
import '../../services/location_service.dart';
import '../../services/payment_service.dart';
import '../../services/road_routing_service.dart';
import '../../models/ride_model.dart';
import '../assistant_chat_screen.dart';
import '../profile_screen.dart';

class PassengerHomeScreen extends StatefulWidget {
  const PassengerHomeScreen({super.key});

  @override
  State<PassengerHomeScreen> createState() => _PassengerHomeScreenState();
}

class _PassengerHomeScreenState extends State<PassengerHomeScreen> {
  static const LatLng _defaultMapCenter = LatLng(
    LocationService.serviceAreaCenterLatitude,
    LocationService.serviceAreaCenterLongitude,
  );
  static const double _innerRideRadiusMeters = 1000;

  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dropoffOrange = Color(0xFFE58A3A);
  static const Color _dangerRed = Color(0xFFD64545);

  final RideService _rideService = RideService();
  final RoadRoutingService _roadRoutingService = RoadRoutingService();
  late TextEditingController _pickupController;
  late TextEditingController _dropoffController;
  final LocationService _locationService = LocationService();
  LatLng? _pickupCoordinates;
  LatLng? _dropoffCoordinates;
  bool _selectingPickup = true;
  double? _estimatedPrice;
  double? _routeDistanceKm;
  bool _isFlatFareZone = false;
  List<LatLng> _routePoints = const [];
  String? _routeError;
  bool _isLoadingRoute = false;
  int _routeRequestVersion = 0;
  bool _isRequestingRide = false;
  bool _isRideSheetCollapsed = false;
  double _rideSheetDragDistance = 0;

  @override
  void initState() {
    super.initState();
    _pickupController = TextEditingController();
    _dropoffController = TextEditingController();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _updateRoadRoute() async {
    final pickupCoordinates = _pickupCoordinates;
    final dropoffCoordinates = _dropoffCoordinates;
    final requestVersion = ++_routeRequestVersion;
    if (pickupCoordinates == null || dropoffCoordinates == null) {
      setState(() {
        _routePoints = const [];
        _routeDistanceKm = null;
        _isFlatFareZone = false;
        _estimatedPrice = null;
        _routeError = null;
        _isLoadingRoute = false;
      });
      return;
    }

    setState(() {
      _routePoints = const [];
      _routeDistanceKm = null;
      _isFlatFareZone = false;
      _estimatedPrice = null;
      _routeError = null;
      _isLoadingRoute = true;
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted || requestVersion != _routeRequestVersion) return;

    try {
      final route = await _roadRoutingService.getRoute(
        pickup: pickupCoordinates,
        dropoff: dropoffCoordinates,
      );
      if (!mounted || requestVersion != _routeRequestVersion) return;
      final isFlatFareZone = PaymentService().isWithinFlatFareZone(
        pickupLatitude: pickupCoordinates.latitude,
        pickupLongitude: pickupCoordinates.longitude,
        dropoffLatitude: dropoffCoordinates.latitude,
        dropoffLongitude: dropoffCoordinates.longitude,
      );
      setState(() {
        _routePoints = route.points;
        _routeDistanceKm = route.distanceKm;
        _isFlatFareZone = isFlatFareZone;
        _estimatedPrice = PaymentService().calculateRidePrice(
          route.distanceKm,
          pickupLatitude: pickupCoordinates.latitude,
          pickupLongitude: pickupCoordinates.longitude,
          dropoffLatitude: dropoffCoordinates.latitude,
          dropoffLongitude: dropoffCoordinates.longitude,
        );
        _isLoadingRoute = false;
      });
    } catch (error) {
      debugPrint('Could not load road route: $error');
      if (!mounted || requestVersion != _routeRequestVersion) return;
      setState(() {
        _routeError =
            'Could not load a road route. Check your connection and retry.';
        _isLoadingRoute = false;
      });
    }
  }

  Future<void> _selectMapPoint(LatLng position) async {
    final isPickup = _selectingPickup;
    setState(() {
      if (isPickup) {
        _pickupCoordinates = position;
        _pickupController.text =
            '(${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
      } else {
        _dropoffCoordinates = position;
        _dropoffController.text =
            '(${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
      }
    });
    unawaited(_updateRoadRoute());

    final address = await _locationService.getAddressFromCoordinates(
      position.latitude,
      position.longitude,
    );
    if (!mounted || address == null) return;

    setState(() {
      if (isPickup && _pickupCoordinates == position) {
        _pickupController.text = address;
      } else if (!isPickup && _dropoffCoordinates == position) {
        _dropoffController.text = address;
      }
    });
  }

  Future<void> _requestRide() async {
    final pickupLocation = _pickupController.text;
    final dropoffLocation = _dropoffController.text;
    final pickupCoordinates = _pickupCoordinates;
    final dropoffCoordinates = _dropoffCoordinates;
    final estimatedDistanceKm = _routeDistanceKm;

    if (pickupLocation.isEmpty ||
        dropoffLocation.isEmpty ||
        pickupCoordinates == null ||
        dropoffCoordinates == null) {
      _showSnackBar('Select both pickup and destination on the map');
      return;
    }
    if (_isLoadingRoute) {
      _showSnackBar('Wait for the road route to finish loading.');
      return;
    }
    if (estimatedDistanceKm == null || _routePoints.isEmpty) {
      _showSnackBar(
        _routeError ?? 'A road route is required before requesting a ride.',
      );
      return;
    }
    if (!_locationService.isWithinPickupServiceArea(
      pickupCoordinates.latitude,
      pickupCoordinates.longitude,
    )) {
      _showSnackBar('Pickup must be within 5 km of San Francisco town center.');
      return;
    }

    setState(() => _isRequestingRide = true);
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final user = await authService.getCurrentUserData();
      if (user == null) {
        throw StateError('Sign in again before requesting a ride.');
      }
      await authService.ensurePublicName(userId: user.id, name: user.name);

      final estimatedPrice = PaymentService().calculateRidePrice(
        estimatedDistanceKm,
        pickupLatitude: pickupCoordinates.latitude,
        pickupLongitude: pickupCoordinates.longitude,
        dropoffLatitude: dropoffCoordinates.latitude,
        dropoffLongitude: dropoffCoordinates.longitude,
      );
      final ride = RideModel(
        id: '',
        passengerId: user.id,
        pickupLocation: pickupLocation,
        dropoffLocation: dropoffLocation,
        pickupLat: pickupCoordinates.latitude,
        pickupLng: pickupCoordinates.longitude,
        dropoffLat: dropoffCoordinates.latitude,
        dropoffLng: dropoffCoordinates.longitude,
        estimatedPrice: estimatedPrice,
        distance: estimatedDistanceKm,
        createdAt: DateTime.now(),
        passengerIdVerified: user.isIdVerified,
      );

      final result = await _rideService.requestRide(ride);
      if (!mounted) return;
      if (result == null) {
        _showSnackBar('No active tricycle found within 5 km. Try again later.');
        return;
      }
      setState(() => _estimatedPrice = result.estimatedPrice);
      Navigator.of(context).pushNamed('/ride_tracking', arguments: result.id);
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not request a ride: $error');
      }
    } finally {
      if (mounted) setState(() => _isRequestingRide = false);
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
          'Are you sure you want to sign out of your TRANSGUARD account?',
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
    await authService.signout();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  Future<void> _cancelRide(RideModel ride) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel ride?'),
        content: const Text(
          'You can cancel before the trip starts, even if the driver is on the way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep ride'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _dangerRed),
            child: const Text('Cancel ride'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final cancelled = await _rideService.cancelRide(ride.id);
    if (!mounted) return;
    _showSnackBar(
      cancelled ? 'Ride cancelled.' : 'Could not cancel. The trip may have started or the ride may already be cancelled.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          Positioned.fill(child: _buildMap()),
          _buildPassengerRideOverlay(),
          _buildBottomSheet(),
        ],
      ),
    );
  }

  Widget _buildPassengerRideOverlay() {
    final passengerId = context.read<AuthService>().currentUser?.uid;
    if (passengerId == null) return _buildStepBanner();

    return StreamBuilder<RideModel?>(
      stream: _rideService.getPassengerCurrentRide(passengerId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              elevation: 5,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: _dangerRed),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Unable to check your ride status. Check your connection.',
                        style: TextStyle(color: _brandDark, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final ride = snapshot.data;
        if (ride == null) return _buildStepBanner();

        final canCancel =
            ride.status == 'requested' || ride.status == 'accepted';
        return Positioned(
          top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          left: 16,
          right: 16,
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            elevation: 5,
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
                    child: InkWell(
                      onTap: () =>
                          Navigator.of(context)
                              .pushNamed('/ride_tracking', arguments: ride.id),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Active ride',
                            style: TextStyle(
                              color: _brandDark,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            ride.status == 'requested'
                                ? 'Waiting for a driver · tap to view'
                                : ride.driverName?.trim().isNotEmpty == true
                                ? 'Driver: ${ride.driverName} · tap to track'
                                : ride.status == 'accepted'
                                ? 'Driver assigned · tap to track'
                                : 'Ride in progress · tap to track',
                            style: const TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (canCancel)
                    TextButton(
                      onPressed: () => _cancelRide(ride),
                      style: TextButton.styleFrom(
                        foregroundColor: _dangerRed,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('Cancel'),
                    )
                  else
                    IconButton(
                      tooltip: 'Track ride',
                      onPressed: () =>
                          Navigator.of(context)
                              .pushNamed('/ride_tracking', arguments: ride.id),
                      icon: const Icon(
                        Icons.chevron_right_rounded,
                        color: _brandGreen,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 16,
      title: _buildBrandChip(),
      actions: [_buildActionGroup(), const SizedBox(width: 16)],
    );
  }

  Widget _buildBrandChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1AA36B), _brandGreen],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.shield_outlined,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'TRANSGUARD',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  letterSpacing: 0.8,
                  color: _brandDark,
                  height: 1.1,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Passenger',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: Colors.black54,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionGroup() {
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
                builder: (_) =>
                    const AssistantChatScreen(userRole: 'passenger'),
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
    required VoidCallback onPressed,
    bool isFirst = false,
    bool isLast = false,
  }) {
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
            width: 48,
            height: 44,
            child: Icon(icon, size: 20, color: _brandDark),
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
              const Text(
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
              const Text(
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

  Widget _buildMap() {
    return GoogleMap(
      initialCameraPosition: const CameraPosition(
        target: _defaultMapCenter,
        zoom: 14,
      ),
      onTap: _isRequestingRide ? null : _selectMapPoint,
      circles: {
        Circle(
          circleId: const CircleId('pickup-service-area'),
          center: _defaultMapCenter,
          radius: LocationService.serviceAreaRadiusMeters,
          fillColor: _brandGreen.withValues(alpha: 0.12),
          strokeColor: _brandGreen,
          strokeWidth: 2,
        ),
        Circle(
          circleId: const CircleId('inner-ride-radius'),
          center: _defaultMapCenter,
          radius: _innerRideRadiusMeters,
          fillColor: Colors.transparent,
          strokeColor: _dropoffOrange,
          strokeWidth: 3,
        ),
      },
      markers: {
        if (_pickupCoordinates case final position?)
          Marker(
            markerId: const MarkerId('pickup'),
            position: position,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            infoWindow: const InfoWindow(title: 'Pickup'),
          ),
        if (_dropoffCoordinates case final position?)
          Marker(
            markerId: const MarkerId('dropoff'),
            position: position,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            infoWindow: const InfoWindow(title: 'Dropoff'),
          ),
      },
      polylines: _routePoints.length >= 2
          ? {
              Polyline(
                polylineId: const PolylineId('trip'),
                points: _routePoints,
                color: _brandGreen,
                width: 4,
              ),
            }
          : const {},
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
    );
  }

  Widget _buildStepBanner() {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: DecoratedBox(
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStepDots(),
                  const SizedBox(width: 10),
                  Text(
                    _selectingPickup
                        ? 'Tap the map to set pickup'
                        : 'Tap the map to set dropoff',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: _brandDark,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDot(active: _selectingPickup),
        const SizedBox(width: 4),
        _buildDot(active: !_selectingPickup),
      ],
    );
  }

  Widget _buildDot({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: active ? 20 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active ? _brandGreen : const Color(0xFFD9E2DC),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildBottomSheet() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0xFFD9E2DC),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        if (_isRideSheetCollapsed) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Plan your ride · Tap or swipe up to expand',
                            style: TextStyle(
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
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  child: _isRideSheetCollapsed
                      ? const SizedBox(width: double.infinity)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Plan your ride',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: _brandDark,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Choose a stop below, then tap anywhere on the map',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildModeSelector(),
                            const SizedBox(height: 16),
                            _LocationSummary(
                              icon: Icons.trip_origin,
                              color: _brandGreen,
                              label: 'Pickup',
                              value: _pickupController.text,
                              isActive: _selectingPickup,
                              onTap: () =>
                                  setState(() => _selectingPickup = true),
                            ),
                            const SizedBox(height: 10),
                            _LocationSummary(
                              icon: Icons.location_on,
                              color: _dropoffOrange,
                              label: 'Dropoff',
                              value: _dropoffController.text,
                              isActive: !_selectingPickup,
                              onTap: () =>
                                  setState(() => _selectingPickup = false),
                            ),
                            if (_isLoadingRoute) ...[
                              const SizedBox(height: 12),
                              const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _brandGreen,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Finding the road route…',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_routeError != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _routeError!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: _dangerRed,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        unawaited(_updateRoadRoute()),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ] else if (_routeDistanceKm != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                _isFlatFareZone
                                    ? 'Both stops are inside 1 km · flat ₱15 fare'
                                    : 'Outside the 1 km zone · ${_routeDistanceKm!.toStringAsFixed(2)} road km',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _brandDark,
                                ),
                              ),
                            ],
                            if (_estimatedPrice != null) ...[
                              const SizedBox(height: 14),
                              _buildFareCard(),
                            ],
                            const SizedBox(height: 14),
                            _buildRequestButton(),
                            const SizedBox(height: 8),
                            const Text(
                              'Road route estimates by OpenStreetMap/OSRM · Pickup within 5 km service area',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildModeButton(
              label: 'Pickup',
              icon: Icons.trip_origin,
              isSelected: _selectingPickup,
              onTap: () => setState(() => _selectingPickup = true),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _buildModeButton(
              label: 'Dropoff',
              icon: Icons.location_on,
              isSelected: !_selectingPickup,
              onTap: () => setState(() => _selectingPickup = false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? _brandGreen : Colors.black54,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? _brandDark : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFareCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _brandGreen.withValues(alpha: 0.08),
            _brandGreen.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _brandGreen.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _brandGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.receipt_long_outlined,
              color: _brandGreen,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isFlatFareZone
                  ? 'Flat-zone fare'
                  : 'Estimated road-distance fare',
              style: TextStyle(fontWeight: FontWeight.w600, color: _brandDark),
            ),
          ),
          Text(
            PaymentService().formatPrice(_estimatedPrice!),
            style: const TextStyle(
              color: _brandGreen,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestButton() {
    return SizedBox(
      height: 54,
      child: ElevatedButton(
        onPressed:
            _isRequestingRide || _isLoadingRoute || _routeDistanceKm == null
            ? null
            : _requestRide,
        style: ElevatedButton.styleFrom(
          backgroundColor: _brandGreen,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _brandGreen.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white,
          shape: const StadiumBorder(),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        child: _isRequestingRide
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Find a ride'),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded, size: 20),
                ],
              ),
      ),
    );
  }
}

class _LocationSummary extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final bool isActive;
  final VoidCallback? onTap;

  const _LocationSummary({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.isActive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isActive
                ? color.withValues(alpha: 0.06)
                : const Color(0xFFF7F9F8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? color.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: _PassengerHomeScreenState._brandDark,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasValue ? value : 'Tap the map to select',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasValue ? Colors.black87 : Colors.black45,
                        fontSize: 13,
                        fontWeight: hasValue
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasValue) Icon(Icons.check_circle, color: color, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
