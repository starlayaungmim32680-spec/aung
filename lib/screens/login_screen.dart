import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main_navigation_screen.dart';
import 'signup_screen.dart';
import 'recent_accounts.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  late final AnimationController _bounceController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  // Drives the logo's soft glow pulse and twinkling sparkles - a separate,
  // slower cycle from the mascot's bounce above so the two don't compete
  // for attention.
  late final AnimationController _sparkleController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2, milliseconds: 200),
  )..repeat();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  List<RecentAccount> _recentAccounts = [];

  @override
  void initState() {
    super.initState();
    _loadRecentAccounts();
    // Just triggers a rebuild so the mascot's emoji/speech bubble (see
    // _mascotEmoji/_mascotMessage below) updates the instant a field is
    // focused - Flutter doesn't rebuild on focus changes on its own.
    _emailFocusNode.addListener(_onFocusChange);
    _passwordFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  // A small, friendly guide (the same "Flyla" character from
  // onboarding_screen.dart) that reacts to whatever the person is doing
  // right now - which field they're in, or what went wrong - instead of
  // a plain red error line. Meant to help both first-time and experienced
  // users alike: an experienced user can just ignore it and type, but
  // someone unsure what to enter (or why a login failed) gets a clear,
  // friendly nudge instead of a cold error code.
  String get _mascotEmoji {
    if (_isLoading) return '🚀';
    if (_errorMessage != null) return '😅';
    if (_passwordFocusNode.hasFocus) return '🙈';
    if (_emailFocusNode.hasFocus) return '👀';
    return '👋';
  }

  String get _mascotMessage {
    if (_isLoading) return 'Hold on, logging you in...';
    if (_errorMessage != null) return _errorMessage!;
    if (_passwordFocusNode.hasFocus) return 'Now type your secret password!';
    if (_emailFocusNode.hasFocus) return 'Type your email here!';
    return "Hi! I'm Flyla - let's get you signed in!";
  }

  Future<void> _loadRecentAccounts() async {
    final accounts = await RecentAccountsStore.load();
    if (mounted) setState(() => _recentAccounts = accounts);
  }

  void _useRecentAccount(RecentAccount account) {
    setState(() {
      _emailController.text = account.email;
      _passwordController.clear();
      _errorMessage = null;
    });
    _passwordFocusNode.requestFocus();
  }

  Future<void> _removeRecentAccount(String email) async {
    await RecentAccountsStore.forget(email);
    _loadRecentAccounts();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _bounceController.dispose();
    _sparkleController.dispose();
    super.dispose();
  }

  void _goToHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const MainNavigationScreen()),
    );
  }

  void _goToSignUp() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SignUpScreen()),
    );
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please fill in email and password';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user != null) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          final data = doc.data();
          await RecentAccountsStore.remember(RecentAccount(
            email: email,
            displayName: (data?['displayName'] as String?) ?? '',
            photoUrl: (data?['photoUrl'] as String?) ?? '',
          ));
        } catch (_) {
          // Not remembering this account locally isn't worth failing the
          // login over - the person is signed in either way.
        }
      }
      if (mounted) _goToHome();
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = _mapErrorMessage(e.code);
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _mapErrorMessage(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found. Please sign up first.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'invalid-email':
        return 'Invalid email format.';
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      default:
        return 'Login failed - $code';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 60),
                AnimatedBuilder(
                  animation: _sparkleController,
                  builder: (context, child) {
                    // 0 -> 1 -> 0 pulse, twice as fast as the controller's
                    // own loop so the glow "breathes" smoothly.
                    final double pulse =
                        (1 - (2 * _sparkleController.value - 1).abs());
                    return Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Color.lerp(
                                  const Color(0xFFFF4B6E),
                                  const Color(0xFF9C4DFF),
                                  pulse,
                                )!
                                    .withOpacity(0.25 + 0.35 * pulse),
                                blurRadius: 24 + 20 * pulse,
                                spreadRadius: 2 + 4 * pulse,
                              ),
                            ],
                          ),
                          child: child,
                        ),
                        _Sparkle(
                          controller: _sparkleController,
                          interval: const Interval(0.0, 0.5),
                          top: -6,
                          left: -18,
                          size: 16,
                        ),
                        _Sparkle(
                          controller: _sparkleController,
                          interval: const Interval(0.3, 0.8),
                          top: 4,
                          right: -22,
                          size: 20,
                        ),
                        _Sparkle(
                          controller: _sparkleController,
                          interval: const Interval(0.6, 1.0),
                          bottom: -10,
                          left: 6,
                          size: 13,
                        ),
                      ],
                    );
                  },
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [
                        Color(0xFFFF4B6E), // pink
                        Color(0xFFFF9142), // orange
                        Color(0xFFFFD93D), // yellow
                        Color(0xFF9C4DFF), // purple
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ).createShader(bounds),
                    child: const Text(
                      'Fly',
                      // ShaderMask needs an opaque color here to paint over -
                      // the gradient above replaces it, so this white never
                      // actually shows.
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 54,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                        shadows: [
                          Shadow(
                            color: Color(0x55000000),
                            offset: Offset(0, 3),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _bounceController,
                  builder: (context, child) {
                    final double lift = -8 * _bounceController.value;
                    return Transform.translate(
                      offset: Offset(0, lift),
                      child: child,
                    );
                  },
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFFFF4B6E), Color(0xFF9C4DFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _mascotEmoji,
                      style: const TextStyle(fontSize: 34),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    key: ValueKey(_mascotMessage),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: _errorMessage != null
                          ? Colors.redAccent.withOpacity(0.12)
                          : const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(14),
                      border: _errorMessage != null
                          ? Border.all(color: Colors.redAccent.withOpacity(0.4))
                          : null,
                    ),
                    child: Text(
                      _mascotMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _errorMessage != null
                            ? Colors.redAccent
                            : Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 48),
                if (_recentAccounts.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Continue as',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 76,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _recentAccounts.length,
                      itemBuilder: (context, index) {
                        final account = _recentAccounts[index];
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: GestureDetector(
                            onTap: () => _useRecentAccount(account),
                            child: SizedBox(
                              width: 64,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      CircleAvatar(
                                        radius: 24,
                                        backgroundColor: Colors.grey[850],
                                        backgroundImage:
                                            account.photoUrl.isNotEmpty
                                                ? NetworkImage(account.photoUrl)
                                                : null,
                                        child: account.photoUrl.isEmpty
                                            ? Text(
                                                account.displayName.isNotEmpty
                                                    ? account.displayName[0]
                                                        .toUpperCase()
                                                    : account.email[0]
                                                        .toUpperCase(),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              )
                                            : null,
                                      ),
                                      Positioned(
                                        right: -6,
                                        top: -6,
                                        child: GestureDetector(
                                          onTap: () => _removeRecentAccount(
                                              account.email),
                                          child: Container(
                                            padding: const EdgeInsets.all(2),
                                            decoration: const BoxDecoration(
                                              color: Colors.black,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.close,
                                              size: 14,
                                              color: Colors.grey[400],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    account.displayName.isNotEmpty
                                        ? account.displayName
                                        : account.email,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                TextField(
                  controller: _emailController,
                  focusNode: _emailFocusNode,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Email',
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Colors.grey[900],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Password',
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Colors.grey[900],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Log In',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _isLoading ? null : _goToSignUp,
                  child: const Text(
                    "Don't have an account? Sign Up",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// One twinkling sparkle near the logo - fades in/out and grows/shrinks
// over its own slice (`interval`) of the shared _sparkleController's
// cycle, so several of these placed around the logo twinkle at
// staggered moments instead of all at once.
class _Sparkle extends StatelessWidget {
  final AnimationController controller;
  final Interval interval;
  final double size;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;

  const _Sparkle({
    required this.controller,
    required this.interval,
    required this.size,
    this.top,
    this.bottom,
    this.left,
    this.right,
  });

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(parent: controller, curve: interval);
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: FadeTransition(
        // 0 -> 1 -> 0 within this sparkle's own slice of the cycle, so it
        // pops in then fades back out rather than snapping on/off.
        opacity: TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 1),
          TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 1),
        ]).animate(animation),
        child: ScaleTransition(
          scale: TweenSequence<double>([
            TweenSequenceItem(tween: Tween(begin: 0.4, end: 1.0), weight: 1),
            TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.4), weight: 1),
          ]).animate(animation),
          child: Text('✨', style: TextStyle(fontSize: size)),
        ),
      ),
    );
  }
}
