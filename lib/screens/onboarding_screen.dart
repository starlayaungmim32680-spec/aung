import 'package:flutter/material.dart';

// A cute, friendly little guide ("Flyla" the bird - fitting for an app
// called Fly) that walks a brand-new user through the basics the first
// time they land on the Home screen. Shown once - see
// main_navigation_screen.dart's _maybeShowOnboardingOnce(), which mirrors
// the same "show once, remember on the user's doc" pattern already used
// for the swipe hint.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingStep {
  final String emoji;
  final String title;
  final String message;

  const _OnboardingStep({
    required this.emoji,
    required this.title,
    required this.message,
  });
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  late final AnimationController _bounceController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  int _page = 0;

  static const _steps = [
    _OnboardingStep(
      emoji: '👋',
      title: "Hi, I'm Flyla!",
      message: "I'll show you around Fly real quick - it'll only take a "
          'moment!',
    ),
    _OnboardingStep(
      emoji: '🎬',
      title: 'Discover videos',
      message: 'Swipe up on Home to see what everyone is sharing, and tap '
          'a video to watch it full-screen.',
    ),
    _OnboardingStep(
      emoji: '💬',
      title: 'Chat and call',
      message: 'Message your friends anytime - a little gold star ⭐ shows '
          "when they're online.",
    ),
    _OnboardingStep(
      emoji: '✨',
      title: 'Share your moment',
      message: "Ready? Tap the + button anytime to post your own video. "
          "Let's fly!",
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    _bounceController.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _steps.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      const Text('Skip', style: TextStyle(color: Colors.grey)),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _steps.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, index) {
                    final step = _steps[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _bounceController,
                            builder: (context, child) {
                              final double lift = -12 * _bounceController.value;
                              return Transform.translate(
                                offset: Offset(0, lift),
                                child: child,
                              );
                            },
                            child: Container(
                              width: 140,
                              height: 140,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFFF4B6E),
                                    Color(0xFF9C4DFF)
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                step.emoji,
                                style: const TextStyle(fontSize: 64),
                              ),
                            ),
                          ),
                          const SizedBox(height: 36),
                          // Speech-bubble style card, as if Flyla is
                          // actually talking to the person.
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 18),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  step.title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  step.message,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.grey[300],
                                    fontSize: 15,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _steps.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 20 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? Colors.redAccent : Colors.grey[700],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _next,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      _page == _steps.length - 1 ? "Let's go!" : 'Next',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
