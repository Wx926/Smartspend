import 'dart:convert';
import 'package:crypto/crypto.dart';

/// One-way hash for the 4-digit app passcode — never store the raw digits.
/// Not meant to resist a targeted attack, just to avoid keeping a plaintext
/// PIN sitting in SharedPreferences.
String hashPasscode(String pin) {
  final bytes = utf8.encode('smartspend_passcode::$pin');
  return sha256.convert(bytes).toString();
}
