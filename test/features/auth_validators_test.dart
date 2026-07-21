import 'package:flutter_test/flutter_test.dart';
import 'package:smartspend/features/auth/util/auth_validators.dart';

void main() {
  group('validateEmail', () {
    test('rejects empty input', () {
      expect(validateEmail(''), isNotNull);
      expect(validateEmail(null), isNotNull);
    });

    test('rejects malformed email', () {
      expect(validateEmail('abc123'), isNotNull);
      expect(validateEmail('abc@nodot'), isNotNull);
      expect(validateEmail('@missinguser.com'), isNotNull);
    });

    test('accepts a valid email', () {
      expect(validateEmail('student@example.com'), isNull);
    });
  });

  group('validateStrongPassword', () {
    test('rejects password under 8 characters', () {
      expect(validateStrongPassword('Ab1!'), isNotNull);
    });

    test('rejects password missing uppercase', () {
      expect(validateStrongPassword('lowercase1!'), isNotNull);
    });

    test('rejects password missing lowercase', () {
      expect(validateStrongPassword('UPPERCASE1!'), isNotNull);
    });

    test('rejects password missing a symbol', () {
      expect(validateStrongPassword('NoSymbol123'), isNotNull);
    });

    test('accepts a password meeting all rules', () {
      expect(validateStrongPassword('Valid1Pass!'), isNull);
    });
  });

  group('validateConfirmPassword', () {
    test('rejects mismatched confirmation', () {
      expect(validateConfirmPassword('Valid1Pass!', 'Different1!'), isNotNull);
    });

    test('accepts matching confirmation', () {
      expect(validateConfirmPassword('Valid1Pass!', 'Valid1Pass!'), isNull);
    });
  });

  group('validateOtpCode', () {
    test('rejects empty code', () {
      expect(validateOtpCode(''), isNotNull);
    });

    test('rejects non-numeric code', () {
      expect(validateOtpCode('12a456'), isNotNull);
    });

    test('accepts a 6-digit code', () {
      expect(validateOtpCode('123456'), isNull);
    });

    test('accepts an 8-digit code (Supabase sometimes issues longer codes)', () {
      expect(validateOtpCode('14943295'), isNull);
    });
  });
}
