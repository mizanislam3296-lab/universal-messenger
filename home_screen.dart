import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Messenger'),
        backgroundColor: const Color(0xFF008069),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'লগআউট',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircleAvatar(
                radius: 40,
                backgroundColor: Color(0xFF008069),
                child: Icon(Icons.check, size: 42, color: Colors.white),
              ),
              const SizedBox(height: 16),
              Text(
                'স্বাগতম, ${user?.displayName ?? 'User'}!',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'ভেরিফাইড জিমেইল: ${user?.email ?? ''}',
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: const Text(
                  'ধাপ ১ সফলভাবে সম্পন্ন হয়েছে! আপনার অথেনটিকেশন সিস্টেম ১০০% সচল। পরবর্তী ধাপে এখানে চ্যাট লিস্ট, ফাইল শেয়ারিং এবং অডিও-ভিডিও কল যুক্ত হবে।',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
