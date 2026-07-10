import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class OsmPlace {
  final String name;
  final String category;
  final String emoji;
  final double latitude;
  final double longitude;

  const OsmPlace({
    required this.name,
    required this.category,
    required this.emoji,
    required this.latitude,
    required this.longitude,
  });
}

class OsmService {
  OsmService._();
  static final OsmService instance = OsmService._();

  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';
  static const _headers = {'User-Agent': 'SmartSpend/1.0'};

  Future<List<OsmPlace>> nearbyPlaces(
    double lat,
    double lon, {
    int radiusMeters = 500,
  }) async {
    final query =
        '''
[out:json][timeout:25];
(
  node["name"]["amenity"](around:$radiusMeters,$lat,$lon);
  node["name"]["shop"](around:$radiusMeters,$lat,$lon);
  node["name"]["tourism"](around:$radiusMeters,$lat,$lon);
  node["name"]["leisure"](around:$radiusMeters,$lat,$lon);
  node["name"]["office"](around:$radiusMeters,$lat,$lon);
  way["name"]["amenity"](around:$radiusMeters,$lat,$lon);
  way["name"]["shop"](around:$radiusMeters,$lat,$lon);
  way["name"]["tourism"](around:$radiusMeters,$lat,$lon);
  way["name"]["leisure"](around:$radiusMeters,$lat,$lon);
);
out center;
''';

    // The public Overpass endpoint occasionally times out or rate-limits
    // under load; retry once before giving up so a single transient
    // failure doesn't silently hide every nearby place from the user.
    http.Response? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        response = await http
            .post(
              Uri.parse(_overpassUrl),
              body: {'data': query},
              headers: _headers,
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) break;
      } catch (_) {
        response = null;
      }
      if (attempt == 0) await Future.delayed(const Duration(seconds: 1));
    }

    try {
      if (response == null || response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = data['elements'] as List? ?? [];

      final places = <OsmPlace>[];
      final seen = <String>{};

      for (final el in elements) {
        final tags = el['tags'] as Map<String, dynamic>? ?? {};
        final name = tags['name'] as String?;
        if (name == null || seen.contains(name)) continue;
        seen.add(name);

        final amenity = tags['amenity'] as String?;
        final shop = tags['shop'] as String?;
        final tourism = tags['tourism'] as String?;
        final leisure = tags['leisure'] as String?;
        final office = tags['office'] as String?;

        final rawCategory =
            amenity ?? shop ?? tourism ?? leisure ?? office ?? 'place';

        // node → lat/lon at top level; way → lat/lon in 'center'
        final center = el['center'] as Map<String, dynamic>?;
        final elLat = (el['lat'] ?? center?['lat']) as num?;
        final elLon = (el['lon'] ?? center?['lon']) as num?;
        if (elLat == null || elLon == null) continue;

        places.add(
          OsmPlace(
            name: name,
            category: _formatCategory(rawCategory),
            emoji: _categoryEmoji(amenity, shop, tourism, leisure),
            latitude: elLat.toDouble(),
            longitude: elLon.toDouble(),
          ),
        );
      }

      // Sort nearest-first so callers can treat places.first as "where I am"
      places.sort((a, b) {
        final da = Geolocator.distanceBetween(
          lat,
          lon,
          a.latitude,
          a.longitude,
        );
        final db = Geolocator.distanceBetween(
          lat,
          lon,
          b.latitude,
          b.longitude,
        );
        return da.compareTo(db);
      });
      return places;
    } catch (_) {
      return [];
    }
  }

  /// Maps an OSM category string to a default expense CategoryModel.id.
  static String toExpenseCategoryId(String osmCategory) {
    final cat = osmCategory.toLowerCase().replaceAll(' ', '_');
    const food = {
      'restaurant',
      'cafe',
      'fast_food',
      'bar',
      'pub',
      'bakery',
      'food_court',
      'ice_cream',
      'juice_bar',
      'biergarten',
      'bbq',
    };
    const shopping = {
      'supermarket',
      'grocery',
      'convenience',
      'clothes',
      'fashion',
      'shoes',
      'electronics',
      'books',
      'sports',
      'gift',
      'jewellery',
      'optician',
      'department_store',
      'mall',
      'hairdresser',
      'beauty',
      'cosmetics',
      'mobile_phone',
      'computer',
      'toys',
      'pet',
      'florist',
      'hardware',
      'stationery',
      'boutique',
    };
    const transport = {
      'fuel',
      'bus_stop',
      'bus_station',
      'taxi',
      'car_rental',
      'parking',
      'bicycle',
      'car_wash',
      'charging_station',
    };
    const entertainment = {
      'cinema',
      'theatre',
      'museum',
      'attraction',
      'amusement_park',
      'casino',
      'arts_centre',
      'nightclub',
      'karaoke',
      'escape_game',
      'bowling_alley',
      'billiards',
      'arcade',
    };
    const health = {
      'hospital',
      'clinic',
      'dentist',
      'doctors',
      'pharmacy',
      'gym',
      'fitness_centre',
      'spa',
    };
    const utilities = {
      'bank',
      'atm',
      'post_office',
      'government',
      'police',
      'office',
      'townhall',
      'library',
    };
    if (food.contains(cat)) return 'food_and_dining';
    if (shopping.contains(cat)) return 'shopping';
    if (transport.contains(cat)) return 'transport';
    if (entertainment.contains(cat)) return 'entertainment';
    if (health.contains(cat)) return 'health';
    if (utilities.contains(cat)) return 'utilities';
    return 'shopping';
  }

  String _formatCategory(String raw) {
    return raw.replaceAll('_', ' ');
  }

  String _categoryEmoji(
    String? amenity,
    String? shop,
    String? tourism,
    String? leisure,
  ) {
    switch (amenity) {
      case 'restaurant':
        return '🍽️';
      case 'cafe':
        return '☕';
      case 'fast_food':
        return '🍔';
      case 'bar':
      case 'pub':
        return '🍺';
      case 'bank':
        return '🏦';
      case 'atm':
        return '🏧';
      case 'pharmacy':
        return '💊';
      case 'hospital':
      case 'clinic':
        return '🏥';
      case 'school':
      case 'university':
        return '🏫';
      case 'fuel':
        return '⛽';
      case 'parking':
        return '🅿️';
      case 'cinema':
        return '🎬';
      case 'gym':
        return '🏋️';
      case 'place_of_worship':
        return '🕌';
    }
    switch (shop) {
      case 'supermarket':
      case 'grocery':
        return '🛒';
      case 'clothes':
      case 'fashion':
        return '👗';
      case 'shoes':
        return '👟';
      case 'electronics':
        return '📱';
      case 'convenience':
        return '🏪';
      case 'mall':
      case 'department_store':
        return '🏬';
      case 'bakery':
        return '🥐';
      case 'hairdresser':
      case 'beauty':
        return '💇';
      case 'books':
        return '📚';
      case 'sports':
        return '⚽';
    }
    switch (tourism) {
      case 'hotel':
      case 'hostel':
        return '🏨';
      case 'museum':
        return '🏛️';
      case 'attraction':
        return '🎡';
    }
    if (leisure == 'fitness_centre') return '🏋️';
    return '📍';
  }
}
