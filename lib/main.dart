import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'app_config.dart';
import 'notification_service.dart';
import 'call_kit_service.dart';
import 'chat_delivery_service.dart';
import 'network_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_navigation_screen.dart';
import 'screens/home_screen.dart' show flyRouteObserver;

// Handles an incoming-call push while the app is backgrounded or fully
// closed. Must be a top-level function (not a class method/closure) and
// keep this exact @pragma - that's what lets Android launch a fresh,
// isolated Dart engine just to run this, without opening the rest of the
// app. This isolate hasn't run the rest of main() first, so it needs its
// own Firebase.initializeApp() call before touching any Firebase API.
//
// Shows the call through CallKitService - Android's own native calling
// system (Telecom/ConnectionService) - instead of a plain notification.
// Because it's a real Android call (not just a notification asking to be
// noticed), the OS itself handles waking the screen and ringing, the
// same way WhatsApp/Messenger's calls do, rather than Fly having to
// convince Android to treat a notification as urgent enough to do that.
//
// Also handles 'call_cancelled' (sent when the caller hangs up before this
// person answers - see call_push_service.dart's sendCallCancelledPush):
// stops the native ringing screen. That's the only thing that can stop it
// when Fly was swiped away, since no Firestore listener is running then.
// No Firebase setup is needed for that - it's a purely local CallKit call.
//
// And 'chat_message' (1 Oct 2026, see call_push_service.dart's
// sendChatPush): shows the message notification and marks the message
// "Delivered" - so both work even when Fly is fully closed. When Fly is
// open, the push still arrives but this handler doesn't run (Android only
// calls it while Fly isn't in the foreground), and MainNavigationScreen's
// own listener shows the in-app alert instead.
//
// And 'friend_request' / 'friend_accept' (4 Oct 2026, the Worker's
// /friend-push): shows a friend notification; tapping it opens Friend
// Requests or the new friend's profile (NotificationService.pendingFriend).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final String? type = message.data['type'] as String?;
  if (type == 'friend_request' || type == 'friend_accept') {
    WidgetsFlutterBinding.ensureInitialized();
    await NotificationService.showFriendNotification(
      kind: message.data['type'] as String? ?? '',
      senderId: message.data['senderId'] as String? ?? '',
      senderName: message.data['senderName'] as String? ?? 'Someone',
      senderPhoto: message.data['senderPhoto'] as String? ?? '',
    );
    return;
  }
  if (type == 'call_cancelled') {
    WidgetsFlutterBinding.ensureInitialized();
    await CallKitService.dismissIncomingCall(
      message.data['roomName'] as String? ?? '',
    );
    return;
  }
  if (type == 'chat_message') {
    WidgetsFlutterBinding.ensureInitialized();
    final String chatId = message.data['chatId'] as String? ?? '';
    await NotificationService.showMessageNotification(
      title: message.data['senderName'] as String? ?? 'New message',
      body: message.data['text'] as String? ?? '',
      chatId: chatId,
      senderId: message.data['senderId'] as String?,
      senderPhoto: message.data['senderPhoto'] as String?,
    );
    if (chatId.isNotEmpty) {
      try {
        await Firebase.initializeApp(options: AppConfig.firebaseOptions);
        await ChatDeliveryService.markChatDelivered(chatId);
      } catch (_) {}
    }
    return;
  }
  if (type != 'incoming_call') return;
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: AppConfig.firebaseOptions);
  await CallKitService.showIncomingCall(
    roomName: message.data['roomName'] as String? ?? '',
    callerName: message.data['callerName'] as String? ?? 'Someone',
    callerPhoto: message.data['callerPhoto'] as String? ?? '',
    isVideo: message.data['isVideo'] == 'true',
  );
}

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // prod = aung-1756e, dev = fly-dev (app_config.dart).
  await Firebase.initializeApp(options: AppConfig.firebaseOptions);
  // Firestore already caches reads and queues writes locally on
  // Android/iOS by default - this just makes that explicit and raises the
  // cache limit past its default 40MB, so a longer scroll through the
  // feed or chat history stays available (read-only) when the connection
  // drops, instead of the oldest of it quietly getting evicted first.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  CallKitService.navigatorKey = _navigatorKey;
  // Registered once, here, so it's ready to catch an Accept/Decline tap
  // even if the app is cold-starting because of that exact tap.
  CallKitService.initListener();
  runApp(const FlyApp());
  // Notification permission setup doesn't need to finish before the user
  // sees a screen - running it after runApp() (instead of awaiting it
  // first) shaves the delay off every app launch.
  NotificationService.init();
  // Same reasoning as above: starts monitoring network quality right
  // away, but doesn't block the first frame from showing.
  NetworkService.instance.init();
}

class FlyApp extends StatelessWidget {
  const FlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fly',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      // The test app wears a red "DEV" ribbon so it's never mistaken for
      // the real one (app_config.dart).
      builder: AppConfig.isDev
          ? (context, child) => Banner(
                message: 'DEV',
                location: BannerLocation.topEnd,
                color: Colors.red,
                child: child ?? const SizedBox.shrink(),
              )
          : null,
      // Lets a playing video know when another screen is pushed on top
      // of it, so it can pause instead of playing on in the background.
      navigatorObservers: [flyRouteObserver],
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.redAccent,
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// Checks if a user is already logged in and skips the login screen if so
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  // Makes sure the logged-in user has a document in the users collection
  // so they appear in the chat user list
  Future<void> _ensureUserDoc(User user) async {
    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final doc = await docRef.get();
    if (!doc.exists) {
      await docRef.set({
        'displayName': user.email?.split('@').first ?? 'User',
        'photoUrl': '',
        'email': user.email,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            ),
          );
        }

        if (snapshot.hasData) {
          // User is logged in - make sure their profile doc exists, and
          // this device is registered to receive incoming-call pushes.
          // Call-related permissions are intentionally NOT requested here
          // - they're requested only when a call actually starts (see
          // CallKitService.showIncomingCall / the outgoing-call flow), so
          // opening the app never itself triggers a permission prompt.
          _ensureUserDoc(snapshot.data!);
          NotificationService.registerAndSaveToken();
          return const MainNavigationScreen();
        }

        // No user logged in - show login screen
        return const LoginScreen();
      },
    );
  }
}
