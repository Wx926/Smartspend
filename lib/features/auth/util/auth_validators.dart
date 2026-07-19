final RegExp emailRegex = RegExp(r'^[\w.+-]+@[\w-]+\.[a-zA-Z]{2,}$');

String? validateEmail(String? value) {
  if (value == null || value.trim().isEmpty) return 'Email is required';
  if (!emailRegex.hasMatch(value.trim())) {
    return 'Enter a valid email (e.g. name@example.com)';
  }
  return null;
}

/// 8+ characters, at least one uppercase, one lowercase, and one symbol —
/// deliberately doesn't restrict *which* characters are allowed elsewhere in
/// the password, only that these categories are present somewhere in it.
String? validateStrongPassword(String? value) {
  if (value == null || value.isEmpty) return 'Password is required';
  if (value.length < 8) return 'At least 8 characters';
  if (!RegExp(r'[A-Z]').hasMatch(value)) {
    return 'Add at least one uppercase letter';
  }
  if (!RegExp(r'[a-z]').hasMatch(value)) {
    return 'Add at least one lowercase letter';
  }
  if (!RegExp(r'[^A-Za-z0-9]').hasMatch(value)) {
    return 'Add at least one symbol (e.g. . , ; ! @)';
  }
  return null;
}

String? validateConfirmPassword(String? value, String password) {
  if (value != password) return 'Passwords do not match';
  return null;
}

/// Deliberately not a fixed length — Supabase's actual OTP length isn't
/// guaranteed, so this only checks it looks like a real code (digits only),
/// not an exact character count.
String? validateOtpCode(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Enter the code from your email';
  }
  if (!RegExp(r'^\d+$').hasMatch(value.trim())) {
    return 'Code should be numbers only';
  }
  return null;
}
