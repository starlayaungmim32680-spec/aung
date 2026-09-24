import 'package:flutter/material.dart';
import 'blocked_users_screen.dart';
import 'sound_moderation.dart';

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
