import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// A simple wrapper around flutter_local_notifications for showing chat alerts
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  // The plugin itself is set up (in this isolate) - separate from
  // _initialized, which also covers the permission prompts.
  static bool _pluginReady = false;

  // A chat the person asked to open by tapping a message notification:
  // {'userId', 'name', 'photo'} of the other person. MainNavigationScreen
  // listens to this and opens that chat, then sets it back to null.
  static final ValueNotifier<Map<String, String>?> pendingChat =
      ValueNotifier<Map<String, String>?>(null);

  // One notification per conversation (like Messenger): a newer message
  // from the same person replaces the older one instead of stacking.
  static int chatNotificationId(String chatId) => chatId.hashCode & 0x7ffffff0;

  static const AndroidInitializationSettings _androidInit =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  // Fixed ID for the incoming-call notification so show()/cancel() always
  // target the same one.
  static const int _callNotificationId = 999999;

  // Long-short-long-short, repeating for the notification's own life -
  // reads as "someone is calling", not "you have a message".
  static final Int64List _callVibrationPattern =
      Int64List.fromList([0, 800, 400, 800, 400, 800, 400, 800]);

  // Sets up the notification plugin and asks for permission. Call once at startup.
  static Future<void> init() async {
    if (_initialized) return;

    const InitializationSettings settings = InitializationSettings(
      android: _androidInit,
    );

    await _plugin.initialize(
      settings,
      // Tapped while Fly is running (foreground or background).
      onDidReceiveNotificationResponse: (response) =>
          _openChatFromPayload(response.payload),
    );
    _pluginReady = true;

    // Tapped while Fly was fully closed - the tap is what started the app.
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _openChatFromPayload(launch!.notificationResponse?.payload);
      }
    } catch (_) {}

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

  static void _openChatFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final Map<String, dynamic> data =
          jsonDecode(payload) as Map<String, dynamic>;
      final String userId = (data['userId'] as String?) ?? '';
      if (userId.isEmpty) return;
      pendingChat.value = {
        'userId': userId,
        'name': (data['name'] as String?) ?? 'User',
        'photo': (data['photo'] as String?) ?? '',
      };
    } catch (_) {}
  }

  // Shows a chat message notification. With [chatId] it replaces that
  // conversation's previous notification; with [senderId] a tap opens the
  // chat. Works from the background push isolate too (see main.dart) -
  // it sets the plugin up on its own there, without asking for permission.
  static Future<void> showMessageNotification({
    required String title,
    required String body,
    String? chatId,
    String? senderId,
    String? senderPhoto,
  }) async {
    try {
      if (!_pluginReady) {
        await _plugin.initialize(
          const InitializationSettings(android: _androidInit),
        );
        _pluginReady = true;
      }

      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        icon: '@drawable/ic_notification',
        styleInformation: BigTextStyleInformation(body),
      );

      final NotificationDetails details =
          NotificationDetails(android: androidDetails);

      await _plugin.show(
        chatId != null && chatId.isNotEmpty
            ? chatNotificationId(chatId)
            : DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        details,
        payload: senderId == null || senderId.isEmpty
            ? null
            : jsonEncode({
                'userId': senderId,
                'name': title,
                'photo': senderPhoto ?? '',
              }),
      );
    } catch (_) {
      // A notification failing must never break anything else.
    }
  }

  // Whether this conversation's notification is in the tray right now.
  static Future<bool> isChatNotificationShowing(String chatId) async {
    try {
      final AndroidFlutterLocalNotificationsPlugin? android =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final active = await android?.getActiveNotifications();
      final int id = chatNotificationId(chatId);
      return active?.any((n) => n.id == id) ?? false;
    } catch (_) {
      return false;
    }
  }

  // Removes a conversation's notification (e.g. when that chat is opened).
  static Future<void> cancelChatNotification(String chatId) async {
    try {
      await _plugin.cancel(chatNotificationId(chatId));
    } catch (_) {}
  }

  // Shows a full-screen incoming-call notification. If the phone screen is
  // off or locked right now, this wakes it up and brings Fly's already-open
  // IncomingCallScreen to the front (see MainActivity's showWhenLocked /
  // turnScreenOn flags in AndroidManifest.xml).
  //
  // Sound/vibration are turned ON here (not left to IncomingCallScreen's
  // own ringtone) because that screen only actually appears if the
  // phone's full-screen-intent permission is granted - on phones where
  // it isn't, this notification is the only thing the person sees/hears,
  // so it needs to be audible on its own rather than sitting silent in
  // the tray. If IncomingCallScreen does also open, both playing briefly
  // together is a minor redundancy, not a real problem.
  //
  // Wrapped in try/catch: a notification failure (missing permission,
  // OEM restriction, etc.) must never stop the incoming-call screen itself
  // from showing.
  static Future<void> showIncomingCallNotification({
    required String callerName,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails =
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
        playSound: true,
        enableVibration: true,
        vibrationPattern: _callVibrationPattern,
        visibility: NotificationVisibility.public,
        timeoutAfter: 45000,
        icon: '@drawable/ic_notification',
      );

      final NotificationDetails details =
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

  // Asks for notification permission, grabs this device's FCM token, and
  // saves it to the signed-in user's profile - that's what lets another
  // user's device find this one to wake it for an incoming call (see
  // call_push_service.dart). Also keeps the saved token current if it
  // ever rotates. Call once after login.
  //
  // Returns null on success, or a short description of what went wrong -
  // used by the "Push notifications" row in wallet_screen.dart so this
  // can be checked/retried right from the app, without needing to dig
  // through the Firebase Console to see whether it worked.
  static Future<String?> registerAndSaveToken() async {
    final messaging = FirebaseMessaging.instance;

    NotificationSettings settings;
    try {
      settings = await messaging.requestPermission();
    } catch (e) {
      return 'Could not request permission: $e';
    }
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return "Notification permission was denied - check the phone's "
          'settings for Fly and allow notifications, then try again.';
    }

    String? token;
    try {
      token = await messaging.getToken();
    } catch (e) {
      return 'Could not get a device token: $e';
    }
    if (token == null || token.isEmpty) {
      return 'Device token came back empty - Google Play Services may be '
          'missing or out of date on this phone.';
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'Not signed in.';

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
    } catch (e) {
      return 'Could not save the token to Firestore: $e';
    }

    messaging.onTokenRefresh.listen(_saveToken);
    return null;
  }

  static Future<void> _saveToken(String? token) async {
    if (token == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
    } catch (_) {}
  }
}
