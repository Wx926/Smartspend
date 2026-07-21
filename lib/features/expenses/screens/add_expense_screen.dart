import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/expense_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/location/providers/location_provider.dart';
import '../../../features/location/services/location_service.dart';
import '../../../features/location/services/osm_service.dart';
import '../../../features/savings_goals/providers/savings_goal_provider.dart';
import '../../../features/wallet/providers/wallet_provider.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/models/wallet_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../../ocr/screens/scan_receipt_screen.dart';
import '../../voice/screens/voice_input_screen.dart';

class AddExpenseScreen extends StatefulWidget {
  final ExpenseModel? existingExpense;
  const AddExpenseScreen({super.key, this.existingExpense});

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _manualLocationCtrl = TextEditingController();
  CategoryModel? _selectedCategory;
  WalletModel? _selectedWallet;
  DateTime _selectedDate = DateTime.now();
  bool _saving = false;
  String _type = 'expense';

  SavingsGoalModel? _selectedGoal;

  // All places within range of the current position — saved locations and
  // unsaved OSM places alike — so the user can pick the right one when more
  // than one is nearby, instead of the app silently guessing.
  List<_LocationCandidate> _locationCandidates = [];
  _LocationCandidate? _selectedLocationCandidate;
  bool _categoryManuallySet = false;
  bool _detectingLocation = false;

  bool get _isEdit => widget.existingExpense != null;
  bool get _isIncome => _type == 'income';

