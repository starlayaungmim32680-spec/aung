// On-device translation for captions/comments, using Google's ML Kit.
//
// Everything here runs locally on the phone - language detection and
// translation both happen on-device via ML Kit, with no network calls to
// any Google server and no per-character billing. This is a different
// product from the paid Cloud Translation API: it's the same offline
// model that powers Google Translate's offline mode, bundled as a
// language pack the device downloads once (a few MB) and reuses after
// that. See: https://developers.google.com/ml-kit/language/translation
//
// Because it's fully offline, this also works with the app's existing
// free Firebase Spark plan - no Cloud Functions / Blaze billing needed.
//
// Fly is aimed at users on every kind of phone, including budget devices
// with weak/unreliable data connections and limited storage - the two
// things that can make the one-time language-model download fail. So
// every outcome here is one of three kinds, not just success/failure:
//   - notApplicable: nothing useful to translate (already the device's
//     language, or ML Kit doesn't support the language) - permanent,
//     the UI should stop offering translation for this text.
//   - retry: the model download or translation itself failed, most
//     likely a connectivity or storage hiccup - temporary, the UI
//     should let the user try again rather than hide the option.
//   - success: translated text.

import 'dart:ui' as ui;
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

enum TranslationStatus { success, notApplicable, retry }

class TranslationOutcome {
  final TranslationStatus status;
  final String? text; // non-null only when status == success

  const TranslationOutcome._(this.status, this.text);
  const TranslationOutcome.success(String text)
      : this._(TranslationStatus.success, text);
  const TranslationOutcome.notApplicable()
      : this._(TranslationStatus.notApplicable, null);
  const TranslationOutcome.retry() : this._(TranslationStatus.retry, null);
}

class TranslationService {
  TranslationService._();
  static final TranslationService instance = TranslationService._();

  final LanguageIdentifier _identifier =
      LanguageIdentifier(confidenceThreshold: 0.5);
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  // Reuse one OnDeviceTranslator per (source, target) language pair for
  // the lifetime of the app, instead of creating/closing one on every
  // tap - the underlying native translator is relatively expensive to
  // set up.
  final Map<String, OnDeviceTranslator> _translators = {};

  TranslateLanguage? _fromBcpCode(String code) {
    for (final TranslateLanguage lang in TranslateLanguage.values) {
      if (lang.bcpCode == code) return lang;
    }
    return null;
  }

  // Detects [text]'s language and translates it into the device's
  // current system language.
  Future<TranslationOutcome> translateToDeviceLanguage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return const TranslationOutcome.notApplicable();

    final String targetCode =
        ui.PlatformDispatcher.instance.locale.languageCode;
    final TranslateLanguage? target = _fromBcpCode(targetCode);
    // Device's own language isn't one ML Kit knows - nothing we can do.
    if (target == null) return const TranslationOutcome.notApplicable();

    String detectedCode;
    try {
      detectedCode = await _identifier.identifyLanguage(trimmed);
    } catch (_) {
      // Language ID model itself failed to load/run - on a very
      // low-storage or low-memory phone this can happen transiently.
      return const TranslationOutcome.retry();
    }
    // 'und' = undetermined; short/ambiguous text isn't worth retrying,
    // more attempts won't make ML Kit more confident about it.
    if (detectedCode == 'und') {
      return const TranslationOutcome.notApplicable();
    }

    final TranslateLanguage? source = _fromBcpCode(detectedCode);
    if (source == null || source == target) {
      return const TranslationOutcome.notApplicable();
    }

    final String key = '${source.bcpCode}_${target.bcpCode}';
    final OnDeviceTranslator translator = _translators.putIfAbsent(
      key,
      () => OnDeviceTranslator(sourceLanguage: source, targetLanguage: target),
    );

    // Each language's model is a few MB and, once downloaded, stays on
    // the device for every future translation into/out of it - so this
    // download only actually happens the first time a given language is
    // ever involved on this phone. Any failure here (no/weak signal,
    // phone almost out of storage) is treated as retryable, since it's
    // circumstantial rather than a real incompatibility.
    try {
      if (!await _modelManager.isModelDownloaded(source.bcpCode)) {
        await _modelManager.downloadModel(source.bcpCode);
      }
      if (!await _modelManager.isModelDownloaded(target.bcpCode)) {
        await _modelManager.downloadModel(target.bcpCode);
      }
    } catch (_) {
      return const TranslationOutcome.retry();
    }

    try {
      final String result = await translator.translateText(trimmed);
      return TranslationOutcome.success(result);
    } catch (_) {
      return const TranslationOutcome.retry();
    }
  }

  // Call once when the app shuts down (not per-screen - translators are
  // shared/cached for the whole app's lifetime).
  void dispose() {
    _identifier.close();
    for (final OnDeviceTranslator t in _translators.values) {
      t.close();
    }
    _translators.clear();
  }
}
