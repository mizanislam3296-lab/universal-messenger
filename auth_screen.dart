import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLogin = true;
  bool _isLoading = false;
  bool _obscurePassword = true;

  bool get _hasMinLength => _passwordController.text.length >= 8;
  bool get _hasUppercase => RegExp(r'[A-Z]').hasMatch(_passwordController.text);
  bool get _hasLowercase => RegExp(r'[a-z]').hasMatch(_passwordController.text);
  bool get _hasDigit => RegExp(r'[0-9]').hasMatch(_passwordController.text);
  bool get _hasSpecialChar =>
      RegExp(r'[!@#\$&*~%^()\-_+=]').hasMatch(_passwordController.text);

  bool get _isPasswordStrong =>
      _hasMinLength &&
      _hasUppercase &&
      _hasLowercase &&
      _hasDigit &&
      _hasSpecialChar;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _mapAuthError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'এই জিমেইল দিয়ে আগেই অ্যাকাউন্ট খোলা হয়েছে। লগইন করুন।';
      case 'invalid-email':
        return 'সঠিক জিমেইল অ্যাড্রেস দিন।';
      case 'weak-password':
        return 'পাসওয়ার্ডটি যথেষ্ট শক্তিশালী নয়।';
      case 'user-not-found':
      case 'invalid-credential':
        return 'জিমেইল অথবা পাসওয়ার্ড ভুল হয়েছে।';
      case 'wrong-password':
        return 'পাসওয়ার্ড ভুল হয়েছে। আবার চেষ্টা করুন।';
      case 'network-request-failed':
        return 'ইন্টারনেট সংযোগ চেক করুন।';
      default:
        return 'সমস্যা হয়েছে ($code)। আবার চেষ্টা করুন।';
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_isLogin && !_isPasswordStrong) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('অনুগ্রহ করে পাসওয়ার্ডের সবগুলো শর্ত পূরণ করুন।'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    try {
      if (_isLogin) {
        final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        await cred.user?.reload();
      } else {
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        final user = cred.user;
        if (user != null) {
          await user.updateDisplayName(name);
          await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
            'uid': user.uid,
            'name': name,
            'email': email,
            'createdAt': FieldValue.serverTimestamp(),
            'isOnline': true,
          });
          await user.sendEmailVerification();
        }
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mapAuthError(e.code)),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim().toLowerCase();
    if (!email.endsWith('@gmail.com')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('পাসওয়ার্ড রিসেট করতে আগে আপনার জিমেইল লিখুন।'),
        ),
      );
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('আপনার জিমেইলে পাসওয়ার্ড রিসেট লিংক পাঠানো হয়েছে।'),
          backgroundColor: Colors.green,
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_mapAuthError(e.code))),
      );
    }
  }

  Widget _buildRuleRow(bool passed, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            passed ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: passed ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: passed ? Colors.green.shade800 : Colors.grey.shade700,
              fontWeight: passed ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.forum_rounded,
                    size: 72,
                    color: Color(0xFF008069),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isLogin ? 'অ্যাকাউন্টে লগইন করুন' : 'নতুন অ্যাকাউন্ট খুলুন',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isLogin
                        ? 'আপনার ভেরিফাইড জিমেইল ও পাসওয়ার্ড দিন'
                        : 'জিমেইল এবং শক্তিশালী পাসওয়ার্ড দিয়ে রেজিস্ট্রেশন করুন',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 28),
                  if (!_isLogin) ...[
                    TextFormField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'আপনার পুরো নাম',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) {
                        if (!_isLogin && (val == null || val.trim().length < 2)) {
                          return 'কমপক্ষে ২ অক্ষরের নাম দিন';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'জিমেইল অ্যাড্রেস (example@gmail.com)',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) {
                      final v = (val ?? '').trim().toLowerCase();
                      if (v.isEmpty || !v.endsWith('@gmail.com') || v.length < 11) {
                        return 'শুধুমাত্র সঠিক @gmail.com অ্যাড্রেস গ্রহণযোগ্য';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'পাসওয়ার্ড',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                    ),
                    validator: (val) {
                      if (val == null || val.isEmpty) {
                        return 'পাসওয়ার্ড লিখুন';
                      }
                      return null;
                    },
                  ),
                  if (!_isLogin) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'শক্তিশালী পাসওয়ার্ডের শর্তাবলী:',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _buildRuleRow(_hasMinLength, 'কমপক্ষে ৮টি অক্ষর'),
                          _buildRuleRow(_hasUppercase, 'অন্তত ১টি বড় হাতের অক্ষর (A-Z)'),
                          _buildRuleRow(_hasLowercase, 'অন্তত ১টি ছোট হাতের অক্ষর (a-z)'),
                          _buildRuleRow(_hasDigit, 'অন্তত ১টি সংখ্যা (0-9)'),
                          _buildRuleRow(_hasSpecialChar, 'অন্তত ১টি বিশেষ চিহ্ন (@#\$%&*!)'),
                        ],
                      ),
                    ),
                  ],
                  if (_isLogin)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _resetPassword,
                        child: const Text('পাসওয়ার্ড ভুলে গেছেন?'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF008069),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _isLogin ? 'লগইন করুন' : 'রেজিস্ট্রেশন করুন',
                            style: const TextStyle(fontSize: 16),
                          ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _isLogin
                            ? 'কোনো অ্যাকাউন্ট নেই?'
                            : 'আগে থেকেই অ্যাকাউন্ট আছে?',
                      ),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () {
                                setState(() {
                                  _isLogin = !_isLogin;
                                  _passwordController.clear();
                                });
                              },
                        child: Text(
                          _isLogin ? 'রেজিস্ট্রেশন করুন' : 'লগইন করুন',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
