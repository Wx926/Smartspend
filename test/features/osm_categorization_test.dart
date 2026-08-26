import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/location/services/osm_service.dart';

// Location-Intelligent Spending Tracking module: OsmService.toExpenseCategoryId
// maps a raw OSM place tag (from the Overpass API, e.g. "restaurant",
// "supermarket") to one of SmartSpend's own expense category ids. This is
// the piece of Algorithm 1 that decides which budget a detected venue
// visit actually counts against, so a wrong mapping here silently sends
// alerts/spending to the wrong category.
void main() {
  group('OsmService.toExpenseCategoryId', () {
    test('maps food-related OSM tags to food_and_dining', () {
      expect(OsmService.toExpenseCategoryId('restaurant'), 'food_and_dining');
      expect(OsmService.toExpenseCategoryId('cafe'), 'food_and_dining');
      expect(OsmService.toExpenseCategoryId('fast_food'), 'food_and_dining');
    });

    test('maps retail-related OSM tags to shopping', () {
      expect(OsmService.toExpenseCategoryId('supermarket'), 'shopping');
      expect(OsmService.toExpenseCategoryId('clothes'), 'shopping');
      expect(OsmService.toExpenseCategoryId('mall'), 'shopping');
    });

    test('maps transport-related OSM tags to transport', () {
      expect(OsmService.toExpenseCategoryId('fuel'), 'transport');
      expect(OsmService.toExpenseCategoryId('parking'), 'transport');
    });

    test('maps leisure-related OSM tags to entertainment', () {
      expect(OsmService.toExpenseCategoryId('cinema'), 'entertainment');
      expect(OsmService.toExpenseCategoryId('nightclub'), 'entertainment');
    });

    test('maps medical-related OSM tags to health', () {
      expect(OsmService.toExpenseCategoryId('pharmacy'), 'health');
      expect(OsmService.toExpenseCategoryId('hospital'), 'health');
    });

    test('maps civic/office-related OSM tags to utilities', () {
      expect(OsmService.toExpenseCategoryId('bank'), 'utilities');
      expect(OsmService.toExpenseCategoryId('post_office'), 'utilities');
    });

    test('is case-insensitive and space-tolerant (raw Overpass tags vary)', () {
      expect(OsmService.toExpenseCategoryId('Fast Food'), 'food_and_dining');
      expect(OsmService.toExpenseCategoryId('DEPARTMENT_STORE'), 'shopping');
    });

    test('unrecognised tags default to shopping rather than throwing', () {
      expect(OsmService.toExpenseCategoryId('completely_unknown_tag'), 'shopping');
    });
  });
}
