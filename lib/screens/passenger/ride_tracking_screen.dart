import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../../services/payment_service.dart';
import '../../services/road_routing_service.dart';
import '../../services/ride_service.dart';
import '../../models/ride_model.dart';
import '../../widgets/ride_contact_actions.dart';

class RideTrackingScreen extends StatefulWidget {
  final String rideId;

  const RideTrackingScreen({super.key, required this.rideId});

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen> {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dropoffOrange = Color(0xFFE58A3A);
  static const Color _dangerRed = Color(0xFFB93838);
  static const Color _infoBlue = Color(0xFF3D7EDB);

  final RideService _rideService = RideService();
  final RoadRoutingService _roadRoutingService = RoadRoutingService();
  StreamSubscription<RideModel?>? _statusSubscription;
  String? _tripRouteRideId;
  List<LatLng> _tripRoutePoints = const [];
  String? _tripRouteError;
  bool _isLoadingTripRoute = false;
  int _tripRouteRequestVersion = 0;
  LatLng? _driverRouteOrigin;
  LatLng? _driverRouteDestination;
  List<LatLng> _driverRoutePoints = const [];
  String? _driverRouteError;
  bool _isLoadingDriverRoute = false;
  int _driverRouteRequestVersion = 0;
  GoogleMapController? _trackingMapController;
  bool _hasFittedDriverRoute = false;
  String? _lastRideStatus;
  Timer? _noDriverPromptTimer;
  bool _hasShownNoDriverPrompt = false;
  double _animationProgress = 0;
  bool _isCancelling = false;
  bool _hasCancelledRide = false;

  @override
  void initState() {
    super.initState();
    _startAnimation();
    _statusSubscription = _rideService.watchRide(widget.rideId).listen((ride) {
      if (!mounted || ride == null) return;
      unawaited(_loadTripRoute(ride));
      unawaited(_loadDriverRoute(ride));
      final previousStatus = _lastRideStatus;
      _lastRideStatus = ride.status;
      if (previousStatus != ride.status) {
        setState(() {});
      }
      if (ride.status == 'requested') {
        _scheduleNoDriverPrompt(ride);
      } else {
        _noDriverPromptTimer?.cancel();
        _noDriverPromptTimer = null;
      }
      if (previousStatus == null || previousStatus == ride.status) return;
      final message = switch (ride.status) {
        'accepted' => 'A driver accepted your ride.',
        'in_progress' => 'Your trip has started.',
        'completed' => 'Your ride is complete.',
        'cancelled' => 'Your ride was cancelled.',
        _ => 'Your ride status changed.',
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    _noDriverPromptTimer?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _scheduleNoDriverPrompt(RideModel ride) {
    if (_hasShownNoDriverPrompt ||
        _noDriverPromptTimer != null ||
        ride.isFromCache) {
      return;
    }

    final elapsed = DateTime.now().difference(ride.createdAt);
    final remaining = const Duration(minutes: 2) - elapsed;
    _noDriverPromptTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _noDriverPromptTimer = null;
        unawaited(_showNoDriverPrompt(ride));
      },
    );
  }

  Future<void> _showNoDriverPrompt(RideModel ride) async {
    if (!mounted ||
        _hasShownNoDriverPrompt ||
        _lastRideStatus != 'requested' ||
        _isCancelling) {
      return;
    }
    _hasShownNoDriverPrompt = true;
    final keepSearching = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(
          Icons.person_search_rounded,
          color: _dropoffOrange,
          size: 34,
        ),
        title: const Text(
          'No driver has accepted yet',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'There may not be an available driver online nearby yet. Would you '
          'like to keep searching? Your current request will stay active.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(foregroundColor: _dangerRed),
            child: const Text('Cancel ride'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: _brandGreen,
              shape: const StadiumBorder(),
            ),
            child: const Text('Keep searching'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (keepSearching == false) {
      await _cancelRide(ride);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Your ride request is still active. Keep searching…'),
          ),
        );
    }
  }

  void _startAnimation() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() => _animationProgress = 1);
      }
    });
  }

  Future<void> _loadTripRoute(RideModel ride, {bool force = false}) async {
    if (!mounted ||
        ![
          'requested',
          'accepted',
          'in_progress',
          'completed',
        ].contains(ride.status)) {
      return;
    }
    if (!force && _tripRouteRideId == ride.id && _tripRoutePoints.isNotEmpty) {
      return;
    }

    final requestVersion = ++_tripRouteRequestVersion;
    setState(() {
      _tripRouteRideId = ride.id;
      _tripRoutePoints = const [];
      _tripRouteError = null;
      _isLoadingTripRoute = true;
    });
    try {
      final route = await _roadRoutingService.getRoute(
        pickup: LatLng(ride.pickupLat, ride.pickupLng),
        dropoff: LatLng(ride.dropoffLat, ride.dropoffLng),
      );
      if (!mounted || requestVersion != _tripRouteRequestVersion) return;
      setState(() {
        _tripRoutePoints = route.points;
        _isLoadingTripRoute = false;
      });
    } catch (error) {
      debugPrint('Could not load passenger trip road route: $error');
      if (!mounted || requestVersion != _tripRouteRequestVersion) return;
      setState(() {
        _tripRouteError =
            'Road route is unavailable. Check your connection and retry.';
        _isLoadingTripRoute = false;
      });
    }
  }

  Future<void> _loadDriverRoute(RideModel ride, {bool force = false}) async {
    if (!['accepted', 'in_progress'].contains(ride.status) ||
        ride.driverLat == null ||
        ride.driverLng == null) {
      if (_driverRoutePoints.isNotEmpty ||
          _isLoadingDriverRoute ||
          _driverRouteError != null ||
          _driverRouteOrigin != null) {
        ++_driverRouteRequestVersion;
        setState(() {
          _driverRouteOrigin = null;
          _driverRouteDestination = null;
          _driverRoutePoints = const [];
          _driverRouteError = null;
          _isLoadingDriverRoute = false;
          _hasFittedDriverRoute = false;
        });
      }
      return;
    }

    final origin = LatLng(ride.driverLat!, ride.driverLng!);
    final destination = ride.status == 'accepted'
        ? LatLng(ride.pickupLat, ride.pickupLng)
        : LatLng(ride.dropoffLat, ride.dropoffLng);
    final previousOrigin = _driverRouteOrigin;
    final movedMeters = previousOrigin == null
        ? double.infinity
        : Geolocator.distanceBetween(
            previousOrigin.latitude,
            previousOrigin.longitude,
            origin.latitude,
            origin.longitude,
          );
    final previousDestination = _driverRouteDestination;
    final destinationMovedMeters = previousDestination == null
        ? double.infinity
        : Geolocator.distanceBetween(
            previousDestination.latitude,
            previousDestination.longitude,
            destination.latitude,
            destination.longitude,
          );
    if (!force &&
        movedMeters < 200 &&
        destinationMovedMeters < 5 &&
        (_driverRoutePoints.isNotEmpty ||
            _isLoadingDriverRoute ||
            _driverRouteError != null)) {
      return;
    }

    final requestVersion = ++_driverRouteRequestVersion;
    setState(() {
      _driverRouteOrigin = origin;
      _driverRouteDestination = destination;
      _driverRoutePoints = const [];
      _driverRouteError = null;
      _isLoadingDriverRoute = true;
      if (destinationMovedMeters >= 5) _hasFittedDriverRoute = false;
    });
    try {
      final route = await _roadRoutingService.getRoute(
        pickup: origin,
        dropoff: destination,
      );
      if (!mounted || requestVersion != _driverRouteRequestVersion) {
        return;
      }
      setState(() {
        _driverRoutePoints = route.points;
        _isLoadingDriverRoute = false;
      });
      if (!_hasFittedDriverRoute) {
        _fitMapToRoute(route.points);
        _hasFittedDriverRoute = true;
      }
    } catch (error) {
      debugPrint('Could not load the driver road route: $error');
      if (!mounted || requestVersion != _driverRouteRequestVersion) {
        return;
      }
      setState(() {
        _driverRouteError =
            'Could not load the driver route. Check connection and retry.';
        _isLoadingDriverRoute = false;
      });
    }
  }

  void _fitMapToRoute(List<LatLng> points) {
    final controller = _trackingMapController;
    if (controller == null || points.isEmpty) return;

    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points.skip(1)) {
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }
    if (south == north) {
      south -= 0.0001;
      north += 0.0001;
    }
    if (west == east) {
      west -= 0.0001;
      east += 0.0001;
    }
    unawaited(
      controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(south, west),
            northeast: LatLng(north, east),
          ),
          40,
        ),
      ),
    );
  }

  String _getStatusMessage(String status) {
    switch (status) {
      case 'requested':
        return 'Finding your driver';
      case 'accepted':
        return 'Driver is on the way';
      case 'in_progress':
        return 'Ride in progress';
      case 'completed':
        return 'Ride completed';
      case 'cancelled':
        return 'Ride cancelled';
      default:
        return '';
    }
  }

  String _getStatusSubtitle(String status) {
    switch (status) {
      case 'requested':
        return 'Looking for an available driver nearby';
      case 'accepted':
        return 'Your driver is heading to the pickup point';
      case 'in_progress':
        return 'Enjoy your trip — you\'re on your way';
      case 'completed':
        return 'Thanks for riding with TRANSGUARD';
      case 'cancelled':
        return 'This ride has been cancelled';
      default:
        return '';
    }
  }

  IconData _getStatusIconData(String status) {
    switch (status) {
      case 'requested':
        return Icons.search_rounded;
      case 'accepted':
        return Icons.person_pin_circle_rounded;
      case 'in_progress':
        return Icons.navigation_rounded;
      case 'completed':
        return Icons.check_circle_rounded;
      case 'cancelled':
        return Icons.cancel_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'requested':
        return _dropoffOrange;
      case 'accepted':
        return _infoBlue;
      case 'in_progress':
        return _brandGreen;
      case 'completed':
        return _brandGreen;
      case 'cancelled':
        return _dangerRed;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _hasCancelledRide || _lastRideStatus == 'cancelled',
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F9F8),
        appBar: _buildAppBar(),
        body: StreamBuilder<RideModel?>(
          stream: _rideService.watchRide(widget.rideId),
          builder: (context, snapshot) {
            if (_isCancelling) {
              return const SizedBox.shrink();
            }

            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: _brandGreen),
              );
            }

            if (!snapshot.hasData || snapshot.data == null) {
              return _buildNotFound();
            }

            final ride = snapshot.data!;

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(
                children: [
                  _buildMapCard(ride),
                  const SizedBox(height: 20),
                  _buildStatusCard(ride),
                  if (_hasCancelledRide || ride.status == 'cancelled') ...[
                    const SizedBox(height: 16),
                    _buildCancellationConfirmationCard(ride),
                  ],
                  if ((ride.status == 'accepted' ||
                          ride.status == 'in_progress') &&
                      ride.driverId != null) ...[
                    const SizedBox(height: 20),
                    _buildDriverCard(ride),
                  ],
                  const SizedBox(height: 20),
                  _buildRideDetailsCard(ride),
                  if (ride.isFromCache) ...[
                    const SizedBox(height: 20),
                    _buildOfflineBanner(),
                  ],
                  if (ride.status == 'accepted' && !ride.isFromCache) ...[
                    const SizedBox(height: 20),
                    _TripQrCard(rideId: ride.id),
                  ],
                  if (!_hasCancelledRide &&
                      !ride.isFromCache &&
                      (ride.status == 'requested' ||
                          ride.status == 'accepted')) ...[
                    const SizedBox(height: 20),
                    _buildCancelButton(ride),
                  ],
                  if (ride.status == 'completed' &&
                      ride.paymentMethod == 'cash') ...[
                    const SizedBox(height: 20),
                    _buildReceiptCard(ride),
                  ],
                  if (!ride.isFromCache && ride.status == 'completed') ...[
                    const SizedBox(height: 20),
                    if (ride.passengerRating == null)
                      _buildRateButton(ride)
                    else
                      _buildRatingSubmittedCard(ride.passengerRating!),
                    const SizedBox(height: 12),
                    _buildBackToHomeButton(),
                  ],
                  if (_hasCancelledRide ||
                      (!ride.isFromCache && ride.status == 'cancelled')) ...[
                    const SizedBox(height: 20),
                    _buildBackToHomeButton(),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      automaticallyImplyLeading: false,
      leading: const SizedBox.shrink(),
      leadingWidth: 0,
      titleSpacing: 20,
      title: const Text(
        'Ride tracking',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: _brandDark,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: _dangerRed.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: _dangerRed,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ride not found',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _brandDark,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'This ride may have been removed or expired.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapCard(RideModel ride) {
    return Container(
      height: 250,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            GoogleMap(
              key: ValueKey('passenger-ride-map-${ride.id}-${ride.status}'),
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<OneSequenceGestureRecognizer>(
                  () => EagerGestureRecognizer(),
                ),
              },
              scrollGesturesEnabled: true,
              zoomGesturesEnabled: true,
              rotateGesturesEnabled: true,
              onMapCreated: (controller) {
                _trackingMapController = controller;
                if (_driverRoutePoints.isNotEmpty && !_hasFittedDriverRoute) {
                  _fitMapToRoute(_driverRoutePoints);
                  _hasFittedDriverRoute = true;
                }
              },
              initialCameraPosition: CameraPosition(
                target: LatLng(ride.pickupLat, ride.pickupLng),
                zoom: 14,
              ),
              markers: {
                if (ride.status == 'requested' || ride.status == 'accepted')
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: LatLng(ride.pickupLat, ride.pickupLng),
                    infoWindow: const InfoWindow(title: 'Pickup'),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueGreen,
                    ),
                  ),
                Marker(
                  markerId: const MarkerId('destination'),
                  position: LatLng(ride.dropoffLat, ride.dropoffLng),
                  infoWindow: const InfoWindow(title: 'Destination'),
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueOrange,
                  ),
                ),
                if (ride.driverLat != null && ride.driverLng != null)
                  Marker(
                    markerId: const MarkerId('driver'),
                    position: LatLng(ride.driverLat!, ride.driverLng!),
                    infoWindow: const InfoWindow(title: 'Driver'),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueAzure,
                    ),
                  ),
              },
              polylines: {
                if (ride.status != 'accepted' &&
                    ride.status != 'in_progress' &&
                    _tripRoutePoints.length >= 2)
                  Polyline(
                    polylineId: const PolylineId('passenger-trip-road'),
                    points: _tripRoutePoints,
                    color: _brandGreen,
                    width: 5,
                  ),
                if (['accepted', 'in_progress'].contains(ride.status) &&
                    _driverRoutePoints.length >= 2)
                  Polyline(
                    polylineId: const PolylineId('live-driver-road-route'),
                    points: _driverRoutePoints,
                    color: _infoBlue,
                    width: 5,
                  ),
              },
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
            ),
            if (['accepted', 'in_progress'].contains(ride.status) &&
                (_isLoadingDriverRoute || _driverRouteError != null))
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: _isLoadingDriverRoute
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _infoBlue,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              ride.status == 'accepted'
                                  ? 'Routing driver to pickup…'
                                  : 'Routing driver to dropoff…',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: _brandDark,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 16,
                              color: _dangerRed,
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              'Driver route unavailable',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: _brandDark,
                              ),
                            ),
                            TextButton(
                              onPressed: () => unawaited(
                                _loadDriverRoute(ride, force: true),
                              ),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                ),
              ),
            if (_isLoadingTripRoute || _tripRouteError != null)
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: _isLoadingTripRoute
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _brandGreen,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Loading road route…',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: _brandDark,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 16,
                              color: _dangerRed,
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              'Road route unavailable',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: _brandDark,
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  unawaited(_loadTripRoute(ride, force: true)),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                ),
              ),
            if (ride.driverLat == null)
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _getStatusColor(ride.status),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        ride.status == 'requested'
                            ? 'Finding a driver'
                            : 'Waiting for driver location',
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
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(RideModel ride) {
    final statusColor = _getStatusColor(ride.status);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _getStatusIconData(ride.status),
              size: 32,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _getStatusMessage(ride.status),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _brandDark,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _getStatusSubtitle(ride.status),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _animationProgress,
              minHeight: 5,
              backgroundColor: statusColor.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRideDetailsCard(RideModel ride) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.receipt_long_outlined,
                    size: 18,
                    color: _brandGreen,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Ride details',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _brandDark,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _buildLocationRow(
              icon: Icons.trip_origin,
              color: _brandGreen,
              label: 'Pickup',
              value: ride.pickupLocation,
            ),
            const SizedBox(height: 14),
            _buildLocationRow(
              icon: Icons.location_on,
              color: _dropoffOrange,
              label: 'Dropoff',
              value: ride.dropoffLocation,
            ),
            const SizedBox(height: 18),
            Divider(
              height: 1,
              thickness: 1,
              color: Colors.black.withValues(alpha: 0.06),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Total fare',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _brandDark,
                    ),
                  ),
                ),
                Text(
                  PaymentService().formatPrice(
                    ride.finalPrice ?? ride.estimatedPrice,
                  ),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _brandGreen,
                    fontSize: 22,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverCard(RideModel ride) {
    final driverName = ride.driverName?.trim();
    final driverProfileStream = driverName == null || driverName.isEmpty
        ? AuthService().watchUserProfile(ride.driverId!)
        : null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StreamBuilder<UserModel?>(
            stream: driverProfileStream,
            builder: (context, snapshot) {
              final profileName = snapshot.data?.name.trim();
              final displayName = driverName?.isNotEmpty == true
                  ? driverName!
                  : profileName?.isNotEmpty == true
                  ? profileName!
                  : 'Driver assigned';
              return Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _brandGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.person_rounded,
                      color: _brandGreen,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your driver',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          displayName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: _brandDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          // Chat and call are available while the driver is on the way.
          if (ride.status == 'accepted') ...[
            const SizedBox(height: 16),
            RideContactActions(
              key: ValueKey('contact_${ride.id}'),
              ride: ride,
              viewerRole: 'passenger',
              otherPartyName: driverName,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLocationRow({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _brandDark,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _dropoffOrange.withValues(alpha: 0.3)),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: _dropoffOrange),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Showing saved ride data offline. Actions are unavailable until you reconnect.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF8A5A20),
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelButton(RideModel ride) {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: _isCancelling ? null : () => _confirmCancel(ride),
        icon: const Icon(Icons.cancel_outlined, size: 18),
        label: const Text(
          'Cancel ride',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: _dangerRed,
          side: const BorderSide(color: _dangerRed, width: 1.5),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }

  Future<void> _confirmCancel(RideModel ride) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Cancel ride?',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Are you sure you want to cancel this ride? You can cancel before the trip starts, even if the driver is on the way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: _brandDark),
            child: const Text(
              'Keep ride',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _dangerRed),
            child: const Text(
              'Cancel ride',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    await _cancelRide(ride);
  }

  Future<void> _cancelRide(RideModel ride) async {
    if (!mounted || _isCancelling) return;
    setState(() => _isCancelling = true);

    final success = await _rideService.cancelRide(ride.id);
    if (!mounted) return;

    if (success) {
      setState(() {
        _isCancelling = false;
        _hasCancelledRide = true;
        _lastRideStatus = 'cancelled';
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Ride cancellation confirmed.')),
        );
    } else {
      // Cancel failed — restore the UI so the user can try again.
      setState(() => _isCancelling = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Could not cancel the ride. Please try again.'),
                ),
              ],
            ),
            backgroundColor: _dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
    }
  }

  Widget _buildCancellationConfirmationCard(RideModel ride) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF6EF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _brandGreen.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_rounded, color: _brandGreen, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cancellation confirmed',
                  style: TextStyle(
                    color: _brandDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'This ride has been cancelled. Keep this ride ID as your confirmation.',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  'Ride ID: ${ride.id}',
                  style: const TextStyle(
                    color: _brandDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptCard(RideModel ride) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.receipt_outlined,
                    size: 18,
                    color: _brandGreen,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Digital ride receipt',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _brandDark,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildReceiptRow('Receipt ID', ride.id),
            _buildReceiptRow(
              'Route',
              '${ride.pickupLocation} → ${ride.dropoffLocation}',
            ),
            if (ride.distance != null)
              _buildReceiptRow(
                'Distance',
                _receiptDistance(ride),
              ),
            _buildReceiptRow(
              'Fare',
              '${PaymentService().formatPrice(ride.finalPrice ?? ride.estimatedPrice)} · Cash',
            ),
            _buildReceiptRow(
              'Cash collection',
              ride.cashCollectedByDriver
                  ? 'Marked received by driver'
                  : 'Unconfirmed',
              valueColor: ride.cashCollectedByDriver
                  ? _brandGreen
                  : _dropoffOrange,
            ),
            _buildReceiptRow(
              'Completed',
              ride.endTime?.toLocal().toString() ?? 'Time unavailable',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _copyReceipt(ride),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text(
                  'Copy receipt',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: _brandGreen,
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor ?? _brandDark,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Current rides store the road-route distance; rides priced with an older
  /// fare basis (or none) used straight-line distance.
  String _receiptDistance(RideModel ride) {
    final km = ride.distance!.toStringAsFixed(2);
    return ride.fareBasis == PaymentService.flatFareBasis
        ? '$km road km'
        : '$km km (straight-line)';
  }

  Future<void> _copyReceipt(RideModel ride) async {
    final receipt = [
      'TRANSGUARD RIDE RECEIPT',
      'Receipt: ${ride.id}',
      'Route: ${ride.pickupLocation} -> ${ride.dropoffLocation}',
      if (ride.distance != null) 'Distance: ${_receiptDistance(ride)}',
      'Fare: ${PaymentService().formatPrice(ride.finalPrice ?? ride.estimatedPrice)}',
      'Payment: Cash; driver confirmation ${ride.cashCollectedByDriver ? 'recorded' : 'not recorded'}',
      'Completed: ${ride.endTime?.toLocal().toString() ?? 'time unavailable'}',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: receipt));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              SizedBox(width: 10),
              Expanded(child: Text('Receipt copied to clipboard')),
            ],
          ),
          backgroundColor: _brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  Widget _buildRateButton(RideModel ride) {
    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: () {
          Navigator.of(context).pushNamed('/rate_ride', arguments: ride.id);
        },
        icon: const Icon(Icons.star_outline_rounded, size: 20),
        label: const Text(
          'Rate your driver',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _brandGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: const StadiumBorder(),
        ),
      ),
    );
  }

  Widget _buildRatingSubmittedCard(double rating) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5EF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_rounded, color: _brandGreen),
          const SizedBox(width: 8),
          Text(
            'You rated your driver ${rating.toStringAsFixed(0)} stars',
            style: const TextStyle(
              color: _brandDark,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackToHomeButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton.icon(
        onPressed: _backToPassengerHome,
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text(
          'Back to home',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: _brandGreen,
          side: const BorderSide(color: _brandGreen),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }

  void _backToPassengerHome() {
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/passenger_home', (route) => false);
  }
}

class _TripQrCard extends StatefulWidget {
  final String rideId;

  const _TripQrCard({required this.rideId});

  @override
  State<_TripQrCard> createState() => _TripQrCardState();
}

class _TripQrCardState extends State<_TripQrCard> {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);

  final RideService _rideService = RideService();
  late Future<String> _code;

  @override
  void initState() {
    super.initState();
    _code = _rideService.issueTripVerificationCode(widget.rideId);
  }

  void _refreshCode() {
    setState(() {
      _code = _rideService.issueTripVerificationCode(widget.rideId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.qr_code_2_rounded,
                    size: 18,
                    color: _brandGreen,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Trip verification QR',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _brandDark,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Show this QR to your driver at pickup',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            FutureBuilder<String>(
              future: _code,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF4E5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.wifi_off_rounded,
                              size: 18,
                              color: Color(0xFFE58A3A),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Could not create the verification code. Connect to the internet and try again.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8A5A20),
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _refreshCode,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try again'),
                        style: TextButton.styleFrom(
                          foregroundColor: _brandGreen,
                        ),
                      ),
                    ],
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(color: _brandGreen),
                  );
                }
                return Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _brandGreen.withValues(alpha: 0.15),
                          width: 2,
                        ),
                      ),
                      child: QrImageView(
                        data: snapshot.data!,
                        version: QrVersions.auto,
                        size: 180,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _brandGreen.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 14,
                            color: _brandGreen,
                          ),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Expires in 5 minutes · single use',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _brandGreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: _refreshCode,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text(
                        'Refresh code',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: TextButton.styleFrom(foregroundColor: _brandGreen),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
