import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:universal_messenger/screens/search_user_screen.dart';
import 'package:universal_messenger/screens/chat_screen.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const int currentAppVersionCode = 7;
  static const String currentAppVersionName = '7.0.0';
  static const String defaultReleaseUrl =
      'https://github.com/mizanislam3296-lab/universal-messenger/releases/latest';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  StreamSubscription<DocumentSnapshot>? _updateSub;
  bool _isUpdateDialogShowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettingsController.load();
    NotificationAndPresenceService.start();
    _listenForAppUpdates();
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationAndPresenceService.setOnlineStatus(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      NotificationAndPresenceService.setOnlineStatus(false);
    }
  }

  void _listenForAppUpdates() {
    final docRef =
        FirebaseFirestore.instance.collection('app_config').doc('version');

    _updateSub = docRef.snapshots().listen((snap) async {
      if (!snap.exists) {
        try {
          await docRef.set({
            'latestVersionCode': HomeScreen.currentAppVersionCode,
            'latestVersionName': HomeScreen.currentAppVersionName,
            'apkUrl': HomeScreen.defaultReleaseUrl,
            'forceUpdate': false,
            'releaseNotes': 'নতুন ফিচার ও পারফরম্যান্স উন্নতি যুক্ত করা হয়েছে।',
          }, SetOptions(merge: true));
        } catch (_) {}
        return;
      }

      final data = snap.data();
      if (data == null || !mounted || _isUpdateDialogShowing) return;

      final latestCode = (data['latestVersionCode'] as num?)?.toInt() ??
          HomeScreen.currentAppVersionCode;
      if (latestCode <= HomeScreen.currentAppVersionCode) return;

      final latestName =
          (data['latestVersionName'] ?? 'New Version').toString();
      final apkUrl =
          (data['apkUrl'] ?? HomeScreen.defaultReleaseUrl).toString();
      final forceUpdate = data['forceUpdate'] == true;
      final notes = (data['releaseNotes'] ??
              'অ্যাপটির নতুন ভার্সন এসেছে। সব ফিচার ঠিকভাবে ব্যবহার করতে এখনই আপডেট করুন।')
          .toString();

      _isUpdateDialogShowing = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !forceUpdate,
        builder: (ctx) => PopScope(
          canPop: !forceUpdate,
          child: AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: Row(
              children: [
                const Icon(Icons.system_update, color: Color(0xFF008069)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'নতুন আপডেট ($latestName)',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Text(notes),
            actions: [
              if (!forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('পরে'),
                ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF008069),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.download),
                label: const Text('Update Now'),
                onPressed: () async {
                  final uri = Uri.tryParse(apkUrl);
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ),
        ),
      );
      _isUpdateDialogShowing = false;
    });
  }

  String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final dt = timestamp.toDate();
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $period';
  }

  Widget _buildIncomingCallBanner(
      BuildContext context, User currentUser, Color primaryColor) {
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
            color: primaryColor,
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

    return ValueListenableBuilder<Color>(
      valueListenable: AppSettingsController.appThemeColor,
      builder: (context, themeColor, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: AppSettingsController.appThemeImage,
          builder: (context, themeImagePath, _) {
            final hasBgImage =
                themeImagePath != null && File(themeImagePath).existsSync();
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return Scaffold(
              appBar: AppBar(
                title: const Text('Universal Messenger'),
                backgroundColor: themeColor,
                foregroundColor: Colors.white,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'ইউজার খুঁজুন',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SearchUsersScreen()),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings),
                    tooltip: 'Settings',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()),
                      );
                    },
                  ),
                ],
              ),
              body: Container(
                decoration: hasBgImage
                    ? BoxDecoration(
                        image: DecorationImage(
                          image: FileImage(File(themeImagePath)),
                          fit: BoxFit.cover,
                          colorFilter: ColorFilter.mode(
                            isDark
                                ? Colors.black.withOpacity(0.55)
                                : Colors.white.withOpacity(0.72),
                            isDark ? BlendMode.darken : BlendMode.lighten,
                          ),
                        ),
                      )
                    : null,
                child: Column(
                  children: [
                    _buildIncomingCallBanner(context, currentUser, themeColor),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('chats')
                            .where('participants',
                                arrayContains: currentUser.uid)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }

                          if (!snapshot.hasData ||
                              snapshot.data!.docs.isEmpty) {
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
                                      'নিচের বাটনে ট্যাপ করে নাম বা জিমেইল দিয়ে বন্ধুদের খুঁজে বের করুন এবং মেসেজ বা কল করুন।',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }

                          final chats = snapshot.data!.docs.toList()
                            ..sort((a, b) {
                              final tA = (a.data() as Map<String, dynamic>)[
                                  'lastMessageTime'] as Timestamp?;
                              final tB = (b.data() as Map<String, dynamic>)[
                                  'lastMessageTime'] as Timestamp?;
                              if (tA == null) return 1;
                              if (tB == null) return -1;
                              return tB.compareTo(tA);
                            });

                          return ListView.separated(
                            itemCount: chats.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final data =
                                  chats[index].data() as Map<String, dynamic>;
                              final participants = List<String>.from(
                                  data['participants'] ?? []);
                              final otherId = participants.firstWhere(
                                (id) => id != currentUser.uid,
                                orElse: () => currentUser.uid,
                              );

                              final usersMap =
                                  (data['users'] as Map<String, dynamic>?) ??
                                      {};
                              final otherUser = (usersMap[otherId]
                                      as Map<String, dynamic>?) ??
                                  {};
                              final name =
                                  (otherUser['name'] ?? 'User').toString();
                              final email =
                                  (otherUser['email'] ?? '').toString();
                              final lastMsg =
                                  (data['lastMessage'] ?? '').toString();
                              final timeText = _formatDate(
                                  data['lastMessageTime'] as Timestamp?);

                              final unreadMap = (data['unreadCount']
                                      as Map<String, dynamic>?) ??
                                  {};
                              final unreadCount =
                                  (unreadMap[currentUser.uid] as num?)
                                          ?.toInt() ??
                                      0;
                              final hasUnread = unreadCount > 0;

                              return ListTile(
                                leading: NotificationAndPresenceService
                                    .buildUserAvatarWithStatus(
                                  userId: otherId,
                                  dotSize: 14,
                                  showOfflineTime: true,
                                  avatar: CircleAvatar(
                                    radius: 24,
                                    backgroundColor: themeColor,
                                    child: Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : 'U',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                subtitle: Text(
                                  hasUnread
                                      ? (unreadCount == 1
                                          ? '1 new message'
                                          : '$unreadCount new messages')
                                      : lastMsg,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: hasUnread
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: hasUnread
                                        ? (isDark
                                            ? Colors.white
                                            : Colors.black87)
                                        : Colors.grey.shade600,
                                  ),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      timeText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: hasUnread
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: hasUnread
                                            ? const Color(0xFF1A73E8)
                                            : Colors.grey.shade600,
                                      ),
                                    ),
                                    if (hasUnread) ...[
                                      const SizedBox(height: 6),
                                      Container(
                                        width: 11,
                                        height: 11,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF1A73E8),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ],
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
              ),
              floatingActionButton: FloatingActionButton(
                backgroundColor: themeColor,
                foregroundColor: Colors.white,
                tooltip: 'নতুন চ্যাট',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SearchUsersScreen()),
                  );
                },
                child: const Icon(Icons.message),
              ),
            );
          },
        );
      },
    );
  }
}
