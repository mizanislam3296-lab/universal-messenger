import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

class CallCleanupCoordinator {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');
  static bool _handlerRegistered = false;
  static Future<void> Function()? _activeCallKillHandler;
  static Map<String, dynamic>? _activeCallMeta;

  static void ensureRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'onAppSwipedFromRecents') {
        await handleForceKill(call.arguments);
      }
      return true;
    });
  }

  static void attachActiveCall(
    Future<void> Function() handler, {
    Map<String, dynamic>? meta,
  }) {
    ensureRegistered();
    _activeCallKillHandler = handler;
    if (meta != null) {
      _activeCallMeta = Map<String, dynamic>.from(meta);
    }
  }

  static void updateActiveCallMeta(Map<String, dynamic> updates) {
    _activeCallMeta = {...?_activeCallMeta, ...updates};
  }

  static void detachActiveCall(Future<void> Function() handler) {
    if (_activeCallKillHandler == handler) {
      _activeCallKillHandler = null;
      _activeCallMeta = null;
    }
  }

  static Future<void> releaseAllHardwareAndRoom() async {
    try {
      ZegoUIKit().stopSharingScreen();
    } catch (_) {}
    try {
      ZegoUIKit().turnCameraOn(false);
    } catch (_) {}
    try {
      ZegoUIKit().turnMicrophoneOn(false);
    } catch (_) {}
    try {
      await ZegoUIKit().leaveRoom();
    } catch (_) {}
  }

  static Future<void> handleForceKill(dynamic args) async {
    NotificationAndPresenceService.isInActiveCall = false;
    NotificationAndPresenceService.stopNativeCallRingtone();
    NotificationAndPresenceService.clearCallNotifications();

    await releaseAllHardwareAndRoom();

    if (_activeCallKillHandler != null) {
      try {
        await _activeCallKillHandler!();
      } catch (_) {}
      return;
    }

    if (args is Map) {
      final callId = (args['callId'] ?? '').toString();
      final callDocId = (args['callDocId'] ?? '').toString();
      await endStaleCallInFirestore(callId: callId, callDocId: callDocId);
    }
  }

  static Future<void> cleanupOnFreshAppLaunch() async {
    ensureRegistered();
    NotificationAndPresenceService.isInActiveCall = false;

    await releaseAllHardwareAndRoom();

    try {
      await _nativeChannel.invokeMethod('stopScreenShareService');
      await _nativeChannel.invokeMethod('setCallAudioMode', {'active': false});
    } catch (_) {}

    try {
      final dynamic killed =
          await _nativeChannel.invokeMethod('consumeKilledCallState');
      if (killed is Map) {
        final callId = (killed['callId'] ?? '').toString();
        final callDocId = (killed['callDocId'] ?? '').toString();
        await endStaleCallInFirestore(callId: callId, callDocId: callDocId);
      }
    } catch (_) {}
  }

  static Future<void> endStaleCallInFirestore({
    required String callId,
    required String callDocId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (callId.isEmpty && callDocId.isEmpty) return;

    final payload = {
      if (callId.isNotEmpty) 'callId': callId,
      'status': 'ended',
      if (uid.isNotEmpty) 'endedBy': uid,
      'endedAt': FieldValue.serverTimestamp(),
    };

    if (callId.isNotEmpty) {
      final meta = _activeCallMeta;
      await CallLogHelper.finalizeCall(
        callId: callId,
        isVideo: meta?['isVideo'] == true,
        wasConnected: meta?['wasConnected'] == true,
        localConnectedAt: meta?['connectedAt'] as DateTime?,
        fallbackChatId: meta?['chatId']?.toString(),
        fallbackCallerId: meta?['callerId']?.toString(),
        fallbackCallerName: meta?['callerName']?.toString(),
        fallbackCallerEmail: meta?['callerEmail']?.toString(),
        fallbackReceiverId: meta?['receiverId']?.toString() ?? callDocId,
        fallbackReceiverName: meta?['receiverName']?.toString(),
        fallbackReceiverEmail: meta?['receiverEmail']?.toString(),
        fallbackCallDocId: callDocId,
      ).catchError((_) {});

      await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(callId)
          .set(payload, SetOptions(merge: true))
          .catchError((_) {});
    }

    if (callDocId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(callDocId)
          .set(payload, SetOptions(merge: true))
          .catchError((_) {});
    }

    if (uid.isNotEmpty && uid != callDocId) {
      try {
        final ownRef = FirebaseFirestore.instance.collection('calls').doc(uid);
        final snap = await ownRef.get();
        if (snap.exists &&
            (callId.isEmpty || (snap.data()?['callId'] ?? '') == callId)) {
          await ownRef.set(payload, SetOptions(merge: true));
        }
      } catch (_) {}
    }
  }
}

class CallLogHelper {
  static final Set<String> _finalizingOrLoggedKeys = {};

