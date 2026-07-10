import 'package:flutter/material.dart';

/// Lets code outside the widget tree (e.g. a notification-tap callback,
/// which has no BuildContext of its own) push routes on the app's Navigator.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
