import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class RoadRoute {
  final List<LatLng> points;
  final double distanceKm;

  const RoadRoute({required this.points, required this.distanceKm});
}

class RoadRoutingService {
  static final Uri _baseUri = Uri.https('router.project-osrm.org', '');

  Future<RoadRoute> getRoute({
    required LatLng pickup,
    required LatLng dropoff,
  }) async {
    final uri = Uri.https(
      _baseUri.host,
      '/route/v1/driving/'
      '${pickup.longitude},${pickup.latitude};'
      '${dropoff.longitude},${dropoff.latitude}',
      {'overview': 'full', 'geometries': 'geojson', 'steps': 'false'},
    );

    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Road routing service returned ${response.statusCode}.');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['code'] != 'Ok') {
      throw StateError('No drivable road route was found between those stops.');
    }

    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      throw const FormatException('Road routing service returned no route.');
    }
    final route = routes.first as Map;
    final distanceMeters = route['distance'];
    final geometry = route['geometry'];
    final coordinates = geometry is Map ? geometry['coordinates'] : null;
    if (distanceMeters is! num ||
        !distanceMeters.isFinite ||
        distanceMeters <= 0 ||
        coordinates is! List ||
        coordinates.length < 2) {
      throw const FormatException(
        'Road routing service returned an invalid route.',
      );
    }

    final points = <LatLng>[];
    for (final coordinate in coordinates) {
      if (coordinate is! List ||
          coordinate.length < 2 ||
          coordinate[0] is! num ||
          coordinate[1] is! num) {
        throw const FormatException(
          'Road routing service returned invalid coordinates.',
        );
      }
      final longitude = (coordinate[0] as num).toDouble();
      final latitude = (coordinate[1] as num).toDouble();
      if (!latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        throw const FormatException(
          'Road routing service returned invalid coordinates.',
        );
      }
      points.add(LatLng(latitude, longitude));
    }

    return RoadRoute(
      points: List.unmodifiable(points),
      distanceKm: distanceMeters.toDouble() / 1000,
    );
  }
}
