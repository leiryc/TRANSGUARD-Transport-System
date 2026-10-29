import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/location_service.dart';

class MapLocationSelection {
  final LatLng coordinates;
  final String address;

  const MapLocationSelection({
    required this.coordinates,
    required this.address,
  });
}

class MapLocationPickerScreen extends StatefulWidget {
  final LatLng initialPosition;
  final String locationLabel;
  final bool showPickupServiceArea;

  const MapLocationPickerScreen({
    super.key,
    required this.initialPosition,
    required this.locationLabel,
    this.showPickupServiceArea = false,
  });

  @override
  State<MapLocationPickerScreen> createState() =>
      _MapLocationPickerScreenState();
}

class _MapLocationPickerScreenState extends State<MapLocationPickerScreen> {
  final LocationService _locationService = LocationService();
  LatLng? _selectedPosition;
  bool _isResolvingAddress = false;

  Future<void> _confirmDestination() async {
    final position = _selectedPosition;
    if (position == null || _isResolvingAddress) return;
    if (widget.showPickupServiceArea &&
        !_locationService.isWithinPickupServiceArea(
          position.latitude,
          position.longitude,
        )) {
      return;
    }

    setState(() => _isResolvingAddress = true);
    final address = await _locationService.getAddressFromCoordinates(
      position.latitude,
      position.longitude,
    );

    if (!mounted) return;
    setState(() => _isResolvingAddress = false);
    Navigator.of(context).pop(
      MapLocationSelection(
        coordinates: position,
        address: address ?? '(${position.latitude}, ${position.longitude})',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedPosition = _selectedPosition;
    final selectedInsideServiceArea =
        selectedPosition != null &&
        _locationService.isWithinPickupServiceArea(
          selectedPosition.latitude,
          selectedPosition.longitude,
        );

    return Scaffold(
      appBar: AppBar(
        title: Text('Choose ${widget.locationLabel.toLowerCase()}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: widget.initialPosition,
                zoom: 14,
              ),
              onTap: (position) => setState(() => _selectedPosition = position),
              circles: widget.showPickupServiceArea
                  ? {
                      Circle(
                        circleId: const CircleId('pickup-service-area'),
                        center: const LatLng(
                          LocationService.serviceAreaCenterLatitude,
                          LocationService.serviceAreaCenterLongitude,
                        ),
                        radius: LocationService.serviceAreaRadiusMeters,
                        fillColor: const Color(0x33168A5B),
                        strokeColor: const Color(0xFF168A5B),
                        strokeWidth: 2,
                      ),
                    }
                  : const <Circle>{},
              markers: selectedPosition == null
                  ? const <Marker>{}
                  : {
                      Marker(
                        markerId: const MarkerId('selected-location'),
                        position: selectedPosition,
                      ),
                    },
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    selectedPosition == null
                        ? widget.showPickupServiceArea
                              ? 'Choose a pickup inside the shaded 5 km service area'
                              : 'Tap the map to place your ${widget.locationLabel.toLowerCase()} pin'
                        : widget.showPickupServiceArea &&
                              !selectedInsideServiceArea
                        ? 'Pickup is outside the 5 km service area'
                        : '${widget.locationLabel} selected',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed:
                        selectedPosition == null ||
                            _isResolvingAddress ||
                            (widget.showPickupServiceArea &&
                                !selectedInsideServiceArea)
                        ? null
                        : _confirmDestination,
                    child: _isResolvingAddress
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text('Confirm ${widget.locationLabel.toLowerCase()}'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
