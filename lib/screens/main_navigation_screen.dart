import 'dart:math';
import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'upload_screen.dart';
import 'profile_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isMenuOpen = false;

  // Position of the draggable button (from bottom-right corner)
  double _buttonRight = 24;
  double _buttonBottom = 24;
  double _dragDistance = 0; // tracks how far the button moved during a drag

  late AnimationController _rotationController;

  final List<Widget> _screens = const [
    HomeScreen(),
    ChatScreen(),
    UploadScreen(),
    ProfileScreen(),
  ];

  final List<Map<String, dynamic>> _menuItems = const [
    {'icon': Icons.home, 'label': 'Home'},
    {'icon': Icons.chat_bubble_outline, 'label': 'Chat'},
    {'icon': Icons.add_box_outlined, 'label': 'Upload'},
    {'icon': Icons.person_outline, 'label': 'Profile'},
  ];

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  void _toggleMenu() {
    setState(() {
      _isMenuOpen = !_isMenuOpen;
    });
  }

  void _selectTab(int index) {
    setState(() {
      _currentIndex = index;
      // Menu stays open - does not close when a tab is tapped
    });
  }

  void _onPanStart(DragStartDetails details) {
    _dragDistance = 0;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _buttonRight -= details.delta.dx;
      _buttonBottom -= details.delta.dy;
      _dragDistance += details.delta.distance;

      // Keep the button within screen bounds
      final screenSize = MediaQuery.of(context).size;
      if (_buttonRight < 0) _buttonRight = 0;
      if (_buttonBottom < 0) _buttonBottom = 0;
      if (_buttonRight > screenSize.width - 56)
        _buttonRight = screenSize.width - 56;
      if (_buttonBottom > screenSize.height - 56)
        _buttonBottom = screenSize.height - 56;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    // If the button barely moved, treat it as a tap
    if (_dragDistance < 5) {
      _toggleMenu();
    }
  }

  // Main button with a rotating rainbow-colored ring around it
  Widget _buildMainButton() {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) {
            return Transform.rotate(
              angle: _rotationController.value * 2 * pi,
              child: Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    colors: [
                      Colors.red,
                      Colors.orange,
                      Colors.yellow,
                      Colors.green,
                      Colors.blue,
                      Colors.purple,
                      Colors.red,
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black,
          ),
          child: Icon(
            _isMenuOpen ? Icons.close : Icons.menu,
            color: Colors.white,
            size: 24,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: _screens,
          ),

          // Bottom row with 4 icons - no background, just floating icons
          if (_isMenuOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(_menuItems.length, (i) {
                    final item = _menuItems[i];
                    final bool isActive = _currentIndex == i;
                    return GestureDetector(
                      onTap: () => _selectTab(i),
                      child: Column(
                        children: [
                          Icon(
                            item['icon'],
                            color: isActive ? Colors.redAccent : Colors.white,
                            size: 28,
                            shadows: const [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item['label'],
                            style: TextStyle(
                              color: isActive ? Colors.redAccent : Colors.white,
                              fontSize: 12,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 8),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ),

          // Draggable main floating button
          Positioned(
            right: _buttonRight,
            bottom: _buttonBottom,
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: _buildMainButton(),
            ),
          ),
        ],
      ),
    );
  }
}
