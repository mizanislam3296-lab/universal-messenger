import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:universal_messenger/screens/search_user_screen.dart';
import 'package:universal_messenger/screens/chat_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final dt = timestamp.toDate();
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $period';
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Messenger'),
        backgroundColor: const Color(0xFF008069),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'ইউজার খুঁজুন',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchUserScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'লগআউট',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .where('participants', arrayContains: currentUser.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade400),
                    const SizedBox(height: 16),
                    const Text(
                      'কোনো চ্যাট নেই',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'নিচের বাটনে ট্যাপ করে জিমেইল দিয়ে বন্ধুদের খুঁজে বের করুন এবং মেসেজ পাঠান।',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            );
          }

          final chats = snapshot.data!.docs.toList()
            ..sort((a, b) {
              final tA = (a.data() as Map<String, dynamic>)['lastMessageTime'] as Timestamp?;
              final tB = (b.data() as Map<String, dynamic>)['lastMessageTime'] as Timestamp?;
              if (tA == null) return 1;
              if (tB == null) return -1;
              return tB.compareTo(tA);
            });

          return ListView.separated(
            itemCount: chats.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final data = chats[index].data() as Map<String, dynamic>;
              final participants = List<String>.from(data['participants'] ?? []);
              final otherId = participants.firstWhere(
                (id) => id != currentUser.uid,
                orElse: () => currentUser.uid,
              );

              final usersMap = (data['users'] as Map<String, dynamic>?) ?? {};
              final otherUser = (usersMap[otherId] as Map<String, dynamic>?) ?? {};
              final name = (otherUser['name'] ?? 'User').toString();
              final email = (otherUser['email'] ?? '').toString();
              final lastMsg = (data['lastMessage'] ?? '').toString();
              final timeText = _formatDate(data['lastMessageTime'] as Timestamp?);

              return ListTile(
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(0xFF008069),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
                title: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  lastMsg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  timeText,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        receiverId: otherId,
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
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF008069),
        foregroundColor: Colors.white,
        tooltip: 'নতুন চ্যাট',
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SearchUserScreen()),
          );
        },
        child: const Icon(Icons.message),
      ),
    );
  }
}