  @override
  void initState() {
    super.initState();
    final e = widget.existingExpense;
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(2);
      _descCtrl.text = e.description;
      _selectedDate = e.date;
      _type = e.type;
    } else {
      // Request a fresh location check so the candidate list reflects where
      // the device actually is now, rather than the last periodic
      // background poll (which runs at most once every 60s).
      final userId = context.read<AuthProvider>().userId;
      context.read<LocationProvider>().refresh(userId);
      _detectLocationCandidates();
    }
  }

  // Deliberately wider than AppConstants.geofenceRadiusMeters (the
  // background arrival-detection radius). A false positive here just adds
  // an extra selectable chip the user can ignore; a false positive in the
  // background geofence would wrongly fire an "you've arrived" alert. GPS
  // and OSM node placement are rarely pinpoint-exact, so a tight radius
  // makes real nearby places (like a cafe next to a saved venue) miss.
  static const double _candidateRadiusMeters = 150;
  // Wider than _candidateRadiusMeters: this only bounds the OSM/Overpass
  // query, not saved-venue matching, so it can be generous without risking
  // false "arrived" matches. Matches the default radius used by the Nearby
  // Locations screen (OsmService.nearbyPlaces), so both surfaces suggest a
  // comparable number of nearby places.
  static const int _osmSearchRadiusMeters = 500;
  static const int _maxCandidates = 6;

  /// Gathers every place within range of the current position — both
  /// locations the user has explicitly saved and unsaved places from a live
  /// OSM lookup — so the user can pick the right one when more than one is
  /// nearby (e.g. a saved venue and a cafe inside/next to it).
  Future<void> _detectLocationCandidates() async {
    setState(() => _detectingLocation = true);
    final pos = await LocationService.instance.getCurrentPosition();
    if (pos == null || !mounted) {
      if (mounted) setState(() => _detectingLocation = false);
      return;
    }

    // Saved locations are normally loaded by the Nearby screen; if the user
    // opens Add Record without ever visiting it this session, the list
    // would otherwise be empty and every saved venue would be missed.
    final lp = context.read<LocationProvider>();
    if (lp.locations.isEmpty) {
      await lp.load(context.read<AuthProvider>().userId);
      if (!mounted) return;
    }
    final savedLocations = lp.locations;
    final candidates = <_LocationCandidate>[];

    for (final loc in savedLocations) {
      final dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        loc.latitude,
        loc.longitude,
      );
      if (dist <= _candidateRadiusMeters) {
        candidates.add(
          _LocationCandidate(
            name: loc.name,
            emoji: '📍',
            locationId: loc.id,
            suggestedCategoryId: loc.categoryIds.firstOrNull,
            distanceMeters: dist,
            latitude: loc.latitude,
            longitude: loc.longitude,
          ),
        );
      }
    }

    final savedNames = savedLocations.map((l) => l.name.toLowerCase()).toSet();
    final places = await OsmService.instance.nearbyPlaces(
      pos.latitude,
      pos.longitude,
      radiusMeters: _osmSearchRadiusMeters,
    );
    for (final p in places) {
      if (savedNames.contains(p.name.toLowerCase())) continue;
      final dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        p.latitude,
        p.longitude,
      );
      candidates.add(
        _LocationCandidate(
          name: p.name,
          emoji: p.emoji,
          suggestedCategoryId: OsmService.toExpenseCategoryId(p.category),
          distanceMeters: dist,
          latitude: p.latitude,
          longitude: p.longitude,
        ),
      );
    }

    if (!mounted) return;
    if (candidates.isEmpty) {
      setState(() => _detectingLocation = false);
      return;
    }
    candidates.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));

    // A saved location in range should always lead the list — the user
    // already curated it (name + category), so it's more likely correct
    // than a same-distance OSM point. Without this, a cluster of unrelated
    // OSM places (e.g. several shops right at a mall entrance) can crowd the
    // saved venue itself out of the top _maxCandidates entirely. Whatever
    // remains — other saved locations and OSM places alike — still fills
    // the rest of the list nearest-first, same as before.
    final savedCandidates = candidates
        .where((c) => c.locationId != null)
        .toList();
    final ordered = savedCandidates.isEmpty
        ? candidates
        : [
            savedCandidates.first,
            ...candidates.where((c) => c != savedCandidates.first),
          ];
    final nearest = ordered.take(_maxCandidates).toList();

    setState(() {
      _locationCandidates = nearest;
      _selectedLocationCandidate = nearest.first;
      _detectingLocation = false;
    });
    _suggestCategoryFor(nearest.first);
  }

  /// Suggests a category for [candidate]: prefers the category most recently
  /// used at that exact saved location, then its static place-type hint.
  /// Never overrides a category the user picked manually themselves.
  void _suggestCategoryFor(_LocationCandidate candidate) {
    if (_categoryManuallySet) return;
    final cats = context.read<BudgetProvider>().categories;
    CategoryModel? suggestion;

    if (candidate.locationId != null) {
      final pastExpenses =
          context
              .read<ExpenseProvider>()
              .expenses
              .where(
                (e) =>
                    e.locationId == candidate.locationId && e.type == 'expense',
              )
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date));
      if (pastExpenses.isNotEmpty) {
        suggestion = cats
            .where((c) => c.id == pastExpenses.first.categoryId)
            .firstOrNull;
      }
    }

    if (suggestion == null && candidate.suggestedCategoryId != null) {
      suggestion = cats
          .where((c) => c.id == candidate.suggestedCategoryId)
          .firstOrNull;
    }

    if (suggestion != null && mounted) {
      setState(() => _selectedCategory = suggestion);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wp = context.read<WalletProvider>();
    if (_selectedWallet == null) {
      if (_isEdit) {
        _selectedWallet =
            wp.wallets
                .where((w) => w.id == widget.existingExpense!.walletId)
                .firstOrNull ??
            wp.defaultWallet;
      } else {
        _selectedWallet = wp.defaultWallet;
      }
    }
    if (_selectedCategory == null && _isEdit) {
      final bp = context.read<BudgetProvider>();
      final allCats = [...bp.categories, ...bp.incomeCategories];
      _selectedCategory = allCats
          .where((c) => c.id == widget.existingExpense!.categoryId)
          .firstOrNull;
    }
    // New (non-edit) expenses get their category suggestion from
    // _detectLocationCandidates / _suggestCategoryFor instead, since that
    // considers every nearby place, not just the single geofence match.
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    _manualLocationCtrl.dispose();
    super.dispose();
  }

  void _switchType(String newType) {
    if (newType == _type) return;
    setState(() {
      _type = newType;
      _selectedCategory = null;
      _categoryManuallySet = false;
      if (newType == 'income') _selectedGoal = null;
    });
    if (newType == 'expense' && _selectedLocationCandidate != null) {
      _suggestCategoryFor(_selectedLocationCandidate!);
    }
  }

  Future<void> _pickSavingsGoal() async {
    final sp = context.read<SavingsGoalProvider>();
    await sp.loadIfNeeded();
    if (!mounted) return;
    final goals = sp.goals;
    if (goals.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No savings goals found')));
      return;
    }
    final fmt = NumberFormat('#,##0.00', 'en_MY');
    final selected = await showModalBottomSheet<SavingsGoalModel>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Select Savings Goal',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          ...goals.map(
            (g) => ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                child: const Text('🎯', style: TextStyle(fontSize: 16)),
              ),
              title: Text(g.name),
              subtitle: Text(
                'Available: RM ${fmt.format(g.currentAmount)} / RM ${fmt.format(g.targetAmount)}',
              ),
              trailing: g.isCompleted
                  ? const Icon(Icons.check_circle, color: AppColors.budgetGreen)
                  : null,
              onTap: () => Navigator.pop(ctx, g),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (selected != null) {
      setState(() {
        _selectedGoal = selected;
        _selectedWallet = null;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a category')));
      return;
    }

    final amount = double.parse(_amountCtrl.text);

    // Validate savings goal balance if spending from one
    if (_selectedGoal != null && amount > _selectedGoal!.currentAmount) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Amount exceeds ${_selectedGoal!.name} balance of RM ${_selectedGoal!.currentAmount.toStringAsFixed(2)}',
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final userId = context.read<AuthProvider>().userId;
      final expProvider = context.read<ExpenseProvider>();
      final sgProvider = context.read<SavingsGoalProvider>();
      final bp = context.read<BudgetProvider>();
      final candidate = _selectedLocationCandidate;
      final manualLocationName = _manualLocationCtrl.text.trim();
      // A manually typed name (e.g. entered while offline with no GPS/OSM
      // candidates available) always wins over a detected chip, and is never
      // attached to a saved locationId — there's no coordinate behind free
      // text, so it can't be matched or offered for saving like a real place.
      // Only an already-saved location has a locationId to attach directly.
      // A candidate from the live OSM lookup stays unattached for now — the
      // user gets asked whether to save it as a real location *after* the
      // expense itself is safely recorded (see below), rather than that
      // happening silently on every pick.
      final activeLocationId =
          (_isIncome || manualLocationName.isNotEmpty || candidate == null)
          ? null
          : candidate.locationId;
      // Kept regardless of whether the place is (or becomes) a saved
      // location, so the visit still shows up in history even if the user
      // says "Not now" below, or later deletes the saved location.
      final activeLocationName = _isIncome
          ? null
          : manualLocationName.isNotEmpty
          ? manualLocationName
          : candidate?.name;

      ExpenseModel? savedExpense;
      if (_isEdit) {
        await expProvider.updateExpense(
          widget.existingExpense!.copyWith(
            categoryId: _selectedCategory!.id,
            amount: amount,
            description: _descCtrl.text.trim(),
            date: _selectedDate,
            type: _type,
          ),
        );
      } else if (_selectedGoal != null) {
        // Spending from a savings goal — use special walletId, deduct from goal
        savedExpense = await expProvider.addExpense(
          userId: userId,
          categoryId: _selectedCategory!.id,
          amount: amount,
          description: _descCtrl.text.trim(),
          date: _selectedDate,
          type: 'expense',
          walletId: 'savings_goal',
          savingsGoalId: _selectedGoal!.id,
          locationId: activeLocationId,
          locationName: activeLocationName,
        );
        final newAmount = _selectedGoal!.currentAmount - amount;
        await sgProvider.update(
          _selectedGoal!.copyWith(
            currentAmount: newAmount,
            isCompleted: newAmount >= _selectedGoal!.targetAmount,
          ),
        );
      } else {
        savedExpense = await expProvider.addExpense(
          userId: userId,
          categoryId: _selectedCategory!.id,
          amount: amount,
          description: _descCtrl.text.trim(),
          date: _selectedDate,
          type: _type,
          walletId: _selectedWallet?.id ?? 'default_account',
          locationId: activeLocationId,
          locationName: activeLocationName,
        );
      }

      if (mounted) {
        bp.recalculate(
          expProvider.expensesForMonth(
            DateTime.now().month,
            DateTime.now().year,
          ),
        );
      }

      // The expense is safely recorded — now, only if it was placed at an
      // unsaved OSM candidate, ask whether to keep this location for next
      // time. Never automatic: a "No" here just means this one record has
      // no attached location, same as picking nothing at all. A manually
      // typed name has no coordinate behind it, so it's never offered here.
      if (mounted &&
          savedExpense != null &&
          manualLocationName.isEmpty &&
          candidate?.locationId == null) {
        final place = candidate;
        if (place != null) {
          final shouldSave = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Save this location?'),
              content: Text(
                'Save "${place.name}" so SmartSpend recognizes it next time '
                'and can give you spending alerts here.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          );
          if (shouldSave == true && mounted) {
            final newLoc = await context.read<LocationProvider>().addLocation(
              userId: userId,
              name: place.name,
              latitude: place.latitude,
              longitude: place.longitude,
              categoryIds: place.suggestedCategoryId != null
                  ? [place.suggestedCategoryId!]
                  : const [],
            );
            await expProvider.updateExpense(
              savedExpense.copyWith(locationId: newLoc.id),
            );
          }
        }
      }

      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    final wp = context.watch<WalletProvider>();
    final lp = context.watch<LocationProvider>();
    // When editing, show the location the record was originally saved with,
    // not wherever the device happens to be right now.
    // Prefer the live saved-location name (picks up renames); fall back to
    // the snapshot taken when the record was made — covers both an unsaved
    // OSM pick and a saved location that's since been deleted.
    final displayLocationName = _isEdit
        ? (lp.locations
                  .where((l) => l.id == widget.existingExpense!.locationId)
                  .firstOrNull
                  ?.name ??
              widget.existingExpense!.locationName)
        : _selectedLocationCandidate?.name;
    final cats = _isIncome ? bp.incomeCategories : bp.categories;
    final accentColor = _isIncome ? AppColors.budgetGreen : AppColors.primary;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.primaryDark,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              _isEdit ? 'Edit Record' : 'Add Record',
              style: const TextStyle(color: Colors.white),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Input method row (add only) ──────────────────────
                    if (!_isEdit) ...[
                      Row(
                        children: [
                          _MethodCard(
                            icon: Icons.camera_alt_outlined,
                            label: 'Scan receipt',
                            sub: 'Auto-fill via OCR',
                            selected: false,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ScanReceiptScreen(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _MethodCard(
                            icon: Icons.mic_outlined,
                            label: 'Voice input',
                            sub: 'Speak your expense',
                            selected: false,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const VoiceInputScreen(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _MethodCard(
                            icon: Icons.edit_outlined,
                            label: 'Manual entry',
                            sub: 'Selected',
                            selected: true,
                            onTap: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── Expense / Income toggle ───────────────────────────
                    if (!_isEdit) ...[
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEEEEE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            _TypeTab(
                              label: 'Expense',
                              icon: Icons.arrow_upward_rounded,
                              selected: !_isIncome,
                              color: AppColors.budgetRed,
                              onTap: () => _switchType('expense'),
                            ),
                            _TypeTab(
                              label: 'Income',
                              icon: Icons.arrow_downward_rounded,
                              selected: _isIncome,
                              color: AppColors.budgetGreen,
                              onTap: () => _switchType('income'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // ── AI location banner ───────────────────────────────
                    if (_selectedLocationCandidate != null &&
                        !_isEdit &&
                        !_isIncome)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF8E1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFE082)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: AppColors.budgetYellow,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _selectedCategory != null
                                    ? 'At ${_selectedLocationCandidate!.name} — ${_selectedCategory!.icon} ${_selectedCategory!.name} pre-selected. Change below if needed.'
                                    : 'At ${_selectedLocationCandidate!.name} — select a category below.',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF7C5800),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // ── Amount ───────────────────────────────────────────
                    const Text(
                      'Amount (RM)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: accentColor,
                      ),
                      decoration: InputDecoration(
                        prefixText: 'RM ',
                        prefixStyle: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                        hintText: '0.00',
                        border: UnderlineInputBorder(
                          borderSide: BorderSide(color: accentColor, width: 2),
                        ),
                        enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFFE0E0E0)),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: accentColor, width: 2),
                        ),
                        filled: false,
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter an amount';
                        if (double.tryParse(v) == null ||
                            double.parse(v) <= 0) {
                          return 'Enter a valid amount';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // ── Category ─────────────────────────────────────────
                    const Text(
                      'Category',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: cats.map((c) {
                        final selected = _selectedCategory?.id == c.id;
                        final color = AppColors.fromHex(c.colorHex);
                        return GestureDetector(
                          onTap: () => setState(() {
                            _selectedCategory = c;
                            _categoryManuallySet = true;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withValues(alpha: 0.12)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: selected
                                    ? color
                                    : const Color(0xFFE0E0E0),
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  c.icon,
                                  style: const TextStyle(fontSize: 15),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  c.name.split(' ').first,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: selected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: selected
                                        ? color
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    // ── Wallet ────────────────────────────────────────────
                    const Text(
                      'Wallet',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Regular wallet picker (hidden when savings goal selected)
                    if (_selectedGoal == null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: DropdownButton<WalletModel>(
                          value: _selectedWallet,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: wp.wallets
                              .map(
                                (w) => DropdownMenuItem(
                                  value: w,
                                  child: Row(
                                    children: [
                                      Text(
                                        w.icon,
                                        style: const TextStyle(fontSize: 18),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(w.name),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _selectedWallet = v),
                        ),
                      ),
                    // Savings goal wallet (only for expenses, not edit)
                    if (!_isEdit && !_isIncome) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: _selectedGoal != null
                            ? () => setState(() {
                                _selectedGoal = null;
                                _selectedWallet = wp.defaultWallet;
                              })
                            : _pickSavingsGoal,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: _selectedGoal != null
                                ? AppColors.primary.withValues(alpha: 0.06)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _selectedGoal != null
                                  ? AppColors.primary
                                  : const Color(0xFFE0E0E0),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Text('🎯', style: TextStyle(fontSize: 18)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _selectedGoal != null
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _selectedGoal!.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                          Text(
                                            'Available: RM ${_selectedGoal!.currentAmount.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      )
                                    : const Text(
                                        'Pay from Savings Goal',
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 14,
                                        ),
                                      ),
                              ),
                              Icon(
                                _selectedGoal != null
                                    ? Icons.close
                                    : Icons.chevron_right,
                                color: AppColors.textSecondary,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    // ── Date ─────────────────────────────────────────────
                    const Text(
                      'Date',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: _pickDate,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calendar_today_outlined,
                              color: accentColor,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              DateFormat('d MMM yyyy').format(_selectedDate),
                              style: const TextStyle(fontSize: 15),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.arrow_drop_down,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Details ───────────────────────────────────────────
                    const Text(
                      'Details',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _descCtrl,
                      maxLength: 100,
                      decoration: InputDecoration(
                        hintText: _isIncome
                            ? 'e.g. Monthly salary'
                            : 'e.g. Lunch at Mamak',
                        counterText: '',
                      ),
                    ),

                    // ── Location (auto-detected, expenses only) ───────────
                    if (_isEdit &&
                        displayLocationName != null &&
                        !_isIncome) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Location',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE0E0E0)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: AppColors.budgetRed,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              displayLocationName,
                              style: const TextStyle(fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                    ] else if (!_isEdit &&
                        _detectingLocation &&
                        !_isIncome) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Location',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: const [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Detecting nearby places...',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ] else if (!_isEdit && !_isIncome) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Location',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (_locationCandidates.length > 1) ...[
                        const SizedBox(height: 4),
                        const Text(
                          'More than one place nearby — pick the right one.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                      if (_locationCandidates.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _locationCandidates.map((cand) {
                            final selected = _selectedLocationCandidate == cand;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedLocationCandidate = cand;
                                  _manualLocationCtrl.clear();
                                });
                                _suggestCategoryFor(cand);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? AppColors.primary.withValues(
                                          alpha: 0.12,
                                        )
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: selected
                                        ? AppColors.primary
                                        : const Color(0xFFE0E0E0),
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      cand.emoji,
                                      style: const TextStyle(fontSize: 15),
                                    ),
                                    const SizedBox(width: 6),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 160,
                                      ),
                                      child: Text(
                                        cand.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: _manualLocationCtrl,
                        onChanged: (val) {
                          if (val.trim().isNotEmpty &&
                              _selectedLocationCandidate != null) {
                            setState(() => _selectedLocationCandidate = null);
                          }
                        },
                        decoration: const InputDecoration(
                          hintText: 'Or type a location (optional)',
                          helperText:
                              'Useful if you\'re offline and nothing was detected',
                        ),
                      ),
                    ],

                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: accentColor,
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(_isEdit ? 'Update Record' : 'Save Record'),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A place within geofence range of the current position — either a
/// location the user has explicitly saved, or an unsaved place found via a
/// live OSM lookup. [locationId] is set only for the former.
class _LocationCandidate {
  final String name;
  final String emoji;
  final String? locationId;
  final String? suggestedCategoryId;
  final double distanceMeters;
  final double latitude;
  final double longitude;

  const _LocationCandidate({
    required this.name,
    required this.emoji,
    this.locationId,
    this.suggestedCategoryId,
    required this.distanceMeters,
    required this.latitude,
    required this.longitude,
  });
}

class _TypeTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _TypeTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? color : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? color : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  const _MethodCard({
    required this.icon,
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.primarySurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : const Color(0xFFE0E0E0),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? AppColors.primary : AppColors.textSecondary,
                size: 24,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                sub,
                style: TextStyle(
                  fontSize: 10,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
