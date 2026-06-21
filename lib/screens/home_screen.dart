import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PageController _pageController = PageController();

  // Placeholder video/photo posts - Cloudinary data ချိတ်ပြီးရင် Firestore ကနေ ဆွဲမယ်
  final List<Map<String, String>> _posts = [
    {'user': '@ko_aung', 'caption': 'My first post on Fly! 🚀'},
    {'user': '@traveler', 'caption': 'Beautiful sunset today 🌅'},
    {'user': '@foodie', 'caption': 'Best noodles in town 🍜'},
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _posts.length,
            itemBuilder: (context, index) {
              final post = _posts[index];
              return Container(
                color: Colors.grey[900 - (index % 3) * 100],
                child: Stack(
                  children: [
                    const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        color: Colors.white24,
                        size: 80,
                      ),
                    ),
                    Positioned(
                      left: 16,
                      bottom: 100,
                      right: 80,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post['user']!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            post['caption']!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 100,
                      child: Column(
                        children: const [
                          Icon(Icons.favorite_border,
                              color: Colors.white, size: 32),
                          SizedBox(height: 20),
                          Icon(Icons.comment_outlined,
                              color: Colors.white, size: 32),
                          SizedBox(height: 20),
                          Icon(Icons.share_outlined,
                              color: Colors.white, size: 32),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Top label
          const SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(
                child: Text(
                  'Fly',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
