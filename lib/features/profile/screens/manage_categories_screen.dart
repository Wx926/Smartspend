import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../shared/models/category_model.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../features/auth/providers/auth_provider.dart';

class ManageCategoriesScreen extends StatefulWidget {
  const ManageCategoriesScreen({super.key});

  @override
  State<ManageCategoriesScreen> createState() =>
      _ManageCategoriesScreenState();
}

class _ManageCategoriesScreenState extends State<ManageCategoriesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  List<CategoryModel> _expenseCategories = [];
  List<CategoryModel> _incomeCategories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final auth = context.read<AuthProvider>();
    if (auth.isLoggedIn) {
      _expenseCategories =
          await SupabaseService.instance.getCategories(type: 'expense');
      _incomeCategories =
          await SupabaseService.instance.getCategories(type: 'income');
    } else {
      _expenseCategories =
          LocalStorageService.instance.getCategories(type: 'expense');
      _incomeCategories =
          LocalStorageService.instance.getCategories(type: 'income');
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
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
        onPressed: () => _showAddCategorySheet(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _categoryList(_expenseCategories),
                _categoryList(_incomeCategories),
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
        final color =
            Color(int.parse('FF${cat.colorHex}', radix: 16));
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
    String selectedIcon = '💡';
    String selectedColor = 'FF6B35';
    String selectedType = _tabs.index == 0 ? 'expense' : 'income';

    final icons = [
      '💡', '🏠', '🚀', '🎯', '💎', '🛒', '✈️', '📱',
      '🎮', '📚', '💪', '🍕', '☕', '🎁', '🚌', '⚡',
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
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('New Category',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Category name'),
                ),
                const SizedBox(height: 16),
                const Text('Choose Icon',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: icons.map((icon) {
                    final selected = selectedIcon == icon;
                    return GestureDetector(
                      onTap: () => setSheet(() => selectedIcon = icon),
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
                          child: Text(icon,
                              style: const TextStyle(fontSize: 20)),
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
                    final color =
                        Color(int.parse('FF$hex', radix: 16));
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
                              ? Border.all(
                                  color: Colors.black54, width: 3)
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                const Text('Type',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Row(
                  children: ['expense', 'income'].map((type) {
                    final selected = selectedType == type;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setSheet(() => selectedType = type),
                        child: Container(
                          margin: EdgeInsets.only(
                              right: type == 'expense' ? 8 : 0),
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.primary
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Text(
                              type[0].toUpperCase() + type.substring(1),
                              style: TextStyle(
                                color: selected
                                    ? Colors.white
                                    : AppColors.textPrimary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
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

                      // Categories table has no user_id — stored as non-default
                      // For guest: not supported (Supabase RLS blocks anon insert)
                      final auth = context.read<AuthProvider>();
                      if (!auth.isLoggedIn) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Sign in to add custom categories')),
                        );
                        return;
                      }

                      // Add locally and reload (Supabase insert requires admin policy)
                      final newCat = CategoryModel(
                        id: DateTime.now()
                            .millisecondsSinceEpoch
                            .toString(),
                        name: name,
                        icon: selectedIcon,
                        colorHex: selectedColor,
                        type: selectedType,
                        isDefault: false,
                      );

                      setState(() {
                        if (selectedType == 'expense') {
                          _expenseCategories.add(newCat);
                        } else {
                          _incomeCategories.add(newCat);
                        }
                      });

                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Add Category'),
                  ),
                ),
              ],
            ),
          ),
        ),
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
            onPressed: () {
              setState(() {
                _expenseCategories.removeWhere((c) => c.id == cat.id);
                _incomeCategories.removeWhere((c) => c.id == cat.id);
              });
              Navigator.pop(context);
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
