import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:universal_messenger/screens/chat_screen.dart';

class SearchUsersScreen extends StatefulWidget {
  const SearchUsersScreen({super.key});

  @override
  State<SearchUsersScreen> createState() => _SearchUsersScreenState();
}

class _SearchUsersScreenState extends State<SearchUsersScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('নতুন চ্যাট শুরু করুন'),
        backgroundColor: const Color(0xFF008069),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _query = val.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'সম্পূর্ণ নাম বা জিমেইল লিখুন...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Expanded(
            child: _query.isEmpty
                ? const Center(
                    child: Text(
                      'চ্যাট শুরু করতে সম্পূর্ণ ইউজার নাম বা জিমেইল লিখুন',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('users').snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(child: Text('কোনো ইউজার পাওয়া যায়নি'));
                      }

                      final users = snapshot.data!.docs.where((doc) {
                        final data = doc.data() as Map<String, dynamic>;
                        final uid = data['uid'] ?? doc.id;
                        if (uid == currentUser?.uid) return false;

                        final name = (data['name'] ?? '').toString().trim().toLowerCase();
                        final email = (data['email'] ?? '').toString().trim().toLowerCase();
                        return name == _query || email == _query;
                      }).toList();

                      if (users.isEmpty) {
                        return const Center(child: Text('এই নামে বা জিমেইলে কোনো ইউজার পাওয়া যায়নি'));
                      }

                      return ListView.separated(
                        itemCount: users.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final data = users[index].data() as Map<String, dynamic>;
                          final uid = data['uid'] ?? users[index].id;
                          final name = (data['name'] ?? 'User').toString();
                          final email = (data['email'] ?? '').toString();

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF008069),
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(email),
                            trailing: const Icon(Icons.chat_bubble_outline),
                            onTap: () {
                              Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    receiverId: uid,
                                    receiverName: name,
                                    receiverEmail: email,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
