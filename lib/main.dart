import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'notification_service.dart';
import 'call_kit_service.dart';
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
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] != 'incoming_call') return;
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
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
}

class FlyApp extends StatelessWidget {
  const FlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fly',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
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
          _ensureUserDoc(snapshot.data!);
          NotificationService.registerAndSaveToken();
          CallKitService.requestPermissions();
          return const MainNavigationScreen();
        }

        // No user logged in - show login screen
        return const LoginScreen();
      },
    );
  }
}
