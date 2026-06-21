import 'package:flutter/material.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Chat', style: TextStyle(color: Colors.white)),
      ),
      body: const Center(
        child: Text(
          'No messages yet',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      ),
    );
  }
}