  static String formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '00:00';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
    }
    return '$mm:$ss';
  }

  static Future<void> startSession({
    required String callId,
    required String chatId,
    required String callerId,
    required String callerName,
    required String callerEmail,
    required String receiverId,
    required String receiverName,
    required String receiverEmail,
    required bool isVideo,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(callId)
          .set({
        'callId': callId,
        'chatId': chatId,
        'callerId': callerId,
        'callerName': callerName,
        'callerEmail': callerEmail,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'receiverEmail': receiverEmail,
        'isVideo': isVideo,
        'status': 'ringing',
        'logged': false,
        'videoUsers': {callerId: isVideo},
        'screenShareUsers': {},
        'startedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> markConnected(String callId) async {
    if (callId.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(callId)
          .set({
        'callId': callId,
        'status': 'accepted',
        'connectedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static String _inferChatIdFromCallId(String callId) {
    final parts = callId.split('_');
    if (parts.length >= 3) {
      return '${parts[0]}_${parts[1]}';
    }
    return '';
  }

  static Future<void> finalizeCall({
    required String callId,
    required bool isVideo,
    bool forceMissed = false,
    bool wasConnected = false,
    bool sendMissedPush = false,
    DateTime? localConnectedAt,
    String? fallbackChatId,
    String? fallbackCallerId,
    String? fallbackCallerName,
    String? fallbackCallerEmail,
    String? fallbackReceiverId,
    String? fallbackReceiverName,
    String? fallbackReceiverEmail,
    String? fallbackCallDocId,
  }) async {
    if (callId.isEmpty) return;

    final dedupeKey = '$callId:${wasConnected && !forceMissed ? 'done' : 'miss'}';
    if (_finalizingOrLoggedKeys.contains(dedupeKey)) return;
    _finalizingOrLoggedKeys.add(dedupeKey);

    Map<String, dynamic> remoteData = {};
    try {
      final sessionSnap = await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(callId)
          .get()
          .timeout(const Duration(seconds: 3));
      if (sessionSnap.exists && sessionSnap.data() != null) {
        remoteData = Map<String, dynamic>.from(sessionSnap.data()!);
      }
    } catch (_) {}

    if (remoteData.isEmpty) {
      final docIdsToCheck = <String>{
        if (fallbackCallDocId != null && fallbackCallDocId.isNotEmpty)
          fallbackCallDocId,
        if (fallbackReceiverId != null && fallbackReceiverId.isNotEmpty)
          fallbackReceiverId,
        if (FirebaseAuth.instance.currentUser?.uid != null)
          FirebaseAuth.instance.currentUser!.uid,
      };
      for (final dId in docIdsToCheck) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection('calls')
              .doc(dId)
              .get()
              .timeout(const Duration(seconds: 2));
          final d = snap.data();
          if (snap.exists && d != null && (d['callId'] ?? '') == callId) {
            remoteData = Map<String, dynamic>.from(d);
            break;
          }
        } catch (_) {}
      }
    }

    String chatId = (fallbackChatId != null && fallbackChatId.isNotEmpty)
        ? fallbackChatId
        : (remoteData['chatId'] ?? '').toString();
    String callerId = (fallbackCallerId != null && fallbackCallerId.isNotEmpty)
        ? fallbackCallerId
        : (remoteData['callerId'] ?? '').toString();
    String callerName =
        (fallbackCallerName != null && fallbackCallerName.isNotEmpty)
            ? fallbackCallerName
            : (remoteData['callerName'] ?? 'User').toString();
    String callerEmail =
        (fallbackCallerEmail != null && fallbackCallerEmail.isNotEmpty)
            ? fallbackCallerEmail
            : (remoteData['callerEmail'] ?? '').toString();
    String receiverId =
        (fallbackReceiverId != null && fallbackReceiverId.isNotEmpty)
            ? fallbackReceiverId
            : (remoteData['receiverId'] ?? '').toString();
    String receiverName =
        (fallbackReceiverName != null && fallbackReceiverName.isNotEmpty)
            ? fallbackReceiverName
            : (remoteData['receiverName'] ?? 'User').toString();
    String receiverEmail =
        (fallbackReceiverEmail != null && fallbackReceiverEmail.isNotEmpty)
            ? fallbackReceiverEmail
            : (remoteData['receiverEmail'] ?? '').toString();

    if (chatId.isEmpty) {
      if (callerId.isNotEmpty && receiverId.isNotEmpty) {
        final ids = [callerId, receiverId]..sort();
        chatId = '${ids[0]}_${ids[1]}';
      } else {
        chatId = _inferChatIdFromCallId(callId);
      }
    }

    if (chatId.isEmpty) {
      _finalizingOrLoggedKeys.remove(dedupeKey);
      return;
    }

    final chatParts = chatId.split('_');
    if (chatParts.length == 2) {
      if (callerId.isEmpty && receiverId.isNotEmpty) {
        callerId = chatParts[0] == receiverId ? chatParts[1] : chatParts[0];
      } else if (receiverId.isEmpty && callerId.isNotEmpty) {
        receiverId = chatParts[0] == callerId ? chatParts[1] : chatParts[0];
      }
    }
    if (callerId.isEmpty || receiverId.isEmpty) {
      _finalizingOrLoggedKeys.remove(dedupeKey);
      return;
    }

    final videoFlag = isVideo || (remoteData['isVideo'] == true);
    final connectedTs = remoteData['connectedAt'] as Timestamp?;
    final DateTime? connectedTime = localConnectedAt ?? connectedTs?.toDate();
    final wasAccepted = !forceMissed &&
        (wasConnected ||
            connectedTime != null ||
            remoteData['status'] == 'accepted');

    int durationSec = 0;
    if (wasAccepted) {
      if (connectedTime != null) {
        final diff = DateTime.now().difference(connectedTime).inSeconds;
        durationSec = diff < 1 ? 1 : diff;
      } else {
        durationSec = 1;
      }
    }

    final isMissed = !wasAccepted;
    final callStatus = isMissed ? 'missed' : 'completed';
    final summaryText = isMissed
        ? (videoFlag ? 'Missed video call' : 'Missed voice call')
        : '${videoFlag ? 'Video call' : 'Voice call'} • ${formatDuration(durationSec)}';

    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);
    final msgRef = chatRef.collection('messages').doc('call_$callId');

    final msgData = <String, dynamic>{
      'senderId': callerId,
      'receiverId': receiverId,
      'text': summaryText,
      'type': 'call',
      'callId': callId,
      'isVideo': videoFlag,
      'callStatus': callStatus,
      'durationSec': durationSec,
      'isSeen': !isMissed,
      'isEdited': false,
      'timestamp': FieldValue.serverTimestamp(),
    };

    final baseChatUpdate = <String, dynamic>{
      'chatId': chatId,
      'participants': [callerId, receiverId],
      'lastMessage': summaryText,
      'lastMessageType': 'call',
      'lastCallStatus': callStatus,
      'lastCallIsVideo': videoFlag,
      'lastCallDurationSec': durationSec,
      'lastCallCallerId': callerId,
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastSenderId': callerId,
      'users': {
        callerId: {
          'name': callerName,
          'email': callerEmail,
        },
        receiverId: {
          'name': receiverName,
          'email': receiverEmail,
        },
      },
    };

    final missedChatUpdate = <String, dynamic>{
      ...baseChatUpdate,
      if (isMissed)
        'unreadCount': {
          receiverId: FieldValue.increment(1),
        },
      if (isMissed)
        'missedCallCount': {
          receiverId: FieldValue.increment(1),
        },
    };

    bool createdFresh = false;
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final existing = await tx.get(msgRef);
        if (existing.exists) {
          final exData = existing.data() ?? <String, dynamic>{};
          final exStatus = (exData['callStatus'] ?? '').toString();
          final exDur = (exData['durationSec'] as num?)?.toInt() ?? 0;
          if ((exStatus == 'missed' && !isMissed) ||
              (!isMissed && durationSec > exDur)) {
            tx.set(msgRef, msgData, SetOptions(merge: true));
            tx.set(chatRef, baseChatUpdate, SetOptions(merge: true));
          }
          return;
        }
        tx.set(msgRef, msgData);
        tx.set(chatRef, missedChatUpdate, SetOptions(merge: true));
        createdFresh = true;
      });
    } catch (_) {
      try {
        await msgRef.set(msgData, SetOptions(merge: true));
        await chatRef.set(missedChatUpdate, SetOptions(merge: true));
        createdFresh = true;
      } catch (_) {}
    }

    FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(callId)
        .set({
      'callId': callId,
      'status': isMissed ? (forceMissed ? 'declined' : 'ended') : 'ended',
      'callStatus': callStatus,
      'durationSec': durationSec,
      'logged': true,
      'endedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((_) {});

    if (isMissed && createdFresh && sendMissedPush) {
      FcmPushService.sendPushToUser(
        receiverId: receiverId,
        title: videoFlag ? 'Missed video call' : 'Missed voice call',
        body: '$callerName tried to call you',
        isCall: false,
        chatId: chatId,
      ).catchError((_) {});
    }
  }
}

class IncomingCallScreen extends StatefulWidget {
  final String callID;
  final bool isVideoCall;
  final String callerId;
  final String callerName;
  final String callerEmail;
  final String chatId;
  final String callDocId;

  const IncomingCallScreen({
    super.key,
    required this.callID,
    required this.isVideoCall,
    required this.callerId,
    required this.callerName,
    required this.callerEmail,
    required this.chatId,
    required this.callDocId,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  StreamSubscription<DocumentSnapshot>? _callSub;
  StreamSubscription<DocumentSnapshot>? _sessionSub;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _listenForCancel();
  }

  void _listenForCancel() {
    _callSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callDocId)
        .snapshots()
        .listen((snap) {
      if (_handled || !mounted) return;
      final data = snap.data();
      if (!snap.exists || data == null) {
        _closeBecauseEnded();
        return;
      }
      final docCallId = (data['callId'] ?? '').toString();
      final status = (data['status'] ?? '').toString();
      if (docCallId != widget.callID || status != 'ringing') {
        _closeBecauseEnded();
      }
    });

    _sessionSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .snapshots()
        .listen((snap) {
      if (_handled || !mounted || !snap.exists) return;
      final status = (snap.data()?['status'] ?? '').toString();
      if (status == 'ended' ||
          status == 'declined' ||
          status == 'rejected' ||
          status == 'cancelled') {
        _closeBecauseEnded();
      }
    });
  }

  void _closeBecauseEnded() {
    if (_handled) return;
    _handled = true;
    NotificationAndPresenceService.stopNativeCallRingtone();
    NotificationAndPresenceService.clearCallNotifications();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _acceptCall() async {
    if (_handled) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    NotificationAndPresenceService.stopNativeCallRingtone();
    await NotificationAndPresenceService.clearCallNotifications();

    await FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callDocId)
        .set({
      'callId': widget.callID,
      'status': 'accepted',
    }, SetOptions(merge: true));

    await CallLogHelper.markConnected(widget.callID);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callID: widget.callID,
          isVideoCall: widget.isVideoCall,
          callDocId: widget.callDocId,
          chatId: widget.chatId.isNotEmpty ? widget.chatId : null,
          otherUserId: widget.callerId.isNotEmpty ? widget.callerId : null,
          otherUserName: widget.callerName,
          otherUserEmail: widget.callerEmail,
          isCaller: false,
        ),
      ),
    );
  }

  Future<void> _declineCall() async {
    if (_handled) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    NotificationAndPresenceService.stopNativeCallRingtone();
    await NotificationAndPresenceService.clearCallNotifications();

    final currentUser = FirebaseAuth.instance.currentUser;
    await FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callDocId)
        .set({
      'callId': widget.callID,
      'status': 'declined',
    }, SetOptions(merge: true));

    await CallLogHelper.finalizeCall(
      callId: widget.callID,
      isVideo: widget.isVideoCall,
      forceMissed: true,
      wasConnected: false,
      sendMissedPush: false,
      fallbackChatId: widget.chatId,
      fallbackCallerId: widget.callerId,
      fallbackCallerName: widget.callerName,
      fallbackCallerEmail: widget.callerEmail,
      fallbackReceiverId: currentUser?.uid ?? widget.callDocId,
      fallbackReceiverName:
          currentUser?.displayName ?? currentUser?.email ?? 'User',
      fallbackReceiverEmail: currentUser?.email ?? '',
      fallbackCallDocId: widget.callDocId,
    );

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _callSub?.cancel();
    _sessionSub?.cancel();
    super.dispose();
  }

  Widget _buildCallerAvatar() {
    final initial = widget.callerName.isNotEmpty
        ? widget.callerName[0].toUpperCase()
        : 'U';

    if (widget.callerId.isEmpty) {
      return CircleAvatar(
        radius: 62,
        backgroundColor: Colors.white24,
        child: Text(
          initial,
          style: const TextStyle(
              fontSize: 46, color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.callerId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>?;
        final photoUrl =
            (data?['photoUrl'] ?? data?['profilePic'] ?? '').toString().trim();

        ImageProvider? img;
        if (photoUrl.startsWith('http')) {
          img = NetworkImage(photoUrl);
        } else if (photoUrl.startsWith('data:image')) {
          try {
            img = MemoryImage(base64Decode(photoUrl.split(',').last));
          } catch (_) {}
        }

        return CircleAvatar(
          radius: 62,
          backgroundColor: Colors.white24,
          backgroundImage: img,
          child: img == null
              ? Text(
                  initial,
                  style: const TextStyle(
                      fontSize: 46,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                )
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: Stack(
          children: [
            const SizedBox.expand(
              child: CustomPaint(painter: _WhatsAppDoodlePainter()),
            ),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        widget.isVideoCall
                            ? Icons.videocam_rounded
                            : Icons.call_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.isVideoCall
                            ? 'Universal Messenger Video Call'
                            : 'Universal Messenger Voice Call',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(flex: 2),
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, child) {
                      final scale = 1.0 + (_pulseCtrl.value * 0.14);
                      final alpha = 0.28 - (_pulseCtrl.value * 0.2);
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.scale(
                            scale: scale,
                            child: Container(
                              width: 152,
                              height: 152,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color:
                                    const Color(0xFF25D366).withOpacity(alpha),
                              ),
                            ),
                          ),
                          child!,
                        ],
                      );
                    },
                    child: _buildCallerAvatar(),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      widget.callerName,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.isVideoCall
                        ? 'Incoming video call...'
                        : 'Incoming voice call...',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(flex: 3),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 42),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: _declineCall,
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFE51C44),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black38,
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.call_end_rounded,
                                  color: Colors.white,
                                  size: 34,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Decline',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: _acceptCall,
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF25D366),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black38,
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  widget.isVideoCall
                                      ? Icons.videocam_rounded
                                      : Icons.call_rounded,
                                  color: Colors.white,
                                  size: 34,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Accept',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 44),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CallScreen extends StatefulWidget {
  static const int zegoAppID = 1555115721;
  static const String zegoAppSign =
      'fef324f61318308645c2181add9d7a299ae4018c7ef2ff4341d17dab38b81bef';

  final String callID;
  final bool isVideoCall;
  final String? receiverIdForCleanup;
  final String? callDocId;
  final String? chatId;
  final String? otherUserId;
  final String? otherUserName;
  final String? otherUserEmail;
  final bool isCaller;

  const CallScreen({
    super.key,
    required this.callID,
    required this.isVideoCall,
    this.receiverIdForCleanup,
    this.callDocId,
    this.chatId,
    this.otherUserId,
    this.otherUserName,
    this.otherUserEmail,
    this.isCaller = true,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with WidgetsBindingObserver {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');

  late final User _currentUser;
  late final ValueNotifier<bool> _screenShareNotifier;
  late final ValueNotifier<List<ZegoUIKitUser>> _remoteScreenShareListNotifier;
  final ValueNotifier<int> _elapsedSecondsNotifier = ValueNotifier<int>(0);

  StreamSubscription<DocumentSnapshot>? _callDocSub;
  StreamSubscription<DocumentSnapshot>? _sessionDocSub;
  Stream<DocumentSnapshot>? _otherUserStream;
  Timer? _durationTimer;
  Timer? _ringTimeoutTimer;

  bool _allowPop = false;
  bool _cleanedUp = false;
  bool _remoteEnded = false;
  bool _isMinimizing = false;
  bool _callDocExisted = false;
  bool _wasScreenSharing = false;
  bool _isConnected = false;
  DateTime? _connectedAt;

  // WhatsApp Call Control States
  late bool _isSpeakerOn;
  late bool _isCameraOn;
  bool _isMuted = false;
  bool _isFrontCamera = true;
  bool _isRemoteCameraOn = false;
  bool _isRemoteScreenSharing = false;
  bool _zegoRemoteScreenSharing = false;

  String? get _effectiveCallDocId =>
      widget.callDocId ?? widget.receiverIdForCleanup;

  bool get _hasRemoteScreenShare =>
      _isRemoteScreenSharing || _zegoRemoteScreenSharing;

  bool get _showVoiceAvatarOverlay =>
      !widget.isVideoCall &&
      !_isCameraOn &&
      !_isRemoteCameraOn &&
      !_hasRemoteScreenShare;

  bool _isEndedStatus(String status) {
    return status == 'ended' ||
        status == 'declined' ||
        status == 'rejected' ||
        status == 'cancelled';
  }

  Map<String, dynamic> _buildCallMeta() {
    final myUid = _currentUser.uid;
    final myName = _currentUser.displayName ?? _currentUser.email ?? 'User';
    final myEmail = _currentUser.email ?? '';
    return {
      'callId': widget.callID,
      'chatId': widget.chatId ?? '',
      'isVideo': widget.isVideoCall || _isCameraOn || _isRemoteCameraOn,
      'wasConnected': _isConnected,
      'connectedAt': _connectedAt,
      'callerId': widget.isCaller ? myUid : (widget.otherUserId ?? ''),
      'callerName':
          widget.isCaller ? myName : (widget.otherUserName ?? 'User'),
      'callerEmail':
          widget.isCaller ? myEmail : (widget.otherUserEmail ?? ''),
      'receiverId': widget.isCaller
          ? (widget.otherUserId ?? widget.receiverIdForCleanup ?? '')
          : myUid,
      'receiverName':
          widget.isCaller ? (widget.otherUserName ?? 'User') : myName,
      'receiverEmail':
          widget.isCaller ? (widget.otherUserEmail ?? '') : myEmail,
    };
  }

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser!;
    _isSpeakerOn = widget.isVideoCall;
    _isCameraOn = widget.isVideoCall;

    if (widget.otherUserId != null && widget.otherUserId!.isNotEmpty) {
      _otherUserStream = FirebaseFirestore.instance
          .collection('users')
          .doc(widget.otherUserId)
          .snapshots();
    }

    _screenShareNotifier = ZegoUIKit().getScreenSharingStateNotifier();
    _screenShareNotifier.addListener(_onScreenShareStateChanged);

    _remoteScreenShareListNotifier =
        ZegoUIKit().getScreenSharingListNotifier();
    _remoteScreenShareListNotifier
        .addListener(_onRemoteScreenShareListChanged);
    _onRemoteScreenShareListChanged();

    WidgetsBinding.instance.addObserver(this);
    CallCleanupCoordinator.attachActiveCall(
      _handleAppKilledDuringCall,
      meta: _buildCallMeta(),
    );

    NotificationAndPresenceService.isInActiveCall = true;
    NotificationAndPresenceService.stopNativeCallRingtone();
    NotificationAndPresenceService.showOngoingCallNotification(
      isVideo: widget.isVideoCall,
      otherName: widget.otherUserName ?? 'Call',
      isScreenSharing: false,
    );

    if (!widget.isCaller) {
      _markLocallyConnected(notifyUi: false);
      CallLogHelper.markConnected(widget.callID);
    } else {
      _ringTimeoutTimer = Timer(const Duration(seconds: 45), () {
        if (mounted && !_isConnected && !_cleanedUp && !_remoteEnded) {
          _hangUpNow();
        }
      });
    }

    _setNativeCallState(true);
    _stopNativeRingtone();
    _syncLocalMediaFlags();
    _listenForRemoteHangUp();

    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && !_cleanedUp) {
        _applySpeakerRouting(_isSpeakerOn);
      }
    });
  }

  void _markLocallyConnected({DateTime? serverTime, bool notifyUi = true}) {
    if (_isConnected) return;
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
    _isConnected = true;
    _connectedAt ??= serverTime ?? DateTime.now();
    CallCleanupCoordinator.updateActiveCallMeta({
      'wasConnected': true,
      'connectedAt': _connectedAt,
    });
    _durationTimer?.cancel();
    _elapsedSecondsNotifier.value =
        DateTime.now().difference(_connectedAt!).inSeconds.clamp(0, 86400);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cleanedUp) return;
      final start = _connectedAt ?? DateTime.now();
      _elapsedSecondsNotifier.value =
          DateTime.now().difference(start).inSeconds.clamp(0, 86400);
    });
    if (notifyUi && mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _handleAppKilledDuringCall();
    }
  }

  Future<void> _handleAppKilledDuringCall() async {
    _isMinimizing = false;
    await CallCleanupCoordinator.releaseAllHardwareAndRoom();
    await _cleanupCallStatus();
  }

  @override
  void dispose() {
    _ringTimeoutTimer?.cancel();
    _durationTimer?.cancel();
    _elapsedSecondsNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    CallCleanupCoordinator.detachActiveCall(_handleAppKilledDuringCall);
    _screenShareNotifier.removeListener(_onScreenShareStateChanged);
    _remoteScreenShareListNotifier
        .removeListener(_onRemoteScreenShareListChanged);
    _callDocSub?.cancel();
    _sessionDocSub?.cancel();
    if (!_isMinimizing) {
      CallCleanupCoordinator.releaseAllHardwareAndRoom();
      _cleanupCallStatus();
    }
    super.dispose();
  }

  Future<void> _syncLocalMediaFlags() async {
    if (_cleanedUp) return;
    try {
      await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(widget.callID)
          .set({
        'videoUsers': {_currentUser.uid: _isCameraOn},
        'screenShareUsers': {_currentUser.uid: _screenShareNotifier.value},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _applySpeakerRouting(bool speakerOn) async {
    try {
      ZegoUIKit().setAudioOutputToSpeaker(speakerOn);
    } catch (_) {}
    try {
      await _nativeChannel
          .invokeMethod('setSpeakerphone', {'enabled': speakerOn});
    } catch (_) {}
  }

  Future<void> _toggleSpeaker() async {
    HapticFeedback.selectionClick();
    final next = !_isSpeakerOn;
    setState(() => _isSpeakerOn = next);
    await _applySpeakerRouting(next);
  }

  Future<void> _toggleCamera() async {
    HapticFeedback.selectionClick();
    final next = !_isCameraOn;
    if (next && _screenShareNotifier.value) {
      _stopScreenSharingImmediately();
    }
    setState(() => _isCameraOn = next);
    if (next) {
      CallCleanupCoordinator.updateActiveCallMeta({'isVideo': true});
    }
    try {
      ZegoUIKit().turnCameraOn(next);
    } catch (_) {}
    _syncLocalMediaFlags();
  }

  void _toggleMute() {
    HapticFeedback.selectionClick();
    final nextMuted = !_isMuted;
    setState(() => _isMuted = nextMuted);
    try {
      ZegoUIKit().turnMicrophoneOn(!nextMuted);
    } catch (_) {}
  }

  void _flipCamera() {
    if (!_isCameraOn) return;
    HapticFeedback.selectionClick();
    final nextFront = !_isFrontCamera;
    setState(() => _isFrontCamera = nextFront);
    try {
      ZegoUIKit().useFrontFacingCamera(nextFront);
    } catch (_) {}
  }

  void _onRemoteScreenShareListChanged() {
    final users = _remoteScreenShareListNotifier.value;
    final remoteSharing = users.any((u) => u.id != _currentUser.uid);
    if (remoteSharing != _zegoRemoteScreenSharing && mounted) {
      setState(() {
        _zegoRemoteScreenSharing = remoteSharing;
      });
    }
  }

  void _onScreenShareStateChanged() {
    final sharing = _screenShareNotifier.value;
    if (sharing) {
      _wasScreenSharing = true;
      _setNativeScreenSharing(true);
    } else if (_wasScreenSharing) {
      _wasScreenSharing = false;
      _setNativeScreenSharing(false);
    }

    _syncLocalMediaFlags();

    if (!_cleanedUp) {
      NotificationAndPresenceService.showOngoingCallNotification(
        isVideo: widget.isVideoCall || _isCameraOn,
        otherName: widget.otherUserName ?? 'Call',
        isScreenSharing: sharing,
      );
    }

    if (mounted) setState(() {});
  }

  Future<void> _setNativeCallState(bool active) async {
    try {
      await _nativeChannel.invokeMethod('setCallActive', {
        'active': active,
        'callId': widget.callID,
        'callDocId': _effectiveCallDocId ?? '',
      });
    } catch (_) {}
  }

  Future<void> _setNativeScreenSharing(bool active) async {
    try {
      await _nativeChannel.invokeMethod('setScreenSharing', {'active': active});
    } catch (_) {}
  }

  Future<void> _stopNativeRingtone() async {
    try {
      await _nativeChannel.invokeMethod('stopRingtone');
    } catch (_) {}
  }

  Future<void> _moveToBackgroundForScreenShare() async {
    try {
      await _nativeChannel.invokeMethod('moveToBackground');
    } catch (_) {}
  }

  void _stopScreenSharingImmediately() {
    _wasScreenSharing = false;
    try {
      ZegoUIKit().stopSharingScreen();
    } catch (_) {}
    try {
      _nativeChannel.invokeMethod('stopScreenShareService');
    } catch (_) {}
  }

  Future<void> _toggleScreenSharing() async {
    HapticFeedback.selectionClick();
    if (_screenShareNotifier.value) {
      _stopScreenSharingImmediately();
      return;
    }

    try {
      await _nativeChannel.invokeMethod('suppressPipOnce', true);
      await _nativeChannel.invokeMethod('setScreenSharing', {'active': true});
    } catch (_) {}

    try {
      ZegoUIKit().startSharingScreen();
    } catch (_) {}
  }

  void _listenForRemoteHangUp() {
    final currentUid = _currentUser.uid;

    _sessionDocSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .snapshots()
        .listen((snap) {
      if (_remoteEnded || _cleanedUp || !snap.exists) return;
      final data = snap.data();
      if (data == null) return;

      final status = (data['status'] ?? '').toString();
      if (status == 'accepted') {
        final ts = data['connectedAt'] as Timestamp?;
        _markLocallyConnected(serverTime: ts?.toDate());
      }

      final videoUsers = data['videoUsers'];
      bool remoteCam = false;
      if (videoUsers is Map) {
        videoUsers.forEach((k, v) {
          if (k.toString() != currentUid && v == true) {
            remoteCam = true;
          }
        });
      }

      final shareUsers = data['screenShareUsers'];
      bool remoteShare = false;
      if (shareUsers is Map) {
        shareUsers.forEach((k, v) {
          if (k.toString() != currentUid && v == true) {
            remoteShare = true;
          }
        });
      }

      if ((remoteCam != _isRemoteCameraOn ||
              remoteShare != _isRemoteScreenSharing) &&
          mounted) {
        setState(() {
          _isRemoteCameraOn = remoteCam;
          _isRemoteScreenSharing = remoteShare;
        });
      }

      if (_isEndedStatus(status)) {
        _endCallFromRemote(wasDeclined: status == 'declined');
      }
    });

    final docId =
        (_effectiveCallDocId != null && _effectiveCallDocId!.isNotEmpty)
            ? _effectiveCallDocId!
            : currentUid;
    if (docId.isEmpty) return;

    _callDocSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(docId)
        .snapshots()
        .listen((snap) {
      if (_remoteEnded || _cleanedUp) return;

      if (!snap.exists) {
        if (_callDocExisted) {
          _endCallFromRemote();
        }
        return;
      }

      final data = snap.data();
      if (data == null) return;

      final docCallId = (data['callId'] ?? '').toString();
      final status = (data['status'] ?? '').toString();

      if (docCallId == widget.callID) {
        _callDocExisted = true;
        if (status == 'accepted') {
          _markLocallyConnected();
        }
        if (_isEndedStatus(status)) {
          _endCallFromRemote(wasDeclined: status == 'declined');
        }
      }
    });
  }

  Future<void> _recordCallLog({bool sendMissedPush = false}) async {
    final myUid = _currentUser.uid;
    final myName = _currentUser.displayName ?? _currentUser.email ?? 'User';
    final myEmail = _currentUser.email ?? '';

    final callerId = widget.isCaller ? myUid : (widget.otherUserId ?? '');
    final callerName =
        widget.isCaller ? myName : (widget.otherUserName ?? 'User');
    final callerEmail =
        widget.isCaller ? myEmail : (widget.otherUserEmail ?? '');

    final receiverId = widget.isCaller
        ? (widget.otherUserId ?? widget.receiverIdForCleanup ?? '')
        : myUid;
    final receiverName =
        widget.isCaller ? (widget.otherUserName ?? 'User') : myName;
    final receiverEmail =
        widget.isCaller ? (widget.otherUserEmail ?? '') : myEmail;

    await CallLogHelper.finalizeCall(
      callId: widget.callID,
      isVideo: widget.isVideoCall || _isCameraOn || _isRemoteCameraOn,
      wasConnected: _isConnected,
      sendMissedPush: sendMissedPush,
      localConnectedAt: _connectedAt,
      fallbackChatId: widget.chatId,
      fallbackCallerId: callerId,
      fallbackCallerName: callerName,
      fallbackCallerEmail: callerEmail,
      fallbackReceiverId: receiverId,
      fallbackReceiverName: receiverName,
      fallbackReceiverEmail: receiverEmail,
      fallbackCallDocId: _effectiveCallDocId,
    );
  }

  Future<void> _hangUpNow() async {
    HapticFeedback.mediumImpact();
    _ringTimeoutTimer?.cancel();
    _isMinimizing = false;
    await CallCleanupCoordinator.releaseAllHardwareAndRoom();
    await _cleanupCallStatus(sendMissedPush: widget.isCaller && !_isConnected);
    if (mounted) setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ZegoUIKitPrebuiltCallController().hangUp(context);
      } catch (_) {}
      _stopScreenSharingImmediately();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _endCallFromRemote({bool wasDeclined = false}) async {
    if (_remoteEnded) return;
    _remoteEnded = true;
    _cleanedUp = true;
    _ringTimeoutTimer?.cancel();
    NotificationAndPresenceService.isInActiveCall = false;
    NotificationAndPresenceService.clearCallNotifications();
    await CallCleanupCoordinator.releaseAllHardwareAndRoom();
    _setNativeCallState(false);
    _stopNativeRingtone();
    await _recordCallLog(sendMissedPush: false);

    if (!mounted) return;
    setState(() => _allowPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ZegoUIKitPrebuiltCallController().hangUp(context);
      } catch (_) {}
      _stopScreenSharingImmediately();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _cleanupCallStatus({bool sendMissedPush = false}) async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _ringTimeoutTimer?.cancel();
    NotificationAndPresenceService.isInActiveCall = false;
    NotificationAndPresenceService.clearCallNotifications();
    _stopScreenSharingImmediately();
    _setNativeCallState(false);
    _stopNativeRingtone();

    final currentUid = _currentUser.uid;
    final payload = {
      'callId': widget.callID,
      'status': 'ended',
      'endedBy': currentUid,
      'endedAt': FieldValue.serverTimestamp(),
    };

    FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .set(payload, SetOptions(merge: true))
        .catchError((_) {});

    final docId = _effectiveCallDocId;
    if (docId != null && docId.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('calls')
          .doc(docId)
          .set(payload, SetOptions(merge: true))
          .catchError((_) {});
    }

    if (currentUid.isNotEmpty && currentUid != docId) {
      final ownRef =
          FirebaseFirestore.instance.collection('calls').doc(currentUid);
      ownRef.get().then((snap) {
        if (snap.exists && (snap.data()?['callId'] ?? '') == widget.callID) {
          ownRef.set(payload, SetOptions(merge: true)).catchError((_) {});
        }
      }).catchError((_) {});
    }

    await _recordCallLog(
      sendMissedPush: sendMissedPush || (widget.isCaller && !_isConnected),
    );
  }

  void _minimizeCall() {
    HapticFeedback.selectionClick();
    if (_allowPop || _remoteEnded) return;
    if (_screenShareNotifier.value) {
      _moveToBackgroundForScreenShare();
      return;
    }
    _isMinimizing = true;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ZegoUIKitPrebuiltCallController().minimize.minimize(context);
      }
    });
  }

  Widget _buildCenterAvatar() {
    final displayName = widget.otherUserName ?? 'User';
    final initial =
        displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U';

    Widget avatarFallback() {
      return CircleAvatar(
        radius: 74,
        backgroundColor: const Color(0xFF008069),
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 54,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      );
    }

    if (_otherUserStream == null) {
      return avatarFallback();
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: _otherUserStream,
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>?;
        final photoUrl =
            (data?['photoUrl'] ?? data?['profilePic'] ?? '').toString().trim();

        ImageProvider? img;
        if (photoUrl.startsWith('http')) {
          img = NetworkImage(photoUrl);
        } else if (photoUrl.startsWith('data:image')) {
          try {
            img = MemoryImage(base64Decode(photoUrl.split(',').last));
          } catch (_) {}
        }

        if (img == null) return avatarFallback();

        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white24,
              width: 2.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 72,
            backgroundColor: const Color(0xFF1F2C34),
            backgroundImage: img,
          ),
        );
      },
    );
  }

  Widget _buildWhatsAppPillButton({
    required IconData icon,
    required VoidCallback onTap,
    bool isActive = false,
    bool isDestructive = false,
  }) {
    final Color bgColor;
    final Color iconColor;

    if (isDestructive) {
      bgColor = const Color(0xFFE51C44);
      iconColor = Colors.white;
    } else if (isActive) {
      bgColor = Colors.white;
      iconColor = const Color(0xFF111B21);
    } else {
      bgColor = const Color(0xFF323A3F);
      iconColor = Colors.white;
    }

    return Material(
      color: bgColor,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, color: iconColor, size: 24),
        ),
      ),
    );
  }

  Widget _buildWhatsAppTopBar() {
    final displayName = widget.otherUserName ?? 'User';

    return SafeArea(
      bottom: false,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Material(
                color: const Color(0xFF222C32).withOpacity(0.88),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: _minimizeCall,
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.close_fullscreen_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 6),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (!_isConnected)
                      const Text(
                        'Ringing...',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          decoration: TextDecoration.none,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 6),
                          ],
                        ),
                      )
                    else
                      ValueListenableBuilder<int>(
                        valueListenable: _elapsedSecondsNotifier,
                        builder: (_, secs, __) => Text(
                          CallLogHelper.formatDuration(secs),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.none,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_isCameraOn)
                Material(
                  color: const Color(0xFF222C32).withOpacity(0.88),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: _flipCamera,
                    customBorder: const CircleBorder(),
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.cameraswitch_rounded,
                        color: Colors.white,
                        size: 21,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: 44, height: 44),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWhatsAppControlCard() {
    return SafeArea(
      top: false,
      child: Material(
        type: MaterialType.transparency,
        child: ValueListenableBuilder<bool>(
          valueListenable: _screenShareNotifier,
          builder: (_, isSharing, __) {
            return Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1C2327).withOpacity(0.92),
                borderRadius: BorderRadius.circular(42),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildWhatsAppPillButton(
                    icon: _isSpeakerOn
                        ? Icons.volume_up_rounded
                        : Icons.volume_down_rounded,
                    isActive: _isSpeakerOn,
                    onTap: _toggleSpeaker,
                  ),
                  _buildWhatsAppPillButton(
                    icon: _isCameraOn
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    isActive: _isCameraOn,
                    onTap: _toggleCamera,
                  ),
                  _buildWhatsAppPillButton(
                    icon: _isMuted
                        ? Icons.mic_off_rounded
                        : Icons.mic_rounded,
                    isActive: _isMuted,
                    onTap: _toggleMute,
                  ),
                  _buildWhatsAppPillButton(
                    icon: isSharing
                        ? Icons.stop_screen_share_rounded
                        : Icons.screen_share_rounded,
                    isActive: isSharing,
                    onTap: _toggleScreenSharing,
                  ),
                  _buildWhatsAppPillButton(
                    icon: Icons.call_end_rounded,
                    isDestructive: true,
                    onTap: _hangUpNow,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessengerScreenSharingOverlay() {
    return Material(
      color: const Color(0xFF0B141A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366).withOpacity(0.16),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.present_to_all_rounded,
                  color: Color(0xFF25D366),
                  size: 46,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'You\'re sharing your screen',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Everyone in this call can see your screen.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text(
                    'Open another app',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  onPressed: _moveToBackgroundForScreenShare,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE51C44),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  icon: const Icon(Icons.stop_screen_share_rounded),
                  label: const Text(
                    'Stop sharing',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  onPressed: _stopScreenSharingImmediately,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                icon:
                    const Icon(Icons.call_end_rounded, color: Color(0xFFE51C44)),
                label: const Text(
                  'End call',
                  style: TextStyle(color: Color(0xFFE51C44)),
                ),
                onPressed: _hangUpNow,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userName = _currentUser.displayName ??
        _currentUser.email?.split('@').first ??
        'User';

    final config = widget.isVideoCall
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

    config.layout = _hasRemoteScreenShare
        ? ZegoLayout.gallery(
            showScreenSharingFullscreenModeToggleButtonRules:
                ZegoShowFullscreenModeToggleButtonRules.alwaysShow,
            showNewScreenSharingViewInFullscreenMode: true,
          )
        : ZegoLayout.pictureInPicture(
            isSmallViewDraggable: true,
            switchLargeOrSmallViewByClick: true,
          );
    config.audioVideoView.useVideoViewAspectFill = true;
    config.duration.isVisible = false;
    config.turnOnCameraWhenJoining = widget.isVideoCall;
    config.turnOnMicrophoneWhenJoining = true;
    config.useSpeakerWhenJoining = widget.isVideoCall;
    config.topMenuBar.isVisible = false;
    config.bottomMenuBar.isVisible = false;
    config.pip.enableWhenBackground = false;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _minimizeCall();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Live Zego video/audio/screen-share canvas
            ZegoUIKitPrebuiltCall(
              appID: CallScreen.zegoAppID,
              appSign: CallScreen.zegoAppSign,
              userID: _currentUser.uid,
              userName: userName,
              callID: widget.callID,
              config: config,
              events: ZegoUIKitPrebuiltCallEvents(
                onCallEnd: (event, defaultAction) async {
                  _isMinimizing = false;
                  await CallCleanupCoordinator.releaseAllHardwareAndRoom();
                  await _cleanupCallStatus(
                    sendMissedPush: widget.isCaller && !_isConnected,
                  );
                  if (mounted) {
                    setState(() => _allowPop = true);
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    defaultAction.call();
                    _stopScreenSharingImmediately();
                  });
                },
                user: ZegoCallUserEvents(
                  onEnter: (user) {
                    if (user.id != _currentUser.uid) {
                      _markLocallyConnected();
                      CallLogHelper.markConnected(widget.callID);
                    }
                  },
                  onLeave: (user) {
                    if (user.id != _currentUser.uid) {
                      _isMinimizing = false;
                      CallCleanupCoordinator.releaseAllHardwareAndRoom();
                      _endCallFromRemote();
                    }
                  },
                ),
              ),
            ),

            // 2. WhatsApp voice-call background & avatar
            if (_showVoiceAvatarOverlay)
              IgnorePointer(
                child: Container(
                  color: const Color(0xFF0B141A),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CustomPaint(painter: _WhatsAppDoodlePainter()),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 110),
                          child: _buildCenterAvatar(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 3. Always-visible WhatsApp Top Bar
            Align(
              alignment: Alignment.topCenter,
              child: _buildWhatsAppTopBar(),
            ),

            // 4. Always-visible 5-button WhatsApp Pill Bar
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildWhatsAppControlCard(),
            ),

            // 5. Local Screen Sharing Overlay
            ValueListenableBuilder<bool>(
              valueListenable: _screenShareNotifier,
              builder: (_, isSharing, __) {
                if (!isSharing) return const SizedBox.shrink();
                return SizedBox.expand(
                  child: _buildMessengerScreenSharingOverlay(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _WhatsAppDoodlePainter extends CustomPainter {
  const _WhatsAppDoodlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.035)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    const double step = 64;
    for (double y = 20; y < size.height; y += step) {
      for (double x = 20; x < size.width; x += step) {
        final offsetX = ((y ~/ step).isOdd) ? step * 0.5 : 0.0;
        final cx = x + offsetX;
        final idx = ((x ~/ step) + (y ~/ step)) % 4;
        if (idx == 0) {
          canvas.drawCircle(Offset(cx, y), 10, paint);
        } else if (idx == 1) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(cx, y), width: 20, height: 14),
              const Radius.circular(5),
            ),
            paint,
          );
        } else if (idx == 2) {
          canvas.drawArc(
            Rect.fromCenter(center: Offset(cx, y), width: 18, height: 18),
            0.2,
            2.4,
            false,
            paint,
          );
        } else {
          final path = Path()
            ..moveTo(cx, y - 9)
            ..lineTo(cx + 9, y)
            ..lineTo(cx, y + 9)
            ..lineTo(cx - 9, y)
            ..close();
          canvas.drawPath(path, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
