import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/location_provider.dart';
import '../services/location_service.dart';
import '../services/osm_service.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/theme/app_colors.dart';

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});
  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final userId = context.read<AuthProvider>().userId;
      final lp = context.read<LocationProvider>();
      await lp.load(userId);
      // load() only force-checks position if tracking wasn't already
      // running; if it was, force a fresh check now so the screen reflects
      // where the device actually is instead of waiting for the next
      // background poll.
      if (mounted && lp.isTracking) lp.refresh(userId);
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final userId = context.read<AuthProvider>().userId;
    await context.read<LocationProvider>().refresh(userId);
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _toggleTracking() async {
    final lp = context.read<LocationProvider>();
    final userId = context.read<AuthProvider>().userId;
    if (lp.isTracking) {
      lp.stopTracking();
    } else {
      final started = await lp.startTracking(userId);
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission denied. Enable it in Settings.'),
            backgroundColor: AppColors.budgetRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lp = context.watch<LocationProvider>();
    final bp = context.watch<BudgetProvider>();
    final active = lp.activeLocation;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: active != null
          ? _buildNearbyView(context, lp, bp, active)
          : _buildTrackingView(context, lp),
    );
  }

  // Radius (much wider than the 100m geofence match) for showing other
  // saved spots on the radar as context — e.g. a cafe next to the mall
  // you're confirmed at, or another venue a few streets over. Purely
  // informational, doesn't affect which location is actually matched or
  // which one gets alerts, so it's fine to be generous.
  static const double _otherNearbyRadiusMeters = 1000;
  static const int _maxOtherNearby = 3;

  /// Up to [_maxOtherNearby] other saved locations near [center], nearest
  /// first, each paired with its compass bearing from [center] for
  /// positioning on the radar.
  List<(LocationModel, double)> _nearestOthers(
    LocationModel center,
    List<LocationModel> all,
  ) {
    final others =
        all
            .where((l) => l.id != center.id)
            .map((l) {
              final dist = Geolocator.distanceBetween(
                center.latitude,
                center.longitude,
                l.latitude,
                l.longitude,
              );
              final bearing = Geolocator.bearingBetween(
                center.latitude,
                center.longitude,
                l.latitude,
                l.longitude,
              );
              return (l, dist, bearing);
            })
            .where((t) => t.$2 <= _otherNearbyRadiusMeters)
            .toList()
          ..sort((a, b) => a.$2.compareTo(b.$2));
    return others.take(_maxOtherNearby).map((t) => (t.$1, t.$3)).toList();
  }

  // ── Nearby view — shown when user is at a known location ──────────────────
  Widget _buildNearbyView(
    BuildContext context,
    LocationProvider lp,
    BudgetProvider bp,
    LocationModel loc,
  ) {
    final fmt = NumberFormat('#,##0.00', 'en_MY');
    final userId = context.read<AuthProvider>().userId;
    final otherNearby = _nearestOthers(loc, lp.locations);

    return Column(
      children: [
        // Green header
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.primaryDark, AppColors.primary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: _refreshing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, color: Colors.white),
                        tooltip: 'Refresh location',
                        onPressed: _refresh,
                        padding: EdgeInsets.zero,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.add_location_alt_outlined,
                          color: Colors.white,
                        ),
                        tooltip: 'Add location',
                        onPressed: () => _showAddDialog(context, userId),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  const Text(
                    'Nearby',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You have been at ${loc.name} for ${lp.activeDwellMinutes} min',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  // Radar visual
                  SizedBox(
                    height: 130,
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            size: const Size(200, 120),
                            painter: _RadarPainter(),
                          ),
                          Positioned(
                            top: 20,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                loc.name,
                                style: const TextStyle(
                                  color: AppColors.primaryDark,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          // Centered — you're confirmed as being at this
                          // location, so your position dot sits at the
                          // radar's center rather than off to one side.
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: AppColors.budgetGreen,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.budgetGreen.withValues(
                                    alpha: 0.5,
                                  ),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                          // Other saved spots nearby, placed on successive
                          // rings (nearest = innermost) at their real
                          // compass bearing from the confirmed location.
                          for (int i = 0; i < otherNearby.length; i++)
                            ..._buildOtherLocationDot(
                              otherNearby[i].$1,
                              otherNearby[i].$2,
                              ring: i + 1,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
        // Body
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Your budget status here',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              ...bp.statuses.map((s) {
                final color = s.severity == AlertSeverity.red
                    ? AppColors.budgetRed
                    : s.severity == AlertSeverity.yellow
                    ? AppColors.budgetYellow
                    : AppColors.budgetGreen;
                final pct = s.percentUsed.clamp(0.0, 1.0);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border(left: BorderSide(color: color, width: 4)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            s.categoryIcon,
                            style: const TextStyle(fontSize: 18),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              s.categoryName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            'RM ${fmt.format(s.remaining)} left',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: color.withValues(alpha: 0.12),
                          color: color,
                          minHeight: 5,
                        ),
                      ),
                    ],
                  ),
                );
              }),

              // AI Warning for categories running low
              ...bp.statuses
                  .where(
                    (s) =>
                        s.severity == AlertSeverity.yellow ||
                        s.severity == AlertSeverity.red,
                  )
                  .map(
                    (s) => Container(
                      margin: const EdgeInsets.only(top: 4, bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('⚠️', style: TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'AI Warning\n${s.categoryName} budget (RM ${fmt.format(s.remaining)} left) is ${s.severity == AlertSeverity.red ? "nearly exhausted" : "running low"}. Think twice before spending here!',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF7C4D00),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(
                        Icons.add_shopping_cart_outlined,
                        size: 18,
                      ),
                      label: const Text('Record Spending'),
                      onPressed: () =>
                          Navigator.pushNamed(context, '/add-expense'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Dismiss'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              ..._buildSavedLocationsSection(
                context,
                lp,
                context.read<AuthProvider>().userId,
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ],
    );
  }

  // ── Saved locations list — shared by both the nearby and tracking views ──
  List<Widget> _buildSavedLocationsSection(
    BuildContext context,
    LocationProvider lp,
    String userId,
  ) {
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Saved Locations (${lp.locations.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          if (lp.routineLocations.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${lp.routineLocations.length} routine',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (lp.isLoading)
        const Center(child: CircularProgressIndicator())
      else if (lp.locations.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 32),
          child: Center(
            child: Column(
              children: [
                const Icon(
                  Icons.location_off_outlined,
                  size: 56,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(height: 12),
                const Text(
                  'No saved locations yet.\nAdd places you regularly spend at.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _showAddDialog(context, userId),
                  icon: const Icon(Icons.add_location_alt),
                  label: const Text('Add Location'),
                ),
              ],
            ),
          ),
        )
      else
        ...lp.locations.map((loc) => _LocationTile(location: loc)),
    ];
  }

  // ── Tracking management view — when not at a location ─────────────────────
  Widget _buildTrackingView(BuildContext context, LocationProvider lp) {
    final userId = context.read<AuthProvider>().userId;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: AppColors.primaryDark,
          title: const Text('Nearby', style: TextStyle(color: Colors.white)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            IconButton(
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh, color: Colors.white),
              tooltip: 'Refresh location',
              onPressed: _refresh,
            ),
            IconButton(
              icon: const Icon(
                Icons.add_location_alt_outlined,
                color: Colors.white,
              ),
              onPressed: () => _showAddDialog(context, userId),
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // Tracking toggle card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: lp.isTracking ? AppColors.alertGreenBg : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: lp.isTracking
                            ? AppColors.budgetGreen
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lp.isTracking
                                ? 'Location Tracking Active'
                                : 'Location Tracking Off',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            lp.isTracking
                                ? 'Monitoring for known spots within 100m'
                                : 'Enable to get location-aware alerts',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: lp.isTracking,
                      onChanged: (_) => _toggleTracking(),
                      activeThumbColor: AppColors.primary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              ..._buildSavedLocationsSection(context, lp, userId),
              const SizedBox(height: 80),
            ]),
          ),
        ),
      ],
    );
  }

  void _showAddDialog(BuildContext context, String userId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AddLocationSheet(userId: userId),
    );
  }

  /// A small dot + name label for another nearby saved location, placed on
  /// the [ring]-th radar ring (matches _RadarPainter's 200x120 rings, 1-3)
  /// at [bearing] degrees from the confirmed location at the center.
  List<Widget> _buildOtherLocationDot(
    LocationModel other,
    double bearing, {
    required int ring,
  }) {
    const centerX = 100.0, centerY = 60.0;
    final rx = 100 * ring / 3;
    final ry = 60 * ring / 3;
    final bearingRad = bearing * math.pi / 180;
    final dx = rx * math.sin(bearingRad);
    final dy = -ry * math.cos(bearingRad);
    const color = Color(
      0xFFFFA726,
    ); // orange — distinct from the green "you are here" dot

    return [
      Positioned(
        left: centerX + dx - 5,
        top: centerY + dy - 5,
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.fromBorderSide(
              BorderSide(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ),
      Positioned(
        left: (centerX + dx - 40).clamp(0, 200 - 80).toDouble(),
        top: centerY + dy + (dy >= 0 ? 8 : -20),
        child: SizedBox(
          width: 80,
          child: Text(
            other.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black45, blurRadius: 3)],
            ),
          ),
        ),
      ),
    ];
  }
}

