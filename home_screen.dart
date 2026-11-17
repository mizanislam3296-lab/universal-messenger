import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:universal_messenger/screens/search_user_screen.dart';
import 'package:universal_messenger/screens/chat_screen.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

static const int currentAppVersionCode = 13;
static const String currentAppVersionName = '13.0.0';


  static const String defaultDirectApkUrl =
      'https://github.com/mizanislam3296-lab/universal-messenger/releases/latest/download/Universal-Messenger.apk';

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
    NotificationAndPresenceService.setAppForeground(true);
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
      NotificationAndPresenceService.setAppForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      NotificationAndPresenceService.setAppForeground(false);
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
            'apkUrl': HomeScreen.defaultDirectApkUrl,
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
      var apkUrl =
          (data['apkUrl'] ?? HomeScreen.defaultDirectApkUrl).toString().trim();
      if (apkUrl.isEmpty ||
          apkUrl.endsWith('/releases/latest') ||
          apkUrl.endsWith('/releases/latest/')) {
        apkUrl = HomeScreen.defaultDirectApkUrl;
      }
      final forceUpdate = data['forceUpdate'] == true;
      final notes = (data['releaseNotes'] ??
              'অ্যাপটির নতুন ভার্সন এসেছে। আনইন্সটল না করেই এখান থেকে সরাসরি আপডেট দিন।')
          .toString();

      _isUpdateDialogShowing = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !forceUpdate,
        builder: (ctx) => _InAppUpdateDialog(
          latestName: latestName,
          apkUrl: apkUrl,
          forceUpdate: forceUpdate,
          notes: notes,
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

                              final typingMap =
                                  (data['typing'] as Map<String, dynamic>?) ??
                                      {};
                              final isOtherTyping = typingMap[otherId] == true;

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
                                subtitle: isOtherTyping
                                    ? Text(
                                        'wait...',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: themeColor,
                                        ),
                                      )
                                    : Text(
                                        hasUnread
                                            ? (unreadCount == 1
                                                ? '1 new message • $lastMsg'
                                                : '$unreadCount new messages • $lastMsg')
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
                                      const SizedBox(height: 5),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 7, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1A73E8),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          '$unreadCount',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
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

class _InAppUpdateDialog extends StatefulWidget {
  final String latestName;
  final String apkUrl;
  final bool forceUpdate;
  final String notes;

  const _InAppUpdateDialog({
    required this.latestName,
    required this.apkUrl,
    required this.forceUpdate,
    required this.notes,
  });

  @override
  State<_InAppUpdateDialog> createState() => _InAppUpdateDialogState();
}

class _InAppUpdateDialogState extends State<_InAppUpdateDialog> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');

  bool _isDownloading = false;
  double _progress = 0.0;
  String _sizeText = '';
  String? _downloadedApkPath;
  String? _statusMessage;
  bool _hasError = false;

  String get _targetApkPath {
    final dir = Directory('/data/user/0/com.universal.messenger/files');
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}/universal_messenger_update.apk';
    } catch (_) {
      return '${Directory.systemTemp.path}/universal_messenger_update.apk';
    }
  }

  Future<void> _downloadAndInstall() async {
    if (_isDownloading) return;

    if (_downloadedApkPath != null && File(_downloadedApkPath!).existsSync()) {
      await _triggerInstall(_downloadedApkPath!);
      return;
    }

    setState(() {
      _isDownloading = true;
      _hasError = false;
      _progress = 0.0;
      _sizeText = '';
      _statusMessage = 'আপডেট ফাইল ডাউনলোড হচ্ছে...';
    });

    try {
      final savePath = _targetApkPath;
      final file = File(savePath);
      if (await file.exists()) await file.delete();

      await Dio().download(
        widget.apkUrl,
        savePath,
        options: Options(followRedirects: true, maxRedirects: 8),
        onReceiveProgress: (received, total) {
          if (!mounted) return;
          final recMb = (received / (1024 * 1024)).toStringAsFixed(1);
          if (total > 0) {
            final totMb = (total / (1024 * 1024)).toStringAsFixed(1);
            setState(() {
              _progress = received / total;
              _sizeText = '$recMb MB / $totMb MB';
            });
          } else {
            setState(() {
              _sizeText = '$recMb MB';
            });
          }
        },
      );

      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadedApkPath = savePath;
        _statusMessage = 'ডাউনলোড সম্পন্ন হয়েছে! ইনস্টল শুরু হচ্ছে...';
      });

      await _triggerInstall(savePath);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _hasError = true;
        _statusMessage =
            'সরাসরি ডাউনলোডে সমস্যা হয়েছে। নিচের বাটন থেকে আবার চেষ্টা করুন।';
      });
    }
  }

  Future<void> _triggerInstall(String path) async {
    try {
      final res =
          await _nativeChannel.invokeMethod<String>('installApk', {'path': path});
      if (!mounted) return;
      if (res == 'PERMISSION_REQUIRED') {
        setState(() {
          _statusMessage =
              'অনুগ্রহ করে সেটিংস থেকে "Allow from this source" চালু করে ফিরে আসুন, তারপর নিচের Install Now বাটনে চাপুন।';
        });
      } else {
        setState(() {
          _statusMessage = 'পপ-আপে "Update" বাটনে চাপ দিয়ে ইনস্টল সম্পন্ন করুন।';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _statusMessage = 'ইনস্টলার চালু করা যায়নি: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final readyToInstall =
        _downloadedApkPath != null && File(_downloadedApkPath!).existsSync();

    return PopScope(
      canPop: !widget.forceUpdate && !_isDownloading,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF008069)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'নতুন আপডেট (${widget.latestName})',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.notes),
            if (_isDownloading || _statusMessage != null) ...[
              const SizedBox(height: 16),
              if (_isDownloading) ...[
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  color: const Color(0xFF008069),
                  minHeight: 7,
                  borderRadius: BorderRadius.circular(6),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _progress > 0
                          ? '${(_progress * 100).toStringAsFixed(0)}%'
                          : 'ডাউনলোড হচ্ছে...',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    Text(
                      _sizeText,
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _statusMessage!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _hasError
                        ? Colors.red.shade700
                        : const Color(0xFF008069),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ],
        ),
        actions: [
          if (!widget.forceUpdate && !_isDownloading)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('পরে'),
            ),
          if (_hasError)
            TextButton(
              onPressed: () async {
                final uri = Uri.tryParse(widget.apkUrl);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text('ব্রাউজারে খুলুন'),
            ),
          if (!_isDownloading)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF008069),
                foregroundColor: Colors.white,
              ),
              icon: Icon(readyToInstall ? Icons.install_mobile : Icons.download),
              label: Text(readyToInstall
                  ? 'Install Now'
                  : (_hasError ? 'আবার চেষ্টা করুন' : 'Update Now')),
              onPressed: _downloadAndInstall,
            ),
        ],
      ),
    );
  }
}
