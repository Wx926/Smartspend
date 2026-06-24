import 'package:flutter/material.dart';
import '../../../shared/models/savings_goal_model.dart';
import '../../../shared/services/supabase_service.dart';

class SavingsGoalProvider extends ChangeNotifier {
  final _db = SupabaseService.instance;

  List<SavingsGoalModel> _goals = [];
  bool _isLoading = false;

  List<SavingsGoalModel> get goals => _goals;
  bool get isLoading => _isLoading;

  double get totalSaved =>
      _goals.fold(0, (sum, g) => sum + g.currentAmount);

  double get totalTarget =>
      _goals.fold(0, (sum, g) => sum + g.targetAmount);

  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    try {
      _goals = await _db.getSavingsGoals();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> add(SavingsGoalModel goal) async {
    final created = await _db.insertSavingsGoal(goal);
    _goals.insert(0, created);
    notifyListeners();
  }

  Future<void> update(SavingsGoalModel goal) async {
    final updated = await _db.updateSavingsGoal(goal);
    final i = _goals.indexWhere((g) => g.id == goal.id);
    if (i != -1) _goals[i] = updated;
    notifyListeners();
  }

  Future<void> delete(String id) async {
    await _db.deleteSavingsGoal(id);
    _goals.removeWhere((g) => g.id == id);
    notifyListeners();
  }
}