class _AddLocationSheet extends StatefulWidget {
  final String userId;
  const _AddLocationSheet({required this.userId});

  @override
  State<_AddLocationSheet> createState() => _AddLocationSheetState();
}

class _AddLocationSheetState extends State<_AddLocationSheet> {
  final _nameCtrl = TextEditingController();
  List<OsmPlace>? _places;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchNearby();
  }

  Future<void> _fetchNearby() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final pos = await LocationService.instance.getCurrentPosition();
    if (pos == null) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Could not get GPS position.';
        });
      return;
    }
    final places = await OsmService.instance.nearbyPlaces(
      pos.latitude,
      pos.longitude,
    );
    if (mounted)
      setState(() {
        _places = places;
        _loading = false;
      });
  }

  Future<void> _save(
    String name, {
    double? lat,
    double? lon,
    List<String> categoryIds = const [],
  }) async {
    if (name.trim().isEmpty) return;
    // Capture before Navigator.pop unmounts this widget
    final lp = context.read<LocationProvider>();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);

    final double saveLat;
    final double saveLon;
    if (lat != null && lon != null) {
      saveLat = lat;
      saveLon = lon;
    } else {
      final pos = await LocationService.instance.getCurrentPosition();
      if (pos == null) return;
      saveLat = pos.latitude;
      saveLon = pos.longitude;
    }

    await lp.addLocation(
      userId: widget.userId,
      name: name.trim(),
      latitude: saveLat,
      longitude: saveLon,
      categoryIds: categoryIds,
    );

    // A brand-new location has never been confirmed, so it wouldn't show
    // the radar preview until the next natural dwell (or a manual refresh)
    // — force one now so it appears immediately if the user is there.
    if (lp.isTracking) {
      await lp.refresh(widget.userId);
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text('${name.trim()} saved'),
        backgroundColor: AppColors.budgetGreen,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Add Location',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),

          // ── Nearby places from OpenStreetMap ──────────────────────────────
          Row(
            children: [
              const Text(
                'Nearby Places',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(width: 6),
              const Text(
                'via OpenStreetMap',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _loading ? null : _fetchNearby,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.budgetRed,
                  fontSize: 13,
                ),
              ),
            )
          else if (_places != null && _places!.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No places found nearby. Enter name manually below.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            )
          else if (_places != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _places!.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = _places![i];
                  return ListTile(
                    dense: true,
                    leading: Text(
                      p.emoji,
                      style: const TextStyle(fontSize: 22),
                    ),
                    title: Text(
                      p.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      p.category,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.add_circle_outline,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    onTap: () => _save(
                      p.name,
                      lat: p.latitude,
                      lon: p.longitude,
                      categoryIds: [OsmService.toExpenseCategoryId(p.category)],
                    ),
                  );
                },
              ),
            ),

          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),

          // ── Manual fallback ───────────────────────────────────────────────
          const Text(
            'Or enter manually',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Location name',
              hintText: 'e.g. My Office, Home',
              prefixIcon: Icon(Icons.place_outlined),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => _save(_nameCtrl.text),
            child: const Text('Save Current Location'),
          ),
        ],
      ),
    );
  }
}

