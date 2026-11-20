import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:universal_messenger/screens/search_user_screen.dart';
import 'package:universal_messenger/screens/chat_screen.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const int currentAppVersionCode = 14;
  static const String currentAppVersionName = '14.0.0';

  static const String defaultDirectApkUrl =
      'https://github.com/mizanislam3296-lab/universal-messenger/releases/latest/download/Universal-Messenger.apk';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  StreamSubscription<DocumentSnapshot>? _updateSub;
  StreamSubscription<RemoteMessage>? _fcmOpenSub;
  bool _isUpdateDialogShowing = false;
  String? _activeIncomingCallId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    NotificationAndPresenceService.onIncomingCallTrigger =
        _handleIncomingCallTrigger;
    NotificationAndPresenceService.onIncomingCallDeclinedFromNotification =
        _handleDeclineFromNotification;

    _bootHomeServices();
  }

  Future<void> _bootHomeServices() async {
    // First clean up any leftover call/camera/mic from a killed session
    await CallCleanupCoordinator.cleanupOnFreshAppLaunch();

    await AppSettingsController.load();
    if (AppSettingsController.notificationsEnabled.value) {
      NotificationAndPresenceService.requestBatteryUnrestricted();
    }
    NotificationAndPresenceService.setAppForeground(true);
    await NotificationAndPresenceService.start();
    if (!mounted) return;
    _listenForAppUpdates();
    _setupFcmCallTapHandlers();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingCallIfAny();
    });
  }

  @override
  void dispose() {
    if (NotificationAndPresenceService.onIncomingCallTrigger ==
        _handleIncomingCallTrigger) {
      NotificationAndPresenceService.onIncomingCallTrigger = null;
    }
    if (NotificationAndPresenceService.onIncomingCallDeclinedFromNotification ==
        _handleDeclineFromNotification) {
      NotificationAndPresenceService.onIncomingCallDeclinedFromNotification =
          null;
    }
    _fcmOpenSub?.cancel();
    _updateSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationAndPresenceService.setAppForeground(true);
      NotificationAndPresenceService.start();
      _checkActiveRingingCallOnResume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      NotificationAndPresenceService.setAppForeground(false);
    }
  }

  void _setupFcmCallTapHandlers() {
    FirebaseMessaging.instance.getInitialMessage().then((msg) {
      if (msg != null && (msg.data['type'] ?? '') == 'call') {
        _checkActiveRingingCallOnResume();
      }
    }).catchError((_) {});

    _fcmOpenSub = FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      if ((msg.data['type'] ?? '') == 'call') {
        _checkActiveRingingCallOnResume();
      }
    });
  }

  void _consumePendingCallIfAny() {
    final pending = NotificationAndPresenceService.pendingCallData;
    if (pending != null) {
      final autoAccept = NotificationAndPresenceService.pendingAutoAccept;
      NotificationAndPresenceService.pendingCallData = null;
      NotificationAndPresenceService.pendingAutoAccept = false;
      _handleIncomingCallTrigger(pending, autoAccept: autoAccept);
    }
  }

  Future<void> _checkActiveRingingCallOnResume() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null ||
        !mounted ||
        NotificationAndPresenceService.isInActiveCall) {
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('calls')
          .doc(user.uid)
          .get();
      final data = snap.data();
      if (!snap.exists || data == null || (data['status'] ?? '') != 'ringing') {
        return;
      }

      // Ignore stale ringing docs older than 60 seconds
      final ts = data['timestamp'] as Timestamp?;
      if (ts != null &&
          DateTime.now().difference(ts.toDate()).inSeconds > 60) {
        return;
      }

      final callId = (data['callId'] ?? '').toString();
      if (callId.isEmpty) return;
      _handleIncomingCallTrigger({
        'type': 'call',
        'callId': callId,
        'chatId': (data['chatId'] ?? '').toString(),
        'callerId': (data['callerId'] ?? '').toString(),
        'callerName': (data['callerName'] ?? 'কেউ একজন').toString(),
        'callerEmail': (data['callerEmail'] ?? '').toString(),
        'isVideo': data['isVideo'] == true,
      }, autoAccept: false);
    } catch (_) {}
  }

  Future<void> _handleDeclineFromNotification(
      Map<String, dynamic> callData) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final callId = (callData['callId'] ?? '').toString();
    if (callId.isEmpty) return;
    final isVideo =
        callData['isVideo'] == true || callData['isVideo'] == 'true';

    NotificationAndPresenceService.stopNativeCallRingtone();
    await NotificationAndPresenceService.clearCallNotifications();

    await FirebaseFirestore.instance
        .collection('calls')
        .doc(currentUser.uid)
        .set({
      'callId': callId,
      'status': 'declined',
    }, SetOptions(merge: true));

    CallLogHelper.finalizeCall(
      callId: callId,
      isVideo: isVideo,
      forceMissed: true,
      fallbackChatId: (callData['chatId'] ?? '').toString(),
      fallbackCallerId: (callData['callerId'] ?? '').toString(),
      fallbackCallerName: (callData['callerName'] ?? 'User').toString(),
      fallbackCallerEmail: (callData['callerEmail'] ?? '').toString(),
      fallbackReceiverId: currentUser.uid,
      fallbackReceiverName:
          currentUser.displayName ?? currentUser.email ?? 'User',
      fallbackReceiverEmail: currentUser.email ?? '',
    );
  }

  Future<void> _handleIncomingCallTrigger(
    Map<String, dynamic> callData, {
    bool autoAccept = false,
  }) async {
    if (!mounted) return;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final callId = (callData['callId'] ?? '').toString();
    if (callId.isEmpty) return;
    if (NotificationAndPresenceService.isInActiveCall) return;
    if (!autoAccept && _activeIncomingCallId == callId) return;

    final chatId = (callData['chatId'] ?? '').toString();
    final callerId = (callData['callerId'] ?? '').toString();
    final callerName = (callData['callerName'] ?? 'কেউ একজন').toString();
    final callerEmail = (callData['callerEmail'] ?? '').toString();
    final isVideo =
        callData['isVideo'] == true || callData['isVideo'] == 'true';

    if (autoAccept) {
      _activeIncomingCallId = null;
      NotificationAndPresenceService.stopNativeCallRingtone();
      await NotificationAndPresenceService.clearCallNotifications();

      await FirebaseFirestore.instance
          .collection('calls')
          .doc(currentUser.uid)
          .set({
        'callId': callId,
        'status': 'accepted',
      }, SetOptions(merge: true));
      await CallLogHelper.markConnected(callId);

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            callID: callId,
            isVideoCall: isVideo,
            callDocId: currentUser.uid,
            chatId: chatId.isNotEmpty ? chatId : null,
            otherUserId: callerId.isNotEmpty ? callerId : null,
            otherUserName: callerName,
            otherUserEmail: callerEmail,
            isCaller: false,
          ),
        ),
      );
      return;
    }

    _activeIncomingCallId = callId;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IncomingCallScreen(
          callID: callId,
          isVideoCall: isVideo,
          callerId: callerId,
          callerName: callerName,
          callerEmail: callerEmail,
          chatId: chatId,
          callDocId: currentUser.uid,
        ),
      ),
    );
    if (_activeIncomingCallId == callId) {
      _activeIncomingCallId = null;
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

  Widget _buildChatSubtitle({
    required bool isOtherTyping,
    required Color themeColor,
    required bool isDark,
    required bool hasUnread,
    required int unreadCount,
    required int missedCount,
    required String lastMsg,
    required String lastMessageType,
    required String lastCallStatus,
    required bool lastCallIsVideo,
    required int lastCallDurationSec,
  }) {
    if (isOtherTyping) {
      return Text(
        'wait...',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: themeColor,
        ),
      );
    }

    if (lastMessageType == 'call') {
      final isMissed = lastCallStatus == 'missed';
      if (isMissed) {
        final baseLabel =
            lastCallIsVideo ? 'Missed video call' : 'Missed voice call';
        final label =
            missedCount > 1 ? '$baseLabel ($missedCount)' : baseLabel;
        return Row(
          children: [
            const Icon(Icons.call_missed, size: 16, color: Colors.redAccent),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.redAccent,
                ),
              ),
            ),
          ],
        );
      }

      final callLabel = lastCallIsVideo ? 'Video call' : 'Voice call';
      final durationText = CallLogHelper.formatDuration(lastCallDurationSec);
      return Row(
        children: [
          Icon(
            lastCallIsVideo ? Icons.videocam_rounded : Icons.call_rounded,
            size: 15,
            color: const Color(0xFF2E7D32),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              '$callLabel • $durationText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: hasUnread ? FontWeight.bold : FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.grey.shade700,
              ),
            ),
          ),
        ],
      );
    }

    if (missedCount > 0) {
      return Row(
        children: [
          const Icon(Icons.call_missed, size: 15, color: Colors.redAccent),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              missedCount == 1
                  ? 'Missed call • $lastMsg'
                  : '$missedCount missed calls • $lastMsg',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.redAccent,
              ),
            ),
          ),
        ],
      );
    }

    return Text(
      hasUnread
          ? (unreadCount == 1
              ? '1 new message • $lastMsg'
              : '$unreadCount new messages • $lastMsg')
          : lastMsg,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
        color: hasUnread
            ? (isDark ? Colors.white : Colors.black87)
            : Colors.grey.shade600,
      ),
    );
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
        final chatId = (data['chatId'] ?? '').toString();
        final callerId = (data['callerId'] ?? '').toString();
        final callerName = (data['callerName'] ?? 'কেউ একজন').toString();
        final callerEmail = (data['callerEmail'] ?? '').toString();
        final isVideo = data['isVideo'] == true;

        final callPayload = <String, dynamic>{
          'type': 'call',
          'callId': callId,
          'chatId': chatId,
          'callerId': callerId,
          'callerName': callerName,
          'callerEmail': callerEmail,
          'isVideo': isVideo,
        };

        return GestureDetector(
          onTap: () =>
              _handleIncomingCallTrigger(callPayload, autoAccept: false),
          child: Container(
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
                        isVideo
                            ? 'ইনকামিং ভিডিও কল... (ট্যাপ করুন)'
                            : 'ইনকামিং অডিও কল... (ট্যাপ করুন)',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  style: IconButton.styleFrom(backgroundColor: Colors.red),
                  icon: const Icon(Icons.call_end, color: Colors.white),
                  tooltip: 'কল কাটুন',
                  onPressed: () => _handleDeclineFromNotification(callPayload),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(backgroundColor: Colors.green),
                  icon: const Icon(Icons.call, color: Colors.white),
                  tooltip: 'কল রিসিভ করুন',
                  onPressed: () =>
                      _handleIncomingCallTrigger(callPayload, autoAccept: true),
                ),
              ],
            ),
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
                              final lastMessageType =
                                  (data['lastMessageType'] ?? 'text')
                                      .toString();
                              final lastCallStatus =
                                  (data['lastCallStatus'] ?? '').toString();
                              final lastCallIsVideo =
                                  data['lastCallIsVideo'] == true;
                              final lastCallDurationSec =
                                  (data['lastCallDurationSec'] as num?)
                                          ?.toInt() ??
                                      0;

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

                              final missedMap = (data['missedCallCount']
                                      as Map<String, dynamic>?) ??
                                  {};
                              final missedCount =
                                  (missedMap[currentUser.uid] as num?)
                                          ?.toInt() ??
                                      0;
                              final hasMissed = missedCount > 0;

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
                                subtitle: _buildChatSubtitle(
                                  isOtherTyping: isOtherTyping,
                                  themeColor: themeColor,
                                  isDark: isDark,
                                  hasUnread: hasUnread,
                                  unreadCount: unreadCount,
                                  missedCount: missedCount,
                                  lastMsg: lastMsg,
                                  lastMessageType: lastMessageType,
                                  lastCallStatus: lastCallStatus,
                                  lastCallIsVideo: lastCallIsVideo,
                                  lastCallDurationSec: lastCallDurationSec,
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      timeText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: (hasUnread || hasMissed)
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: hasMissed
                                            ? Colors.redAccent
                                            : (hasUnread
                                                ? const Color(0xFF1A73E8)
                                                : Colors.grey.shade600),
                                      ),
                                    ),
                                    if (hasMissed || hasUnread) ...[
                                      const SizedBox(height: 5),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (hasMissed)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.redAccent,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.call_missed,
                                                    color: Colors.white,
                                                    size: 11,
                                                  ),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    '$missedCount',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          if (hasMissed &&
                                              unreadCount > missedCount)
                                            const SizedBox(width: 4),
                                          if (!hasMissed && hasUnread)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 7,
                                                      vertical: 2),
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
                                            )
                                          else if (hasMissed &&
                                              unreadCount > missedCount)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1A73E8),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                '${unreadCount - missedCount}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                        ],
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
    for (final pkg in const [
      'com.universal.universal_messenger',
      'com.universal.messenger',
    ]) {
      try {
        final dir = Directory('/data/user/0/$pkg/files');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final probe = File('${dir.path}/.probe_apk');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        return '${dir.path}/universal_messenger_update.apk';
      } catch (_) {}
    }
    return '${Directory.systemTemp.path}/universal_messenger_update.apk';
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
      final dynamic res =
          await _nativeChannel.invokeMethod('installApk', {'path': path});
      if (!mounted) return;
      if (res == 'PERMISSION_REQUIRED' || res == false) {
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
