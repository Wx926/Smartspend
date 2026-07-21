import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/services/local_storage_service.dart';
import '../services/auth_service.dart';

Future<void> _clearAccountData() =>
    LocalStorageService.instance.clearAccountData();

class AuthProvider extends ChangeNotifier {
  final AuthService _auth = AuthService.instance;

  bool _isLoading = false;
  String? _errorMessage;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isLoggedIn => _auth.isLoggedIn;
  User? get currentUser => _auth.currentUser;
  String get displayName => _auth.userDisplayName;
  String get email => _auth.userEmail;

  /// Always returns a valid user ID — Supabase ID when logged in,
  /// or a stable device-local UUID when using the app as a guest.
  String get userId =>
      currentUser?.id ?? LocalStorageService.instance.localUserId;

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<bool> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.signUp(email: email, password: password, name: name);
      await _clearAccountData();
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'An unexpected error occurred. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> signIn({required String email, required String password}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.signIn(email: email, password: password);
      await _clearAccountData();
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'An unexpected error occurred. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendRegistrationOtp(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.sendRegistrationOtp(email);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Could not send the verification code. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Verifies the registration OTP, then finishes setting up the account
  /// (Supabase creates the user on OTP verification with no password or
  /// name yet — this call fills both in).
  Future<bool> completeRegistration({
    required String email,
    required String otp,
    required String name,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.verifyRegistrationOtp(email: email, token: otp);
      await _auth.updatePassword(password);
      await _auth.updateName(name);
      await _clearAccountData();
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Could not create your account. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateName(String name) async {
    try {
      await _auth.updateName(name);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPasswordReset(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.resetPassword(email);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Could not send the reset code. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Verifies a recovery OTP (sent via [requestPasswordReset]) without
  /// changing the password — used to confirm identity for things like
  /// passcode recovery, where there's nothing account-level to reset.
  Future<bool> verifyRecoveryOtp({
    required String email,
    required String otp,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.verifyPasswordResetOtp(email: email, token: otp);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Could not verify the code. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> confirmPasswordReset({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _auth.verifyPasswordResetOtp(email: email, token: otp);
      await _auth.updatePassword(newPassword);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (_) {
      _errorMessage = 'Could not reset your password. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    await _clearAccountData();
    // The passcode protects this account's session on this device — once
    // it's over, there's nothing left to lock, and whoever logs in next
    // (same person or someone else) should set up their own if they want
    // one, not inherit whatever was set before.
    await LocalStorageService.instance.setPasscodeEnabled(false);
    await LocalStorageService.instance.setPasscodeHash(null);
    notifyListeners();
  }
}
