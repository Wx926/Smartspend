import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  SupabaseClient get _client => Supabase.instance.client;

  User? get currentUser => _client.auth.currentUser;
  bool get isLoggedIn => currentUser != null;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: {'name': name},
    );
    return response;
  }

  /// Step 1 of OTP-based registration: sends a 6-digit code to [email] and
  /// creates the underlying Supabase user if one doesn't already exist yet
  /// (it has no password until [verifyRegistrationOtp] + [updatePassword]
  /// run — same email template caveat as [resetPassword], needs
  /// `{{ .Token }}` in the relevant Supabase email template).
  Future<void> sendRegistrationOtp(String email) async {
    await _client.auth.signInWithOtp(email: email, shouldCreateUser: true);
  }

  /// Step 2: verifying the code opens a real session for that (possibly
  /// brand new) user — the caller still needs to set a password and name
  /// on it afterward via [updatePassword]/[updateName] to finish
  /// registration.
  Future<void> verifyRegistrationOtp({
    required String email,
    required String token,
  }) async {
    await _client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.email,
    );
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Sends a password-recovery email containing a one-time code. The
  /// Supabase project's "Reset Password" email template must be set to show
  /// `{{ .Token }}` for this to arrive as a 6-digit code rather than a link.
  Future<void> resetPassword(String email) async {
    await _client.auth.resetPasswordForEmail(email);
  }

  /// Verifies the code from [resetPassword]'s email. On success this opens a
  /// recovery session, after which [updatePassword] can actually change it.
  Future<void> verifyPasswordResetOtp({
    required String email,
    required String token,
  }) async {
    await _client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.recovery,
    );
  }

  Future<void> updatePassword(String password) async {
    await _client.auth.updateUser(UserAttributes(password: password));
  }

  Future<void> updateName(String name) async {
    await _client.auth.updateUser(UserAttributes(data: {'name': name}));
  }

  String get userDisplayName {
    final user = currentUser;
    if (user == null) return '';
    return user.userMetadata?['name'] as String? ??
        user.email?.split('@').first ??
        'User';
  }

  String get userEmail => currentUser?.email ?? '';
}
