import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../models/ride_model.dart';
import '../../services/auth_service.dart';
import '../../services/location_service.dart';
import '../../services/payment_service.dart';
import '../../services/road_routing_service.dart';
import '../../services/ride_service.dart';
import '../../services/security_audit_service.dart';
import '../../widgets/ride_contact_actions.dart';
import '../../widgets/verified_passenger_badge.dart';

class DriverTrackingScreen extends StatefulWidget {
  final String rideId;

  const DriverTrackingScreen({super.key, required this.rideId});

  @override
  State<DriverTrackingScreen> createState() => _DriverTrackingScreenState();
}

class _DriverTrackingScreenState extends State<DriverTrackingScreen> {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dropoffOrange = Color(0xFFE58A3A);
  static const Color _dangerRed = Color(0xFFD64545);

  final _rideService = RideService();
  final _locationService = LocationService();
  final _roadRoutingService = RoadRoutingService();
  final _securityAuditService = SecurityAuditService();
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<RideModel?>? _statusSubscription;
  Timer? _locationHeartbeat;
  LatLng? _driverPosition;
  Position? _lastTrackedPosition;
  RideModel? _currentRide;
  String? _passengerNameStreamUserId;
  Stream<String?>? _passengerNameStream;
  LatLng? _pickupRouteOrigin;
  LatLng? _pickupRouteDestination;
  String? _pickupRouteRideId;
  List<LatLng> _pickupRoutePoints = const [];
  String? _pickupRouteError;
  int _pickupRouteRequestVersion = 0;
  bool _isLoadingPickupRoute = false;
  String? _driverId;
  String? _locationError;
  bool _isSharing = false;
  bool _isUpdatingStatus = false;
  String? _lastLocationError;

