import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:universal_messenger/screens/home_screen.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  Timer? _checkTimer;
  bool _canResend = true;
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _checkTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkVerification(silent: true),
    );
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerification({bool silent = false}) async {
    if (!silent) setState(() => _isChecking = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      await user?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser != null && refreshedUser.emailVerified) {
        _checkTimer?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('এখনও ভেরিফাই হয়নি। আপনার জিমেইল ইনবক্স বা স্প্যাম ফোল্ডার চেক করুন।'),
          ),
        );
      }
    } finally {
      if (!silent && mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _resendEmail() async {
    if (!_canResend) return;
    setState(() => _canResend = false);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('নতুন ভেরিফিকেশন লিংক পাঠানো হয়েছে!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (_) {}

    await Future.delayed(const Duration(seconds: 45));
    if (mounted) setState(() => _canResend = true);
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('জিমেইল ভেরিফিকেশন'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'লগআউট',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.mark_email_unread_outlined,
              size: 80,
              color: Color(0xFF008069),
            ),
            const SizedBox(height: 20),
            const Text(
              'আপনার জিমেইল ভেরিফাই করুন',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'আমরা $email ঠিকানায় একটি ভেরিফিকেশন লিংক পাঠিয়েছি। জিমেইল অ্যাপ ওপেন করে লিংকটিতে ক্লিক করুন।',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _isChecking ? null : () => _checkVerification(silent: false),
              icon: const Icon(Icons.verified_user),
              label: const Text('আমি ভেরিফাই করেছি (এগিয়ে যান)'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF008069),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _canResend ? _resendEmail : null,
              icon: const Icon(Icons.refresh),
              label: Text(
                _canResend ? 'আবার ভেরিফিকেশন লিংক পাঠান' : 'অপেক্ষা করুন...',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
