import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:universal_messenger/screens/search_user_screen.dart';
import 'package:universal_messenger/screens/chat_screen.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

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

  Widget _buildIncomingCallBanner(BuildContext context, User currentUser) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('calls')
          .doc(currentUser.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null || data['status'] != 'ringing') {
          return const SizedBox.shrink();
        }

        final callId = (data['callId'] ?? '').toString();
        final callerName = (data['callerName'] ?? 'কেউ একজন').toString();
        final isVideo = data['isVideo'] == true;

        return Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF008069),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.white24,
                child: Icon(
                  isVideo ? Icons.videocam : Icons.call,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      callerName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isVideo ? 'ইনকামিং ভিডিও কল...' : 'ইনকামিং অডিও কল...',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.red),
                icon: const Icon(Icons.call_end, color: Colors.white),
                tooltip: 'কল কাটুন',
                onPressed: () {
                  FirebaseFirestore.instance
                      .collection('calls')
                      .doc(currentUser.uid)
                      .set({'status': 'declined'}, SetOptions(merge: true));
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.green),
                icon: const Icon(Icons.call, color: Colors.white),
                tooltip: 'কল রিসিভ করুন',
                onPressed: () {
                  FirebaseFirestore.instance
                      .collection('calls')
                      .doc(currentUser.uid)
                      .set({'status': 'accepted'}, SetOptions(merge: true));
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CallScreen(
                        callID: callId,
                        isVideoCall: isVideo,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
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
                MaterialPageRoute(builder: (_) =>  SearchUsersScreen()),
              );
            },
          ),
                    IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],

      ),
      body: Column(
        children: [
          _buildIncomingCallBanner(context, currentUser),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
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
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'কোনো চ্যাট নেই',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'নিচের বাটনে ট্যাপ করে জিমেইল দিয়ে বন্ধুদের খুঁজে বের করুন এবং মেসেজ বা কল করুন।',
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
                    final tA = (a.data() as Map<String, dynamic>)['lastMessageTime']
                        as Timestamp?;
                    final tB = (b.data() as Map<String, dynamic>)['lastMessageTime']
                        as Timestamp?;
                    if (tA == null) return 1;
                    if (tB == null) return -1;
                    return tB.compareTo(tA);
                  });

                return ListView.separated(
                  itemCount: chats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final data = chats[index].data() as Map<String, dynamic>;
                    final participants =
                        List<String>.from(data['participants'] ?? []);
                    final otherId = participants.firstWhere(
                      (id) => id != currentUser.uid,
                      orElse: () => currentUser.uid,
                    );

                    final usersMap =
                        (data['users'] as Map<String, dynamic>?) ?? {};
                    final otherUser =
                        (usersMap[otherId] as Map<String, dynamic>?) ?? {};
                    final name = (otherUser['name'] ?? 'User').toString();
                    final email = (otherUser['email'] ?? '').toString();
                    final lastMsg = (data['lastMessage'] ?? '').toString();
                    final timeText =
                        _formatDate(data['lastMessageTime'] as Timestamp?);

                    return ListTile(
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: const Color(0xFF008069),
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'U',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                          ),
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
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
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
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF008069),
        foregroundColor: Colors.white,
        tooltip: 'নতুন চ্যাট',
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) =>  SearchUserScreen()),
          );
        },
        child: const Icon(Icons.message),
      ),
    );
  }
}
