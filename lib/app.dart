import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/auth/providers/auth_provider.dart';
import 'features/auth/screens/forgot_password_screen.dart';
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
import 'features/loans/providers/loan_provider.dart';
import 'features/loans/screens/loans_screen.dart';
import 'features/ai_advice/providers/chat_history_provider.dart';
import 'features/profile/screens/manage_categories_screen.dart';
import 'features/security/screens/app_lock_gate.dart';
import 'features/wallet/providers/wallet_provider.dart';
import 'shared/services/navigation_service.dart';
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
        ChangeNotifierProvider(create: (_) => LoanProvider()),
        ChangeNotifierProvider(create: (_) => ChatHistoryProvider()),
        ChangeNotifierProvider(create: (_) => WalletProvider()..init()),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'SmartSpend',
        theme: AppTheme.light,
        debugShowCheckedModeBanner: false,
        // Wraps whichever route is currently on top of the Navigator stack,
        // not just `home` — so the lock screen still shows up even if the
        // app was backgrounded while several screens deep (e.g. sitting on
        // Passcode settings, Add Expense, etc.), not only when idle on Home.
        builder: (context, child) => AppLockGate(child: child!),
        // App opens directly — no login required
        home: const MainShell(),
        routes: {
          '/login': (_) => const LoginScreen(),
          '/register': (_) => const RegisterScreen(),
          '/forgot-password': (_) => const ForgotPasswordScreen(),
          '/home': (_) => const MainShell(),
          '/home-profile': (_) => const MainShell(initialIndex: 3),
          '/alerts': (_) => const AlertsScreen(),
          '/budget': (_) => const BudgetScreen(),
          '/expenses': (_) => const ExpenseListScreen(),
          '/add-expense': (_) => const AddExpenseScreen(),
          '/profile': (_) => const ProfileScreen(),
          '/ai-advice': (_) => const AiAdviceScreen(),
          '/savings-goals': (_) => const SavingsGoalsScreen(),
          '/loans': (_) => const LoansScreen(),
          '/manage-categories': (_) => const ManageCategoriesScreen(),
        },
      ),
    );
  }
}
