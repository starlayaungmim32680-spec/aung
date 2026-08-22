// A lightweight, on-device text moderation filter for captions, comments,
// and video titles.
//
// This is a first line of defense: it catches obvious profanity, hate
// speech, and spam BEFORE the text is even sent to Firestore or a video is
// uploaded to Cloudinary — so it works instantly, with no backend and no
// Blaze billing required.
//
// It is NOT a replacement for the AI-based image/video moderation service
// (the separate fly-moderation project using Detoxify + Falconsai) — that
// project still handles actual photo/video content once it's deployed.
// This filter only handles text.
//
// The word list below is a starting point, not a complete list — no fixed
// list ever fully covers real-world abuse. Expand `_blockedWords` over time
// using real reports (the Report feature already writes to the Firestore
// `reports` collection), so the list grows to match what users actually
// try to post.
class ContentFilter {
  ContentFilter._();

  // Starter blocklist. Keep this updated from real moderation reports.
  // Grouped by category purely for readability when editing this list.
  static const List<String> _blockedWords = [
    // English — profanity
    'fuck',
    'shit',
    'bitch',
    'asshole',
    'bastard',
    'slut',
    'whore',
    'dick',
    'pussy',
    'cunt',
    // English — slurs / hate speech
    'nigger',
    'nigga',
    'faggot',
    'retard',
    'chink',
    'spic',
    // Burmese — profanity / insults / slurs (expand based on real reports)
    'ခွေးကောင်',
    'ကျားကောင်',
    'ကုလား',
    'မိန်းမကလေး',
    // Spam / scam markers
    'click here to win',
    'free money',
    't.me/',
    'wa.me/',
  ];

  /// Normalizes text to catch common evasion tricks: lowercasing, removing
  /// symbols used to break up letters (f.u.c.k, f*ck), simple leetspeak
  /// substitutions (sh1t -> shit), and collapsing repeated characters
  /// (fuuuuck -> fuck). Burmese script and spacing are left untouched.
  static String _normalize(String input) {
    String s = input.toLowerCase();

    const Map<String, String> substitutions = {
      '@': 'a',
      '4': 'a',
      '3': 'e',
      '1': 'i',
      '!': 'i',
      '0': 'o',
      r'$': 's',
      '5': 's',
      '7': 't',
    };
    substitutions.forEach((from, to) {
      s = s.replaceAll(from, to);
    });

    // Strip punctuation commonly used to break up a blocked word.
    s = s.replaceAll(RegExp(r'[.\-_*]'), '');

    // Collapse 3+ repeated characters down to 1 (fuuuuck -> fuck).
    s = s.replaceAllMapped(RegExp(r'(.)\1{2,}'), (m) => m.group(1)!);

    return s;
  }

  /// Returns true if [text] contains blocked content (profanity, hate
  /// speech, or obvious spam).
  static bool containsBlockedContent(String text) {
    if (text.trim().isEmpty) return false;
    final String normalized = _normalize(text);
    for (final String word in _blockedWords) {
      if (normalized.contains(word.toLowerCase())) return true;
    }
    return false;
  }
}
