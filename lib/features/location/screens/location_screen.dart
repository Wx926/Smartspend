import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/location_provider.dart';
import '../services/location_service.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/location_model.dart';
import '../../../shared/theme/app_colors.dart';

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});
  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LocationProvider>().load();
    });
  }

  Future<void> _toggleTracking() async {
    final lp = context.read<LocationProvider>();
    final userId = context.read<AuthProvider>().userId;
    if (lp.isTracking) {
      lp.stopTracking();
    } else {
      final started = await lp.startTracking(userId);
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location permission denied. Enable it in Settings.'),
          backgroundColor: AppColors.budgetRed,
        ));
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

  // ── Nearby view — shown when user is at a known location ──────────────────
  Widget _buildNearbyView(
    BuildContext context,
    LocationProvider lp,
    BudgetProvider bp,
    LocationModel loc,
  ) {
    final fmt = NumberFormat('#,##0.00', 'en_MY');

    return Column(children: [
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                ),
                const Spacer(),
              ]),
              const Text('Nearby',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('You have been at ${loc.name} for ${lp.activeDwellMinutes} min',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 16),
              // Radar visual
              SizedBox(
                height: 130,
                child: Center(
                  child: Stack(alignment: Alignment.center, children: [
                    CustomPaint(
                      size: const Size(200, 120),
                      painter: _RadarPainter(),
                    ),
                    Positioned(
                      top: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(loc.name,
                            style: const TextStyle(
                                color: AppColors.primaryDark,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ),
                    ),
                    Positioned(
                      bottom: 20,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: AppColors.budgetGreen,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                                color: AppColors.budgetGreen.withValues(alpha: 0.5),
                                blurRadius: 8,
                                spreadRadius: 2)
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
            ]),
          ),
        ),
      ),
      // Body
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Your budget status here',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
                    border: Border(
                        left: BorderSide(color: color, width: 4))),
                child: Column(children: [
                  Row(children: [
                    Text(s.categoryIcon, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(s.categoryName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14))),
                    Text('RM ${fmt.format(s.remaining)} left',
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                        value: pct,
                        backgroundColor: color.withValues(alpha: 0.12),
                        color: color,
                        minHeight: 5),
                  ),
                ]),
              );
            }),

            // AI Warning for categories running low
            ...bp.statuses
                .where((s) =>
                    s.severity == AlertSeverity.yellow ||
                    s.severity == AlertSeverity.red)
                .map((s) => Container(
                      margin: const EdgeInsets.only(top: 4, bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('⚠️', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'AI Warning\n${s.categoryName} budget (RM ${fmt.format(s.remaining)} left) is ${s.severity == AlertSeverity.red ? "nearly exhausted" : "running low"}. Think twice before spending here!',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF7C4D00),
                                height: 1.4),
                          ),
                        ),
                      ]),
                    )),

            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
                  label: const Text('Record Spending'),
                  onPressed: () => Navigator.pushNamed(context, '/add-expense'),
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Dismiss'),
                ),
              ),
            ]),
            const SizedBox(height: 80),
          ],
        ),
      ),
    ]);
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
              icon: const Icon(Icons.add_location_alt_outlined, color: Colors.white),
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
                    borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: lp.isTracking
                            ? AppColors.budgetGreen
                            : AppColors.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          lp.isTracking
                              ? 'Location Tracking Active'
                              : 'Location Tracking Off',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(
                          lp.isTracking
                              ? 'Monitoring for known spots within 100m'
                              : 'Enable to get location-aware alerts',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                    ]),
                  ),
                  Switch(
                    value: lp.isTracking,
                    onChanged: (_) => _toggleTracking(),
                    activeThumbColor: AppColors.primary,
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                Text('Saved Locations (${lp.locations.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                if (lp.routineLocations.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('${lp.routineLocations.length} routine',
                        style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
              ]),
              const SizedBox(height: 12),
              if (lp.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (lp.locations.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Center(
                    child: Column(children: [
                      const Icon(Icons.location_off_outlined,
                          size: 56, color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      const Text(
                          'No saved locations yet.\nAdd places you regularly spend at.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 14)),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => _showAddDialog(context, userId),
                        icon: const Icon(Icons.add_location_alt),
                        label: const Text('Add Location'),
                      ),
                    ]),
                  ),
                )
              else
                ...lp.locations.map((loc) => _LocationTile(location: loc)),
              const SizedBox(height: 80),
            ]),
          ),
        ),
      ],
    );
  }

  void _showAddDialog(BuildContext context, String userId) {
    final nameCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          const Text('Add New Location',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
                labelText: 'Location Name',
                hintText: 'e.g. Pavilion KL, Sunway Pyramid',
                prefixIcon: Icon(Icons.place_outlined)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: addressCtrl,
            decoration: const InputDecoration(
                labelText: 'Address (optional)',
                prefixIcon: Icon(Icons.location_on_outlined)),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              final pos = await LocationService.instance.getCurrentPosition();
              if (pos != null && context.mounted) {
                await context.read<LocationProvider>().addLocation(
                      userId: userId,
                      name: nameCtrl.text.trim(),
                      address: addressCtrl.text.trim().isEmpty
                          ? null
                          : addressCtrl.text.trim(),
                      latitude: pos.latitude,
                      longitude: pos.longitude,
                    );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${nameCtrl.text.trim()} saved'),
                    backgroundColor: AppColors.budgetGreen,
                  ));
                }
              }
            },
            child: const Text('Save Current Location'),
          ),
        ]),
      ),
    );
  }
}

class _LocationTile extends StatelessWidget {
  final LocationModel location;
  const _LocationTile({required this.location});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.primarySurface,
            child: const Icon(Icons.location_on, color: AppColors.primary),
          ),
          title: Row(children: [
            Text(location.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (location.isRoutine) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(6)),
                child: const Text('Routine',
                    style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ]),
          subtitle: Text(
            location.address ??
                '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
          trailing: Text('${location.visitCount} visits',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ),
      );
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
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2), paint);
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

