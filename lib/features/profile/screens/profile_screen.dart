import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/theme/app_colors.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          CircleAvatar(
            radius: 44,
            backgroundColor: AppColors.primary.withValues(alpha: 0.12),
            child: Icon(
              auth.isLoggedIn ? Icons.person : Icons.person_outline,
              size: 48,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            auth.isLoggedIn
                ? (auth.displayName.isEmpty ? auth.email : auth.displayName)
                : 'Guest User',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (!auth.isLoggedIn)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Sign in to sync data across devices\nand access advanced features.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          if (auth.isLoggedIn)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                auth.email,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          const SizedBox(height: 32),
          if (!auth.isLoggedIn) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Sign In'),
              onPressed: () => Navigator.pushNamed(context, '/login'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('Create Account'),
              onPressed: () => Navigator.pushNamed(context, '/register'),
            ),
          ],
          if (auth.isLoggedIn) ...[
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Email'),
              subtitle: Text(auth.email),
              dense: true,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.budgetRed),
              title: const Text('Sign Out',
                  style: TextStyle(color: AppColors.budgetRed)),
              onTap: () async {
                await context.read<AuthProvider>().signOut();
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
          const SizedBox(height: 40),
          const Center(
            child: Text('SmartSpend v1.0.0',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
