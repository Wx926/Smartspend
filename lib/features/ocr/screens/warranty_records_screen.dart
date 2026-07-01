import 'package:flutter/material.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../shared/theme/app_colors.dart';

class WarrantyRecordsScreen extends StatefulWidget {
  const WarrantyRecordsScreen({super.key});

  @override
  State<WarrantyRecordsScreen> createState() => _WarrantyRecordsScreenState();
}

class _WarrantyRecordsScreenState extends State<WarrantyRecordsScreen> {
  List<Map<String, dynamic>> _warranties = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SupabaseService.instance.getWarranties();
    if (mounted) setState(() { _warranties = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: AppColors.textWhite,
        title: const Text('Warranty Records'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _warranties.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_user_outlined,
                          size: 64, color: AppColors.textSecondary),
                      SizedBox(height: 12),
                      Text('No warranty records yet',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 15)),
                      SizedBox(height: 6),
                      Text('Scan a receipt with warranty info to get started',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _warranties.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _WarrantyCard(w: _warranties[i]),
                  ),
                ),
    );
  }
}

class _WarrantyCard extends StatelessWidget {
  final Map<String, dynamic> w;
  const _WarrantyCard({required this.w});

  @override
  Widget build(BuildContext context) {
    final status = w['status'] as String? ?? 'unknown';
    Color bg, fg;
    IconData icon;
    String label;

    switch (status) {
      case 'green':
        bg = AppColors.alertGreenBg;
        fg = AppColors.budgetGreen;
        icon = Icons.verified_rounded;
        label = 'Valid';
        break;
      case 'yellow':
        bg = AppColors.alertYellowBg;
        fg = AppColors.budgetYellow;
        icon = Icons.warning_amber_rounded;
        label = 'Expiring Soon';
        break;
      case 'red':
        bg = AppColors.alertRedBg;
        fg = AppColors.budgetRed;
        icon = Icons.cancel_rounded;
        label = 'Expired';
        break;
      default:
        bg = AppColors.primarySurface;
        fg = AppColors.primary;
        icon = Icons.shield_rounded;
        label = 'Unknown';
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(w['vendor_name'] as String? ?? 'Unknown vendor',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: fg,
                        fontSize: 15)),
                Text('Status: $label',
                    style: TextStyle(color: fg, fontSize: 13)),
                if (w['duration_months'] != null)
                  Text('Duration: ${w['duration_months']} month(s)',
                      style: TextStyle(color: fg, fontSize: 12)),
                if (w['expiry_date'] != null)
                  Text('Expires: ${w['expiry_date']}',
                      style: TextStyle(color: fg, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
