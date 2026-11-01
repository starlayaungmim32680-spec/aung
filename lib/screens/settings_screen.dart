import 'package:flutter/material.dart';
import 'blocked_users_screen.dart';
import 'sound_moderation.dart';
import 'account_status_screen.dart';

// Fly's settings hub - starts with just Blocked accounts, but gives
// future settings (notifications, privacy, etc.) a proper home instead
// of piling onto profile_screen.dart's 3-dot menu.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
        ],
      ),
    );
  }
}
