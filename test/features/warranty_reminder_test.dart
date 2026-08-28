import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/alerts/services/alert_service.dart';

// FR 4.15: warranty expiration reminder. computeWarrantyReminderFireDate is
// the pure date-math half of this feature (see its own doc comment in
// alert_service.dart for why it's kept separate) -- the actual
// scheduleWarrantyReminder call needs a real notification plugin/device and
// isn't unit-testable, but the decision of WHEN to fire is, and that's the
// part most likely to have an off-by-one or silently-never-fires bug.
void main() {
  group('computeWarrantyReminderFireDate', () {
    test('fires N days before expiry when that point is still in the future', () {
      final now = DateTime(2026, 1, 1);
      final expiry = DateTime(2026, 2, 1); // 31 days out
      final fireDate = computeWarrantyReminderFireDate(
        expiry,
        daysBeforeExpiry: 7,
        now: now,
      );
      expect(fireDate, DateTime(2026, 1, 25)); // 7 days before Feb 1
    });

    test('fires almost immediately when the N-days-before point already passed', () {
      // A 5-day warranty scanned today: "7 days before expiry" is already
      // 2 days in the past by the time this runs.
      final now = DateTime(2026, 1, 1, 10, 0);
      final expiry = DateTime(2026, 1, 6);
      final fireDate = computeWarrantyReminderFireDate(
        expiry,
        daysBeforeExpiry: 7,
        now: now,
      );
      expect(fireDate.isAfter(now), isTrue);
      expect(fireDate.difference(now), lessThan(const Duration(minutes: 1)));
    });

    test('a warranty expiring tomorrow still gets an immediate reminder, not a silently skipped one', () {
      final now = DateTime(2026, 6, 1);
      final expiry = DateTime(2026, 6, 2);
      final fireDate = computeWarrantyReminderFireDate(
        expiry,
        daysBeforeExpiry: 7,
        now: now,
      );
      expect(fireDate.isAfter(now), isTrue);
    });

    test('respects a custom daysBeforeExpiry lead time', () {
      final now = DateTime(2026, 1, 1);
      final expiry = DateTime(2026, 1, 31);
      final fireDate = computeWarrantyReminderFireDate(
        expiry,
        daysBeforeExpiry: 3,
        now: now,
      );
      expect(fireDate, DateTime(2026, 1, 28));
    });
  });
}
