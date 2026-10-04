// Recent searches (4 Oct 2026) - TikTok / Facebook style: what I searched
// for and which accounts I opened from search, newest first, max 20.
//
// Saved with the ACCOUNT (so it follows me to a new phone) in ONE doc:
//   users/{uid}/private/searchHistory  { items: [...], updatedAt }
// so opening Search costs 1 read and saving costs 1 write - never one doc
// per search. Only I can read/write it (firestore.rules, `private`).
// A copy is kept on the phone (SharedPreferences) so the list shows
// instantly, even offline; the Firestore copy replaces it once it loads.
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistoryItem {
  /// 'text' (a typed search) or 'user' (an account opened from search).
  final String type;
  final String text; // text: the words searched
  final String userId; // user: their uid
  final String name; // user: name at the time
  final String photo; // user: photo at the time

  const SearchHistoryItem.text(this.text)
      : type = 'text',
        userId = '',
        name = '',
        photo = '';

  const SearchHistoryItem.user({
    required this.userId,
    required this.name,
    required this.photo,
  })  : type = 'user',
        text = '';

  bool get isUser => type == 'user';

  // Same entry = same account, or the same words (any letter case).
  String get key => isUser ? 'u:$userId' : 't:${text.toLowerCase()}';

  Map<String, dynamic> toJson() => isUser
      ? {'type': 'user', 'id': userId, 'name': name, 'photo': photo}
      : {'type': 'text', 'q': text};

  static SearchHistoryItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['type'] == 'user') {
      final String id = (raw['id'] as String?) ?? '';
      if (id.isEmpty) return null;
      return SearchHistoryItem.user(
        userId: id,
        name: (raw['name'] as String?) ?? 'User',
        photo: (raw['photo'] as String?) ?? '',
      );
    }
    final String q = ((raw['q'] as String?) ?? '').trim();
    return q.isEmpty ? null : SearchHistoryItem.text(q);
  }
}

class SearchHistory {
  SearchHistory._();
  static final SearchHistory instance = SearchHistory._();

  static const int maxItems = 20;

  /// Newest first. Listen to it (ValueListenableBuilder).
  final ValueNotifier<List<SearchHistoryItem>> items =
      ValueNotifier(const <SearchHistoryItem>[]);

  String? _loadedFor;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('private')
          .doc('searchHistory');

  String _prefsKey(String uid) => 'fly_search_history_$uid';

  /// Shows the phone's copy at once, then the account's copy. Call when
  /// Search opens; cheap to call again (one read per app run per account).
  Future<void> load() async {
    final String? uid = _uid;
    if (uid == null || _loadedFor == uid) return;
    _loadedFor = uid;
    items.value = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey(uid));
      if (raw != null && raw.isNotEmpty && _uid == uid) {
        items.value = _decode(jsonDecode(raw));
      }
    } catch (_) {}
    try {
      final snap = await _doc(uid).get();
      final remote = _decode(snap.data()?['items']);
      if (_uid == uid) {
        items.value = remote;
        await _saveLocal(uid, remote);
      }
    } catch (_) {
      // Offline - the phone's copy stays; try again next app run.
      _loadedFor = null;
    }
  }

  List<SearchHistoryItem> _decode(Object? raw) {
    if (raw is! List) return const [];
    final out = <SearchHistoryItem>[];
    for (final e in raw) {
      final item = SearchHistoryItem.fromJson(e);
      if (item != null) out.add(item);
      if (out.length >= maxItems) break;
    }
    return out;
  }

  /// Remembers typed words (e.g. after pressing search or opening a result).
  Future<void> addText(String text) async {
    final String q = text.trim();
    if (q.isEmpty || q.length > 60) return;
    await _put(SearchHistoryItem.text(q));
  }

  /// Remembers an account opened from search.
  Future<void> addUser(String userId, String name, String photo) async {
    if (userId.isEmpty) return;
    await _put(
        SearchHistoryItem.user(userId: userId, name: name, photo: photo));
  }

  Future<void> remove(SearchHistoryItem item) async {
    final next = items.value.where((e) => e.key != item.key).toList();
    await _save(next);
  }

  Future<void> clear() => _save(const []);

  // Moves [item] to the top (no duplicates), capped at [maxItems].
  Future<void> _put(SearchHistoryItem item) async {
    final next = <SearchHistoryItem>[
      item,
      ...items.value.where((e) => e.key != item.key),
    ];
    if (next.length > maxItems) next.removeRange(maxItems, next.length);
    // Same order as before - nothing to write.
    if (listEquals(next.map((e) => e.key).toList(),
        items.value.map((e) => e.key).toList())) {
      return;
    }
    await _save(next);
  }

  Future<void> _save(List<SearchHistoryItem> next) async {
    final String? uid = _uid;
    if (uid == null) return;
    items.value = List.unmodifiable(next);
    await _saveLocal(uid, next);
    try {
      await _doc(uid).set({
        'items': next.map((e) => e.toJson()).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Firestore queues the write offline and sends it later.
    }
  }

  Future<void> _saveLocal(String uid, List<SearchHistoryItem> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey(uid), jsonEncode(list.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }
}
