// A lightweight, on-device text filter - the INSTANT, offline first step
// of text moderation. moderation_service.dart runs it first, then asks the
// Worker (POST /moderate-text), which knows far more (Zawgyi Burmese,
// "f u c k" tricks, links, fake official names). This file only needs to
// catch the obvious cases when the phone is offline.
//
// 21 Oct 2026 fixes (it used to block normal words and miss others):
//   - English is matched per WORD, not "anywhere in the text": "spicy",
//     "Dickson", "Scunthorpe" are no longer blocked;
//   - Burmese words are found even with spaces / dots / zero-width
//     characters between the letters, only on a syllable boundary
//     (ကောင် is not matched inside ကောင်း), and never inside a normal word
//     from [_burmeseAllowed] (ကုလားထိုင် = chair);
//   - the Telegram / WhatsApp link check never worked (the text's dots were
//     removed but the list's were not) - links are now matched separately.
// Removed from the list: မိန်းမကလေး ("little girl", a normal phrase) and
// ကျားကောင် ("tiger").
//
// Keep this list SHORT and in step with the Worker's lists ("Text
// moderation" in cloudflare/livekit_token_worker.js) - the Worker is the
// one to grow from real reports (no new APK needed there).
class ContentFilter {
  ContentFilter._();

  // A word that CONTAINS one of these is blocked (motherfucker).
  static const List<String> _englishAnywhere = [
    'fuck',
    'nigger',
    'nigga',
    'faggot',
    'shit',
  ];

  // A word that STARTS with one of these is blocked (bitches, shitty).
  static const List<String> _englishPrefix = [
    'bitch',
    'cunt',
    'whore',
    'slut',
    'bastard',
    'asshole',
  ];

  // Only the word itself (+ s/es/ed/er/ers/ing) is blocked: "dick",
  // "dicks" - but not "Dickson".
  static const List<String> _englishExact = [
    'dick',
    'pussy',
    'chink',
    'retard',
  ];

  static const List<String> _englishSuffixes = [
    '',
    's',
    'es',
    'ed',
    'er',
    'ers',
    'ing',
  ];

  static const List<String> _burmeseBlocked = [
    'လီး',
    'လိုး',
    'စောက်',
    'ခွေးမသား',
    'ခွေးကောင်',
    'ကုလား',
  ];

  // Normal words that contain a blocked Burmese word.
  static const List<String> _burmeseAllowed = [
    'ကုလားထိုင်',
    'ကုလားပဲ',
    'ကုလားအုတ်',
    'ကုလားကာ',
    'မတ်စောက်',
    'တောင်စောက်',
  ];

  static final RegExp _spamLink = RegExp(
      r'(^|[^a-z0-9])(t\.me|telegram\.me|wa\.me|chat\.whatsapp\.com)([^a-z0-9]|$)');

  static const Map<String, String> _leet = {
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

  // Everything that is not a Burmese letter/mark or our '|' break
  // (spaces, dots, emoji, zero-width characters...).
  static final RegExp _notBurmese = RegExp(r'[^က-႟|]');

  /// Returns true if [text] contains blocked content (profanity, slurs or
  /// a Telegram/WhatsApp link).
  static bool containsBlockedContent(String text) {
    if (text.trim().isEmpty) return false;
    final String lower = text.toLowerCase();

    final String linkText =
        lower.replaceAllMapped(RegExp(r'\s*([./])\s*'), (m) => m.group(1)!);
    if (_spamLink.hasMatch(linkText)) return true;

    for (final String token in lower.split(RegExp(r'[^a-z0-9@$!*]+'))) {
      if (token.isEmpty || !RegExp(r'[a-z]').hasMatch(token)) continue;
      if (_englishWordBlocked(_cleanWord(token))) return true;
    }

    return _burmeseBlockedIn(text);
  }

  // sh1t -> shit, f*ck -> fck, fuuuuck -> fuck.
  static String _cleanWord(String token) {
    final StringBuffer b = StringBuffer();
    for (final String c in token.split('')) {
      if (c == '*') continue;
      b.write(_leet[c] ?? c);
    }
    return b
        .toString()
        .replaceAllMapped(RegExp(r'(.)\1{2,}'), (m) => m.group(1)!);
  }

  static bool _englishWordBlocked(String w) {
    for (final String x in _englishAnywhere) {
      if (w.contains(x)) return true;
    }
    for (final String x in _englishPrefix) {
      if (w.startsWith(x)) return true;
    }
    for (final String x in _englishExact) {
      for (final String sfx in _englishSuffixes) {
        if (w == '$x$sfx') return true;
      }
    }
    return false;
  }

  static String _burmeseSqueeze(String text) {
    return text
        .replaceAll(RegExp(r'[a-zA-Z]+'), '|')
        .replaceAll(_notBurmese, '');
  }

  static bool _burmeseBlockedIn(String text) {
    if (!RegExp(r'[က-႟]').hasMatch(text)) return false;
    final String s = _burmeseSqueeze(text);
    for (final String bad in _burmeseBlocked) {
      int from = 0;
      while (true) {
        final int i = s.indexOf(bad, from);
        if (i < 0) break;
        from = i + 1;
        final int end = i + bad.length;
        // The syllable goes on (a vowel/medial/final mark follows).
        if (end < s.length) {
          final int next = s.codeUnitAt(end);
          if (next >= 0x102B && next <= 0x103E) continue;
        }
        if (_insideAllowed(s, i, bad.length)) continue;
        return true;
      }
    }
    return false;
  }

  static bool _insideAllowed(String s, int start, int length) {
    for (final String a in _burmeseAllowed) {
      int from = 0;
      while (true) {
        final int i = s.indexOf(a, from);
        if (i < 0) break;
        if (i <= start && start + length <= i + a.length) return true;
        from = i + 1;
      }
    }
    return false;
  }
}
