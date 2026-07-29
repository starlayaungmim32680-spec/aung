import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// A simple wrapper around flutter_local_notifications for showing chat alerts
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Fixed ID for the incoming-call notification so show()/cancel() always
  // target the same one.
  static const int _callNotificationId = 999999;

  // Sets up the notification plugin and asks for permission. Call once at startup.
  static Future<void> init() async {
    if (_initialized) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(settings);

    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation();
    try {
      await androidPlugin?.requestNotificationsPermission();
    } catch (_) {}
    try {
      // Needed on Android 14+ so the incoming-call notification is allowed
      // to pop the full-screen ringing UI over the lock screen. Wrapped in
      // try/catch since older plugin/OS combos may not support this call.
      await androidPlugin?.requestFullScreenIntentPermission();
    } catch (_) {}

    _initialized = true;
  }

  // Shows a notification with the given title and body
  static Future<void> showMessageNotification({
    required String title,
    required String body,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for new chat messages',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_notification',
    );

    const NotificationDetails details =
        NotificationDetails(android: androidDetails);

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  // Shows a full-screen incoming-call notification. If the phone screen is
  // off or locked right now, this wakes it up and brings Fly's already-open
  // IncomingCallScreen to the front (see MainActivity's showWhenLocked /
  // turnScreenOn flags in AndroidManifest.xml). Sound/vibration are left off
  // here since IncomingCallScreen already plays its own ringtone + haptics.
  //
  // Wrapped in try/catch: a notification failure (missing permission,
  // OEM restriction, etc.) must never stop the incoming-call screen itself
  // from showing.
  static Future<void> showIncomingCallNotification({
    required String callerName,
  }) async {
    try {
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'incoming_calls',
        'Incoming Calls',
        channelDescription: 'Full-screen alert for incoming Fly calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
        visibility: NotificationVisibility.public,
        timeoutAfter: 45000,
        icon: '@drawable/ic_notification',
      );

      const NotificationDetails details =
          NotificationDetails(android: androidDetails);

      await _plugin.show(
        _callNotificationId,
        callerName,
        'Incoming Fly call...',
        details,
      );
    } catch (_) {
      // Ignore — the IncomingCallScreen navigation still happens regardless.
    }
  }

  // Dismisses the incoming-call notification (call accepted, declined, or
  // the screen was closed some other way).
  static Future<void> cancelIncomingCallNotification() async {
    try {
      await _plugin.cancel(_callNotificationId);
    } catch (_) {}
  }
}
