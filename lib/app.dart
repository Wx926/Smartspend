import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/auth/providers/auth_provider.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/register_screen.dart';
import 'features/budget/providers/budget_provider.dart';
import 'features/expenses/providers/expense_provider.dart';
import 'features/location/providers/location_provider.dart';
import 'features/home/screens/main_shell.dart';
import 'features/alerts/screens/alerts_screen.dart';
import 'features/budget/screens/budget_screen.dart';
import 'features/expenses/screens/expense_list_screen.dart';
import 'features/expenses/screens/add_expense_screen.dart';
import 'features/profile/screens/profile_screen.dart';
import 'features/ai_advice/screens/ai_advice_screen.dart';
import 'features/savings_goals/providers/savings_goal_provider.dart';
import 'features/savings_goals/screens/savings_goals_screen.dart';
import 'features/profile/screens/manage_categories_screen.dart';
import 'shared/theme/app_theme.dart';

class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ExpenseProvider()),
        ChangeNotifierProvider(create: (_) => BudgetProvider()),
        ChangeNotifierProvider(create: (_) => LocationProvider()),
        ChangeNotifierProvider(create: (_) => SavingsGoalProvider()),
      ],
      child: MaterialApp(
        title: 'SmartSpend',
        theme: AppTheme.light,
        debugShowCheckedModeBanner: false,
        // App opens directly — no login required
        home: const MainShell(),
        routes: {
          '/login': (_) => const LoginScreen(),
          '/register': (_) => const RegisterScreen(),
          '/home': (_) => const MainShell(),
          '/home-profile': (_) => const MainShell(initialIndex: 3),
          '/alerts': (_) => const AlertsScreen(),
          '/budget': (_) => const BudgetScreen(),
          '/expenses': (_) => const ExpenseListScreen(),
          '/add-expense': (_) => const AddExpenseScreen(),
          '/profile': (_) => const ProfileScreen(),
          '/ai-advice': (_) => const AiAdviceScreen(),
          '/savings-goals': (_) => const SavingsGoalsScreen(),
          '/manage-categories': (_) => const ManageCategoriesScreen(),
        },
      ),
    );
  }
}
