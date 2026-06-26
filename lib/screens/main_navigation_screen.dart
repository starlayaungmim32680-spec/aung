import 'dart:math';
import 'dart:ui';
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

  // Each menu item has an icon and its own accent gradient
  final List<Map<String, dynamic>> _menuItems = const [
    {
      'icon': Icons.home_rounded,
      'label': 'Home',
      'colors': [Color(0xFFFF4B6E), Color(0xFFD32F4F)],
    },
    {
      'icon': Icons.chat_bubble_rounded,
      'label': 'Chat',
      'colors': [Color(0xFF3A8DFF), Color(0xFF1565C0)],
    },
    {
      'icon': Icons.add_rounded,
      'label': 'Upload',
      'colors': [Color(0xFF24D17E), Color(0xFF0E9F5E)],
    },
    {
      'icon': Icons.person_rounded,
      'label': 'Profile',
      'colors': [Color(0xFF9C4DFF), Color(0xFF6A1B9A)],
    },
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

  // Builds one menu item. The active item expands into a gradient pill with a label
  Widget _buildMenuItem(int i) {
    final item = _menuItems[i];
    final bool isActive = _currentIndex == i;
    final List<Color> colors = (item['colors'] as List).cast<Color>();

    return GestureDetector(
      onTap: () => _selectTab(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 18 : 14,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          gradient: isActive
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                )
              : null,
          borderRadius: BorderRadius.circular(20),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: colors.first.withOpacity(0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item['icon'],
              color: Colors.white,
              size: 26,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
            // Show the label only for the active item, with a smooth expand
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: isActive
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        item['label'],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
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

          // Frosted-glass pill menu bar with the 4 items - only visible when open
          if (_isMenuOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.15),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(
                          _menuItems.length,
                          (i) => Padding(
                            // Wider spacing between the items
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: _buildMenuItem(i),
                          ),
                        ),
                      ),
                    ),
                  ),
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
