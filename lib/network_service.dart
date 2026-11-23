import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

// How good the device's ACTUAL internet connection currently is - not
// just whether a network interface (wifi/mobile) is connected. A wifi or
// mobile connection can still be present but too slow/unstable to load
// anything, which is the common case this app needs to react to, not
// just a flat "airplane mode" case.
enum NetworkStatus { offline, weak, good }

// App-wide network quality monitor. Other services (adaptive video
// quality, upload retry - later steps) read `status` to decide how to
// behave; the top banner in MainNavigationScreen reads it to show the
// user what's going on.
//
// Uses a ValueNotifier (not a per-widget Stream/setState) so any part of
// the app can listen without causing rebuilds elsewhere - the same
// flicker-avoiding pattern already used for the video control overlay.
class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  final ValueNotifier<NetworkStatus> status =
      ValueNotifier<NetworkStatus>(NetworkStatus.good);

  // 23 Nov 2026 (Scale plan 2, S4 "data saver"): true while the phone is
  // on MOBILE DATA only (no Wi-Fi / ethernet). Videos then play the 480p
  // rendition and fewer neighbours are preloaded (media_utils.dart,
  // video_preload_cache.dart, story_file_prefetch.dart) - less to
  // download for the person's data plan AND for Fly's CDN bill.
  bool _onMobileData = false;
  bool get isOnMobileData => _onMobileData;

  void _applyConnectivity(List<ConnectivityResult> results) {
    final bool hasUnmetered = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    _onMobileData =
        !hasUnmetered && results.contains(ConnectivityResult.mobile);
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _probeTimer;
  bool _initialized = false;

  // A tiny, near-empty-response endpoint used purely to measure real
  // reachability/latency, not to fetch any actual data - a 204 response
  // means the elapsed time measured is almost entirely round-trip time.
  static const String _probeUrl = 'https://www.gstatic.com/generate_204';

  // Call once, early in main() - safe to call more than once (no-op after
  // the first call).
  void init() {
    if (_initialized) return;
    _initialized = true;

    // S4: know Wi-Fi vs mobile data from the start, not only after the
    // first change event.
    Connectivity()
        .checkConnectivity()
        .then(_applyConnectivity)
        .catchError((_) {});
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      _applyConnectivity(results);
      if (results.every((r) => r == ConnectivityResult.none)) {
        status.value = NetworkStatus.offline;
      } else {
        // A network interface is up, but that alone doesn't mean it's
        // usable - probe immediately to find out for real.
        _probeOnce();
      }
    });

    // Periodic probe covers the connection quietly degrading (e.g. weak
    // mobile signal in one spot) without connectivity_plus ever firing a
    // change event, since the interface itself never actually drops.
    _probeTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _probeOnce());
    _probeOnce();
  }

  Future<void> _probeOnce() async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.parse(_probeUrl))
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        status.value = stopwatch.elapsedMilliseconds > 1500
            ? NetworkStatus.weak
            : NetworkStatus.good;
      } else {
        status.value = NetworkStatus.weak;
      }
    } catch (_) {
      stopwatch.stop();
      status.value = NetworkStatus.offline;
    }
  }

  // Stops listening (tests / a future sign-out flow). Fly keeps the
  // service for the whole run, so nothing calls this today - it also
  // keeps the two fields above "used" for the analyzer.
  void dispose() {
    _connectivitySub?.cancel();
    _probeTimer?.cancel();
    _connectivitySub = null;
    _probeTimer = null;
    _initialized = false;
  }

  // True when the app should behave conservatively - lower video
  // quality, more cautious retries, etc. Later network-resilience
  // features (adaptive video quality, upload retry) read this.
  bool get isSlowOrOffline =>
      status.value == NetworkStatus.weak ||
      status.value == NetworkStatus.offline;
}