  @override
  void initState() {
    super.initState();
    _statusSubscription = _rideService
        .watchRide(widget.rideId)
        .listen(
          (ride) {
            if (ride != null) {
              _currentRide = ride;
              unawaited(_updatePickupRoute(ride));
            } else {
              _currentRide = null;
            }
            if (ride == null ||
                !['accepted', 'in_progress'].contains(ride.status)) {
              _stopSharing();
            } else if (!_isSharing) {
              _startSharing();
            }
          },
          onError: (Object error) {
            if (mounted) {
              setState(
                () => _locationError = 'Could not read this ride: $error',
              );
            }
          },
        );
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _locationHeartbeat?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startSharing() async {
    if (_isSharing) return;
    setState(() {
      _isSharing = true;
      _locationError = null;
    });
    _lastTrackedPosition = null;

    try {
      final driver = await context.read<AuthService>().getCurrentUserData();
      if (!mounted) return;
      if (driver == null || driver.userType != 'driver') {
        throw StateError(
          'A driver account is required to share this location.',
        );
      }
      _driverId = driver.id;

      final firstPosition = await _locationService.getRequiredCurrentLocation();
      if (!mounted) return;
      final suspiciousReason = _locationService.detectSuspiciousDriverPosition(
        firstPosition,
      );
      if (suspiciousReason != null) {
        await _reportSuspiciousPosition(suspiciousReason);
        throw StateError(
          'Suspicious GPS activity detected. Location sharing has been stopped.',
        );
      }
      await _publishLocation(firstPosition);

      _locationSubscription = _locationService.getLocationUpdates().listen(
        (position) => _publishLocation(position),
        onError: (Object error) {
          if (mounted) {
            setState(() {
              _locationError = error.toString();
              _isSharing = false;
            });
          }
        },
      );
      _locationHeartbeat?.cancel();
      _locationHeartbeat = Timer.periodic(const Duration(minutes: 1), (
        _,
      ) async {
        try {
          final position = await _locationService.getRequiredCurrentLocation();
          await _publishLocation(position);
        } catch (error) {
          if (mounted) {
            setState(() => _locationError = error.toString());
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSharing = false;
        _locationError = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _publishLocation(Position position) async {
    final driverId = _driverId;
    if (driverId == null) return;
    final suspiciousReason = _locationService.detectSuspiciousDriverPosition(
      position,
      previousPosition: _lastTrackedPosition,
    );
    if (suspiciousReason != null) {
      await _reportSuspiciousPosition(suspiciousReason);
      await _stopSharing();
      if (mounted) {
        setState(() {
          _locationError = 'Suspicious GPS activity detected. Location sharing has been stopped.';
        });
      }
      return;
    }
    final location = LatLng(position.latitude, position.longitude);
    if (mounted) setState(() => _driverPosition = location);
    final currentRide = _currentRide;
    if (currentRide != null) {
      unawaited(_updatePickupRoute(currentRide));
    }
    try {
      await _rideService.updateDriverLocation(
        widget.rideId,
        location.latitude,
        location.longitude,
        position.accuracy,
      );
      _lastTrackedPosition = position;
      if (_lastLocationError != null && mounted) {
        setState(() => _lastLocationError = null);
      }
    } catch (error) {
      if (error is FirebaseException && error.code == 'permission-denied') {
        await _securityAuditService.reportPermissionDenied(
          'active ride location update',
        );
      }
      if (mounted) {
        setState(() => _lastLocationError = error.toString());
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

  Future<void> _stopSharing() async {
    await _locationSubscription?.cancel();
    _locationSubscription = null;
    _locationHeartbeat?.cancel();
    _locationHeartbeat = null;
    if (mounted && _isSharing) {
      setState(() => _isSharing = false);
    }
  }

  Future<void> _updatePickupRoute(RideModel ride, {bool force = false}) async {
    if (!mounted) return;
    if (ride.status != 'accepted' && ride.status != 'in_progress') {
      if (_pickupRouteRideId != null ||
          _pickupRoutePoints.isNotEmpty ||
          _isLoadingPickupRoute) {
        ++_pickupRouteRequestVersion;
        setState(() {
          _pickupRouteRideId = null;
          _pickupRouteOrigin = null;
          _pickupRouteDestination = null;
          _pickupRoutePoints = const [];
          _pickupRouteError = null;
          _isLoadingPickupRoute = false;
        });
      }
      return;
    }

    final origin = _driverPosition;
    if (origin == null) return;
    final destination = ride.status == 'accepted'
        ? LatLng(ride.pickupLat, ride.pickupLng)
        : LatLng(ride.dropoffLat, ride.dropoffLng);

    final movedMeters = _pickupRouteOrigin == null
        ? double.infinity
        : Geolocator.distanceBetween(
            _pickupRouteOrigin!.latitude,
            _pickupRouteOrigin!.longitude,
            origin.latitude,
            origin.longitude,
          );
    final destinationMovedMeters = _pickupRouteDestination == null
        ? double.infinity
        : Geolocator.distanceBetween(
            _pickupRouteDestination!.latitude,
            _pickupRouteDestination!.longitude,
            destination.latitude,
            destination.longitude,
          );
    if (!force &&
        _pickupRouteRideId == ride.id &&
        movedMeters < 250 &&
        destinationMovedMeters < 5 &&
        (_pickupRoutePoints.isNotEmpty ||
            _isLoadingPickupRoute ||
            _pickupRouteError != null)) {
      return;
    }

    final requestVersion = ++_pickupRouteRequestVersion;
    setState(() {
      _pickupRouteRideId = ride.id;
      _pickupRouteOrigin = origin;
      _pickupRouteDestination = destination;
      _pickupRoutePoints = const [];
      _pickupRouteError = null;
      _isLoadingPickupRoute = true;
    });

    try {
      final route = await _roadRoutingService.getRoute(
        pickup: origin,
        dropoff: destination,
      );
      if (!mounted || requestVersion != _pickupRouteRequestVersion) return;
      setState(() {
        _pickupRoutePoints = route.points;
        _isLoadingPickupRoute = false;
      });
    } catch (error) {
      debugPrint('Could not load active ride road route: $error');
      if (!mounted || requestVersion != _pickupRouteRequestVersion) return;
      setState(() {
        _pickupRouteError = error.toString().replaceFirst('Bad state: ', '');
        _isLoadingPickupRoute = false;
      });
    }
  }

  Future<void> _verifyPassengerQr() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        bool handled = false;
        return StatefulBuilder(
          builder: (context, setState) {
            final sheetNavigator = Navigator.of(context);
            return SizedBox(
              height: 560,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
                    const SizedBox(height: 16),
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
                            Icons.qr_code_scanner_rounded,
                            size: 18,
                            color: _brandGreen,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Scan passenger QR',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: _brandDark,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.04,
                            ),
                            shape: const CircleBorder(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Scan the QR shown on the passenger app to verify the trip and begin pickup.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F4F2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _brandGreen.withValues(alpha: 0.15),
                            width: 2,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: MobileScanner(
                            controller: MobileScannerController(
                              formats: [BarcodeFormat.qrCode],
                            ),
                            onDetect: (capture) async {
                              if (handled) return;
                              final rawCode =
                                  capture.barcodes.firstOrNull?.rawValue;
                              if (rawCode == null) return;
                              handled = true;

                              final verified = await _rideService
                                  .validatePassengerTripQr(
                                    rideId: widget.rideId,
                                    scannedCode: rawCode,
                                  );

                              if (!mounted || !context.mounted) return;
                              sheetNavigator.pop();

                              if (verified) {
                                scaffoldMessenger
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
                                          Expanded(
                                            child: Text(
                                              'Passenger verified. Trip started.',
                                            ),
                                          ),
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
                                return;
                              }

                              scaffoldMessenger
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
                                          child: Text(
                                            'Trip verification failed. Check the QR and your pickup location, then try again.',
                                          ),
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
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _changeRideStatus({
    required String nextStatus,
    required Future<bool> Function() updateStatus,
  }) async {
    setState(() => _isUpdatingStatus = true);
    try {
      final success = await updateStatus();
      if (!mounted) return;
      if (!success) {
        _showSnackBar('Could not update the ride status.', isError: true);
        return;
      }
      if (nextStatus == 'completed') {
        await _stopSharing();
      }
    } on FirebaseException catch (error) {
      if (!mounted) return;
      final message = error.code == 'permission-denied'
          ? 'Could not record the cash fare: Firestore denied the update. '
                'Deploy the latest Firestore rules and try again.'
          : 'Could not update the ride (${error.code}). Please try again.';
      _showSnackBar(message, isError: true);
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('Could not update the ride: $error', isError: true);
    } finally {
      if (mounted) setState(() => _isUpdatingStatus = false);
    }
  }

  Future<bool> _confirmCashFareAndComplete(RideModel ride) async {
    final collected = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _brandGreen.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.payments_outlined,
            size: 32,
            color: _brandGreen,
          ),
        ),
        title: const Text(
          'Record cash fare',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Confirm that you received ${PaymentService().formatPrice(ride.finalPrice ?? ride.estimatedPrice)} in cash from the passenger.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(foregroundColor: _brandDark),
            child: const Text(
              'Not received',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: _brandGreen,
              shape: const StadiumBorder(),
            ),
            child: const Text('Cash received'),
          ),
        ],
      ),
    );
    if (collected != true || !mounted) return false;
    await _changeRideStatus(
      nextStatus: 'completed',
      updateStatus: () => _rideService.completeRide(ride.id),
    );
    return true;
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

  Set<Marker> _markers(RideModel ride) {
    final markers = <Marker>{
      if (ride.status != 'in_progress')
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
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ),
    };
    final driverPosition = _driverPosition;
    if (driverPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('driver'),
          position: driverPosition,
          infoWindow: const InfoWindow(title: 'Your location'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F8),
      appBar: _buildAppBar(),
      body: StreamBuilder<RideModel?>(
        stream: _rideService.watchRide(widget.rideId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: _brandGreen),
            );
          }
          if (snapshot.hasError) {
            return _buildErrorState('Could not load ride: ${snapshot.error}');
          }
          final ride = snapshot.data;
          if (ride == null) {
            return _buildErrorState('Ride not found.');
          }
          if (ride.status == 'completed') {
            return _buildRideCompletedState(ride);
          }

          return Column(
            children: [
              Expanded(child: _buildMap(ride)),
              _buildActionsPanel(ride),
            ],
          );
        },
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
      titleSpacing: 4,
      title: const Text(
        'Active ride',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: _brandDark,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildErrorState(String message) {
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
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _brandDark,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRideCompletedState(RideModel ride) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: _brandGreen.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: _brandGreen,
                size: 58,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'Ride complete!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _brandDark,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Fare received: ${PaymentService().formatPrice(ride.finalPrice ?? ride.estimatedPrice)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _brandGreen,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamedAndRemoveUntil('/driver_home', (_) => false),
                icon: const Icon(Icons.home_outlined),
                label: const Text(
                  'Back home',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _brandGreen,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap(RideModel ride) {
    return Stack(
      children: [
        Positioned.fill(
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _driverPosition ?? LatLng(ride.pickupLat, ride.pickupLng),
              zoom: 14,
            ),
            markers: _markers(ride),
            polylines:
                (ride.status == 'accepted' || ride.status == 'in_progress') &&
                    _pickupRoutePoints.length >= 2
                ? {
                    Polyline(
                      polylineId: const PolylineId('driver-active-ride-route'),
                      points: _pickupRoutePoints,
                      color: _brandGreen,
                      width: 5,
                    ),
                  }
                : const {},
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: true,
          ),
        ),
        _buildStatusBanner(ride),
      ],
    );
  }

  Widget _buildStatusBanner(RideModel ride) {
    final Color bannerColor;
    final IconData bannerIcon;
    final String bannerText;

    if (_locationError != null) {
      bannerColor = _dangerRed;
      bannerIcon = Icons.error_outline_rounded;
      bannerText = _locationError!;
    } else if (_isSharing) {
      bannerColor = _brandGreen;
      bannerIcon = Icons.wifi_tethering_rounded;
      bannerText = 'Sharing live location';
    } else {
      bannerColor = _dropoffOrange;
      bannerIcon = Icons.location_searching_rounded;
      bannerText = 'Waiting for location permission';
    }

    return Positioned(
      top: 12,
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

  Widget _buildActionsPanel(RideModel ride) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
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
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
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
              const SizedBox(height: 16),
              _buildRideSummaryCard(ride),
              if ((ride.status == 'accepted' || ride.status == 'in_progress') &&
                  (_isLoadingPickupRoute || _pickupRouteError != null)) ...[
                const SizedBox(height: 12),
                if (_isLoadingPickupRoute)
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _brandGreen,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          ride.status == 'accepted'
                              ? 'Finding road route to passenger pickup…'
                              : 'Finding road route to destination…',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: _buildInlineWarning(
                          'Could not load road route: $_pickupRouteError',
                        ),
                      ),
                      TextButton(
                        onPressed: _isLoadingPickupRoute
                            ? null
                            : () => unawaited(
                                _updatePickupRoute(ride, force: true),
                              ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
              ],
              if (_lastLocationError != null) ...[
                const SizedBox(height: 12),
                _buildInlineWarning(
                  'Location update failed: $_lastLocationError',
                ),
              ],
              if (ride.isFromCache) ...[
                const SizedBox(height: 12),
                _buildOfflineBanner(),
              ],
              const SizedBox(height: 16),
              _buildStatusAction(ride),
              if (ride.status == 'accepted') ...[
                const SizedBox(height: 10),
                _buildCancelAssignedRideButton(ride),
              ],
              if (ride.status != 'in_progress' &&
                  ride.status != 'accepted') ...[
                const SizedBox(height: 10),
                _buildBackButton(ride),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRideSummaryCard(RideModel ride) {
    final title = ride.status == 'accepted'
        ? 'Head to the pickup point'
        : ride.status == 'in_progress'
        ? 'Ride in progress'
        : 'Ride ${ride.status}';

    final subtitle = ride.status == 'accepted'
        ? 'Verify the passenger\'s QR when you arrive'
        : ride.status == 'in_progress'
        ? 'Complete the ride and record the cash fare'
        : '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _brandGreen.withValues(alpha: 0.08),
            _brandGreen.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _brandGreen.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.local_taxi_rounded,
                  size: 20,
                  color: _brandGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: _brandDark,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (ride.status == 'accepted' || ride.status == 'in_progress') ...[
            _buildPassengerName(ride),
            const SizedBox(height: 12),
          ],
          // Chat is available while heading to the pickup.
          if (ride.status == 'accepted') ...[
            RideContactActions(
              key: ValueKey('contact_${ride.id}'),
              ride: ride,
              viewerRole: 'driver',
            ),
            const SizedBox(height: 14),
          ],
          _buildLocationLine(
            icon: Icons.trip_origin,
            color: _brandGreen,
            label: 'Pickup',
            value: ride.pickupLocation,
          ),
          const SizedBox(height: 10),
          _buildLocationLine(
            icon: Icons.location_on,
            color: _dropoffOrange,
            label: 'Dropoff',
            value: ride.dropoffLocation,
          ),
          const SizedBox(height: 14),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.black.withValues(alpha: 0.06),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Cash fare',
                  style: TextStyle(
                    fontSize: 13,
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
                  fontSize: 18,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPassengerName(RideModel ride) {
    if (_passengerNameStreamUserId != ride.passengerId) {
      _passengerNameStreamUserId = ride.passengerId;
      _passengerNameStream = context.read<AuthService>().watchPublicName(
        ride.passengerId,
      );
    }
    return StreamBuilder<String?>(
      stream: _passengerNameStream,
      builder: (context, snapshot) {
        final passengerName = snapshot.data;
        final nameLine = _buildLocationLine(
          icon: Icons.person_outline_rounded,
          color: _brandGreen,
          label: 'Passenger',
          value:
              passengerName ??
              (snapshot.hasError
                  ? 'Name unavailable'
                  : 'Loading passenger name…'),
        );
        if (!ride.passengerIdVerified) return nameLine;
        return Row(
          children: [
            Expanded(child: nameLine),
            const SizedBox(width: 8),
            const VerifiedPassengerBadge(),
          ],
        );
      },
    );
  }

  Widget _buildLocationLine({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
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

  Widget _buildInlineWarning(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _dropoffOrange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: _dropoffOrange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
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

  Widget _buildOfflineBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _dropoffOrange.withValues(alpha: 0.3)),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: _dropoffOrange),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Showing saved ride data offline. Trip actions are unavailable until you reconnect.',
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

  Widget _buildStatusAction(RideModel ride) {
    if (ride.status == 'accepted') {
      return SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: ride.isFromCache || _isUpdatingStatus
              ? null
              : _verifyPassengerQr,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
          label: Text(
            'Verify passenger QR',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 0.3,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _brandGreen.withValues(alpha: 0.5),
            disabledForegroundColor: Colors.white,
            elevation: 0,
            shape: const StadiumBorder(),
          ),
        ),
      );
    }

    if (ride.status == 'in_progress') {
      return SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: ride.isFromCache || _isUpdatingStatus
              ? null
              : () => _confirmCashFareAndComplete(ride),
          icon: const Icon(Icons.check_circle_outline_rounded, size: 20),
          label: const Text(
            'Complete & record cash fare',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 0.3,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _brandGreen.withValues(alpha: 0.5),
            disabledForegroundColor: Colors.white,
            elevation: 0,
            shape: const StadiumBorder(),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildCancelAssignedRideButton(RideModel ride) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: ride.isFromCache || _isUpdatingStatus
            ? null
            : () => _confirmCancelAssignedRide(ride),
        icon: const Icon(Icons.cancel_outlined, size: 19),
        label: const Text(
          'Cancel assigned ride',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: _dangerRed,
          side: const BorderSide(color: _dangerRed),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }

  Future<void> _confirmCancelAssignedRide(RideModel ride) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel assigned ride?'),
        content: const Text(
          'This will cancel the ride before pickup and notify the passenger '
          'that they can request another driver.',
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

    setState(() => _isUpdatingStatus = true);
    try {
      final cancelled = await _rideService.cancelAcceptedRide(ride.id);
      if (!mounted) return;
      if (!cancelled) {
        _showSnackBar(
          'Could not cancel the assigned ride. Check your connection and retry.',
          isError: true,
        );
        return;
      }
      await _stopSharing();
    } finally {
      if (mounted) setState(() => _isUpdatingStatus = false);
    }
  }

  Widget _buildBackButton(RideModel ride) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.of(context).pop(),
        icon: Icon(
          ride.status == 'cancelled'
              ? Icons.home_outlined
              : Icons.arrow_back_rounded,
          size: 18,
        ),
        label: Text(
          ride.status == 'cancelled' ? 'Return home' : 'Back to rides',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: _brandDark,
          side: BorderSide(
            color: _brandDark.withValues(alpha: 0.2),
            width: 1.5,
          ),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}
