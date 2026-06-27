import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../features/budget/providers/budget_provider.dart';

class ManageCategoriesScreen extends StatefulWidget {
  const ManageCategoriesScreen({super.key});

  @override
  State<ManageCategoriesScreen> createState() =>
      _ManageCategoriesScreenState();
}

class _ManageCategoriesScreenState extends State<ManageCategoriesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bp = context.watch<BudgetProvider>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Manage Categories'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Expense'),
            Tab(text: 'Income'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddCategorySheet,
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _categoryList(bp.categories),
          _categoryList(bp.incomeCategories),
        ],
      ),
    );
  }

  Widget _categoryList(List<CategoryModel> cats) {
    if (cats.isEmpty) {
      return const Center(
        child: Text('No categories',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: cats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final cat = cats[i];
        final color = Color(int.parse('FF${cat.colorHex}', radix: 16));
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(cat.icon, style: const TextStyle(fontSize: 20)),
              ),
            ),
            title: Text(cat.name,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: cat.isDefault
                ? const Text('Default',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12))
                : null,
            trailing: cat.isDefault
                ? null
                : IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.red, size: 20),
                    onPressed: () => _confirmDelete(cat),
                  ),
          ),
        );
      },
    );
  }

  void _showAddCategorySheet() {
    final nameCtrl = TextEditingController();
    final iconCtrl = TextEditingController(text: '💡');
    String selectedIcon = '💡';
    String selectedColor = 'FF6B35';
    String selectedType = _tabs.index == 0 ? 'expense' : 'income';

    final expenseIconSuggestions = [
      '💡', '🏠', '🚀', '🎯', '💎', '🛒', '✈️', '📱',
      '🎮', '📚', '💪', '🍕', '☕', '🎁', '🚌', '⚡',
    ];
    final incomeIconSuggestions = [
      '💼', '💻', '📈', '🎁', '🤝', '💵', '🏦', '⭐',
      '🎓', '🏆', '💹', '🌟', '💰', '📊', '🔑', '⚡',
    ];

    final incomeTemplates = [
      {'name': 'Salary', 'icon': '💼', 'color': '27AE60'},
      {'name': 'Part-time Job', 'icon': '💻', 'color': '2980B9'},
      {'name': 'Investment', 'icon': '📈', 'color': 'F39C12'},
      {'name': 'Bonus', 'icon': '🎁', 'color': '8E44AD'},
      {'name': 'Allowance', 'icon': '🎓', 'color': '10B981'},
      {'name': 'Commission', 'icon': '🤝', 'color': 'E74C3C'},
    ];

    final colors = [
      'FF6B35', '4ECDC4', 'A855F7', 'F59E0B',
      '10B981', '3B82F6', '6B7280', 'E74C3C',
      '27AE60', '2980B9', 'F39C12', '8E44AD',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final iconSuggestions = selectedType == 'income'
              ? incomeIconSuggestions
              : expenseIconSuggestions;

          return Padding(
            padding: EdgeInsets.fromLTRB(
                24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('New Category',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  // ── Type selector ──────────────────────────────────────
                  const Text('Type', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Row(
                    children: ['expense', 'income'].map((type) {
                      final selected = selectedType == type;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setSheet(() => selectedType = type),
                          child: Container(
                            margin: EdgeInsets.only(right: type == 'expense' ? 8 : 0),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: selected ? AppColors.primary : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                type[0].toUpperCase() + type.substring(1),
                                style: TextStyle(
                                  color: selected ? Colors.white : AppColors.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  // ── Quick-add income templates ─────────────────────────
                  if (selectedType == 'income') ...[
                    const SizedBox(height: 16),
                    const Text('Quick add', style: TextStyle(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: incomeTemplates.map((t) {
                        return GestureDetector(
                          onTap: () => setSheet(() {
                            nameCtrl.text = t['name']!;
                            selectedIcon = t['icon']!;
                            iconCtrl.text = t['icon']!;
                            selectedColor = t['color']!;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(t['icon']!, style: const TextStyle(fontSize: 16)),
                              const SizedBox(width: 6),
                              Text(t['name']!, style: const TextStyle(fontSize: 13)),
                            ]),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 4),
                    const Text('Tap to fill — or type your own below',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                  ],

                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Category name'),
                  ),

                  // ── Icon: keyboard input + quick picks ────────────────
                  const SizedBox(height: 16),
                  const Text('Icon', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: iconCtrl,
                    style: const TextStyle(fontSize: 24),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '😊',
                      helperText: 'Type any emoji from your keyboard',
                      helperStyle: const TextStyle(fontSize: 11),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (val) {
                      final trimmed = val.trim();
                      if (trimmed.isNotEmpty) setSheet(() => selectedIcon = trimmed);
                    },
                  ),
                  const SizedBox(height: 10),
                  const Text('Quick picks',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: iconSuggestions.map((icon) {
                      final selected = selectedIcon == icon;
                      return GestureDetector(
                        onTap: () => setSheet(() {
                          selectedIcon = icon;
                          iconCtrl.text = icon;
                        }),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.primary.withValues(alpha: 0.15)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                            border: selected
                                ? Border.all(color: AppColors.primary, width: 2)
                                : null,
                          ),
                          child: Center(
                            child: Text(icon, style: const TextStyle(fontSize: 20)),
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 16),
                  const Text('Choose Color',
                      style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: colors.map((hex) {
                      final color = Color(int.parse('FF$hex', radix: 16));
                      final selected = selectedColor == hex;
                      return GestureDetector(
                        onTap: () => setSheet(() => selectedColor = hex),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(color: Colors.black54, width: 3)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;

                        final newCat = CategoryModel(
                          id: '${selectedType}_${DateTime.now().millisecondsSinceEpoch}',
                          name: name,
                          icon: selectedIcon,
                          colorHex: selectedColor,
                          type: selectedType,
                          isDefault: false,
                        );

                        await context.read<BudgetProvider>().addCategory(newCat);

                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Add Category'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _confirmDelete(CategoryModel cat) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Category'),
        content: Text('Delete "${cat.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<BudgetProvider>().removeCategory(cat);
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
