import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'login_screen.dart';
import 'blocked_users_screen.dart';
import 'sound_moderation.dart';
import 'account_status_screen.dart';
import 'terms_consent.dart' show kChildSafetyUrl, openFlyWebPage;

// Fly's settings hub - starts with just Blocked accounts, but gives
// future settings (notifications, privacy, etc.) a proper home instead
// of piling onto profile_screen.dart's 3-dot menu.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  // 7 Nov 2026 (Sky Pass): Log out moved here from the Profile AppBar.
  Future<void> _logout(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Log out of Fly?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "You'll need to sign in again to use Fly. If you're trying to "
          'switch to a different account, logging out and signing back in '
          'with another email is how to do that.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await FirebaseAuth.instance.signOut();
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          // 1 Nov 2026 (strikes, step C): my strikes and posting limits.
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: Colors.white),
            title: const Text('Account status',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Strikes and posting limits',
                style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountStatusScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.white),
            title: const Text('Blocked accounts',
                style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
              );
            },
          ),
          // 1 Nov 2026: Google Play's Child Safety Standards - how to
          // report, what Fly does, the child-safety contact.
          ListTile(
            leading: const Icon(Icons.child_care, color: Colors.white),
            title: const Text('Child safety',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Our standards and how to report',
                style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            trailing:
                const Icon(Icons.open_in_new, color: Colors.grey, size: 20),
            onTap: () => openFlyWebPage(context, kChildSafetyUrl),
          ),
          ListTile(
            leading: const Icon(Icons.copyright, color: Colors.white),
            title: const Text('Copyright & Sounds',
                style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const CopyrightPolicyScreen()),
              );
            },
          ),
          const Divider(color: Colors.white12, height: 24),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text('Log out',
                style: TextStyle(color: Colors.redAccent)),
            subtitle: Text(
              FirebaseAuth.instance.currentUser?.email ?? '',
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}
