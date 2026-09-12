import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

// A previously logged-in account, remembered on THIS device only, purely
// so the login screen can offer a "tap to fill your email" chip when
// switching between accounts. Deliberately holds nothing but what's
// already public-ish profile info - never a password, never an auth
// token - signing in still always requires typing the password fresh.
class RecentAccount {
  final String email;
  final String displayName;
  final String photoUrl;

  const RecentAccount({
    required this.email,
    required this.displayName,
    required this.photoUrl,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'displayName': displayName,
        'photoUrl': photoUrl,
      };

  factory RecentAccount.fromJson(Map<String, dynamic> json) => RecentAccount(
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        photoUrl: json['photoUrl'] as String? ?? '',
      );
}

class RecentAccountsStore {
  static const _key = 'fly_recent_accounts';
  static const _maxAccounts = 5;

  static Future<List<RecentAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => RecentAccount.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted/old-format data shouldn't crash the login screen -
      // just start with an empty list again.
      return [];
    }
  }

  // Adds/updates an account at the front of the list (most-recent-first),
  // de-duplicated by email, capped at _maxAccounts so this can't grow
  // forever on a shared device.
  static Future<void> remember(RecentAccount account) async {
    if (account.email.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await load();
    final updated = [
      account,
      ...current
          .where((a) => a.email.toLowerCase() != account.email.toLowerCase()),
    ].take(_maxAccounts).toList();
    await prefs.setString(
        _key, jsonEncode(updated.map((a) => a.toJson()).toList()));
  }

  // Removes one remembered account (e.g. the person tapped "x" on its
  // chip) - only forgets the local shortcut, doesn't touch their actual
  // Fly account.
  static Future<void> forget(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await load();
    final updated = current
        .where((a) => a.email.toLowerCase() != email.toLowerCase())
        .toList();
    await prefs.setString(
        _key, jsonEncode(updated.map((a) => a.toJson()).toList()));
  }
}