class _LocationTile extends StatelessWidget {
  final LocationModel location;
  const _LocationTile({required this.location});

  @override
  Widget build(BuildContext context) {
    final cats = context.watch<BudgetProvider>().categories;
    return Dismissible(
      key: Key(location.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.budgetRed,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Remove Location'),
          content: Text(
            'Remove "${location.name}"? The app will no longer detect this spot.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'Remove',
                style: TextStyle(color: AppColors.budgetRed),
              ),
            ),
          ],
        ),
      ),
      onDismissed: (_) =>
          context.read<LocationProvider>().deleteLocation(location.id),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.primarySurface,
            child: const Icon(Icons.location_on, color: AppColors.primary),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  location.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (location.effectiveIsRoutine) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    location.routineOverride == true ? 'Home/Work' : 'Routine',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            location.address ??
                '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${location.visitCount} visits',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(
                  Icons.more_vert,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                tooltip: 'Location settings',
                onPressed: () => _showLocationSettings(context, location, cats),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  color: AppColors.budgetRed,
                  size: 20,
                ),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Remove Location'),
                      content: Text(
                        'Remove "${location.name}"? The app will no longer detect this spot.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text(
                            'Remove',
                            style: TextStyle(color: AppColors.budgetRed),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && context.mounted) {
                    context.read<LocationProvider>().deleteLocation(
                      location.id,
                    );
                  }
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Locations saved via "enter manually" have no category, so Algorithm 3
  // can never tell which budget is relevant here — let the user assign one
  // (or several — a mall can be both Shopping and Food) after the fact.
  // Uses the user's actual categories (defaults + custom, e.g. "gym"), not
  // a fixed list, and stays editable even for system-suggested categories.
  void _showLocationSettings(
    BuildContext context,
    LocationModel location,
    List<CategoryModel> allCategories,
  ) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final categoryNames = location.categoryIds
            .map((id) => allCategories.where((c) => c.id == id).firstOrNull)
            .whereType<CategoryModel>()
            .toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Location Settings',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  location.name,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Category',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showCategoryPicker(context, location, allCategories);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (categoryNames.isEmpty)
                  const Text(
                    'No category set — alerts can\'t run here yet.',
                    style: TextStyle(fontSize: 13, color: AppColors.budgetRed),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: categoryNames.map((c) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(c.icon, style: const TextStyle(fontSize: 13)),
                            const SizedBox(width: 4),
                            Text(
                              c.name,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 24),
                const Text(
                  'Alert behavior',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 8),
                _RoutineOptionTile(
                  icon: Icons.auto_awesome,
                  title: 'Auto-detect (default)',
                  subtitle: 'Learn from visit patterns automatically',
                  selected: location.routineOverride == null,
                  onTap: () {
                    context.read<LocationProvider>().setRoutineOverride(
                      location.id,
                      null,
                    );
                    Navigator.pop(ctx);
                  },
                ),
                _RoutineOptionTile(
                  icon: Icons.home_outlined,
                  title: 'Mark as Home/Work',
                  subtitle: 'Mute alerts here, always',
                  selected: location.routineOverride == true,
                  onTap: () {
                    context.read<LocationProvider>().setRoutineOverride(
                      location.id,
                      true,
                    );
                    Navigator.pop(ctx);
                  },
                ),
                _RoutineOptionTile(
                  icon: Icons.notifications_active_outlined,
                  title: 'Always alert here',
                  subtitle: 'Never treat as routine',
                  selected: location.routineOverride == false,
                  onTap: () {
                    context.read<LocationProvider>().setRoutineOverride(
                      location.id,
                      false,
                    );
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCategoryPicker(
    BuildContext context,
    LocationModel location,
    List<CategoryModel> categories,
  ) {
    final selected = Set<String>.from(location.categoryIds);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Categories for ${location.name}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pick every category relevant here — a mall might be both Shopping and Food.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: categories.map((c) {
                    final isSelected = selected.contains(c.id);
                    return GestureDetector(
                      onTap: () => setSheetState(() {
                        if (isSelected) {
                          selected.remove(c.id);
                        } else {
                          selected.add(c.id);
                        }
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withValues(alpha: 0.12)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary
                                : const Color(0xFFE0E0E0),
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(c.icon, style: const TextStyle(fontSize: 15)),
                            const SizedBox(width: 6),
                            Text(
                              c.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.check_circle,
                                size: 16,
                                color: AppColors.primary,
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    context.read<LocationProvider>().setCategoryIds(
                      location.id,
                      selected.toList(),
                    );
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoutineOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _RoutineOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : const Color(0xFFE0E0E0),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: selected ? AppColors.primary : AppColors.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_circle,
                color: AppColors.primary,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}

// Radar rings painter
class _RadarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 3; i >= 1; i--) {
      paint.color = Colors.white.withValues(alpha: 0.15 * i);
      final rx = (size.width / 2) * i / 3;
      final ry = (size.height / 2) * i / 3;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
        paint,
      );
    }
    // Cross hairs
    paint
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), paint);
  }

  @override
  bool shouldRepaint(_) => false;
}
