import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/main_navigation_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const FlyApp());
}

class FlyApp extends StatelessWidget {
  const FlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fly',
      debugShowCheckedModeBanner: false,
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
          // User is logged in - make sure their profile doc exists
          _ensureUserDoc(snapshot.data!);
          return const MainNavigationScreen();
        }

        // No user logged in - show login screen
        return const LoginScreen();
      },
    );
  }
}
