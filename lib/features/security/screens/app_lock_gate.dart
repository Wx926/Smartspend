import 'package:flutter/material.dart';
import '../../../shared/services/local_storage_service.dart';
import 'passcode_lock_screen.dart';

/// Wraps the app's home content. Decides once at startup, and again every
/// time the app comes back from the background, whether the passcode lock
/// (Profile > Passcode) should be shown before the real content underneath.
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late bool _locked = _shouldLock();
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _shouldLock() {
    final store = LocalStorageService.instance;
    if (!store.passcodeEnabled) return false;
    final last = store.passcodeLastUnlockedAt;
    if (last == null) return true;
    final timeoutMinutes = store.passcodeTimeoutMinutes;
    if (timeoutMinutes <= 0) return true;
    return DateTime.now().difference(last).inMinutes >= timeoutMinutes;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` is a real backgrounding (home button, app switcher); unlike
    // `inactive` it doesn't fire for transient overlays like a system
    // permission dialog, so those don't needlessly trigger a re-lock.
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final backgroundedAt = _backgroundedAt;
      _backgroundedAt = null;
      if (backgroundedAt == null) return;
      final store = LocalStorageService.instance;
      if (!store.passcodeEnabled) return;
      final timeoutMinutes = store.passcodeTimeoutMinutes;
      final elapsedSeconds = DateTime.now()
          .difference(backgroundedAt)
          .inSeconds;
      final shouldLock =
          timeoutMinutes <= 0 || elapsedSeconds >= timeoutMinutes * 60;
      if (shouldLock && mounted) {
        setState(() => _locked = true);
      }
    }
  }

  void _onUnlocked() {
    LocalStorageService.instance.setPasscodeLastUnlockedAt(DateTime.now());
    setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    // `child` is the entire app's Navigator — every route and its state.
    // It must never be conditionally omitted from the tree (e.g. an
    // if/else that returns one or the other): yanking a subtree that large
    // out and back in triggers Flutter's Element-lifecycle assertions
    // ("_ElementLifecycle.inactive") when the app is quickly locked and
    // unlocked. Keeping it permanently present and layering the lock
    // screen on top instead avoids ever tearing it down.
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(child: PasscodeLockScreen(onUnlocked: _onUnlocked)),
      ],
    );
  }
}
