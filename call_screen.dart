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

  static void attachActiveCall(Future<void> Function() handler) {
    ensureRegistered();
    _activeCallKillHandler = handler;
  }

  static void detachActiveCall(Future<void> Function() handler) {
    if (_activeCallKillHandler == handler) {
      _activeCallKillHandler = null;
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
      await FirebaseFirestore.instance
          .collection('call_sessions')
          .doc(callId)
          .set(payload, SetOptions(merge: true))
          .catchError((_) {});
      await CallLogHelper.finalizeCall(callId: callId, isVideo: false)
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
        'startedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> markConnected(String callId) async {
    if (callId.isEmpty) return;
    try {
      final ref =
          FirebaseFirestore.instance.collection('call_sessions').doc(callId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        final alreadyConnected = data != null && data['connectedAt'] != null;
        tx.set(
          ref,
          {
            'callId': callId,
            'status': 'accepted',
            if (!alreadyConnected) 'connectedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      });
    } catch (_) {}
  }

  static Future<void> finalizeCall({
    required String callId,
    required bool isVideo,
    bool forceMissed = false,
    DateTime? localConnectedAt,
    String? fallbackChatId,
    String? fallbackCallerId,
    String? fallbackCallerName,
    String? fallbackCallerEmail,
    String? fallbackReceiverId,
    String? fallbackReceiverName,
    String? fallbackReceiverEmail,
  }) async {
    if (callId.isEmpty) return;

    final sessionRef =
        FirebaseFirestore.instance.collection('call_sessions').doc(callId);

    Map<String, dynamic>? finalPayload;

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(sessionRef);
        final data = snap.data() ?? <String, dynamic>{};

        if (data['logged'] == true) {
          return;
        }

        final chatId = (data['chatId'] ?? fallbackChatId ?? '').toString();
        final callerId =
            (data['callerId'] ?? fallbackCallerId ?? '').toString();
        final callerName =
            (data['callerName'] ?? fallbackCallerName ?? 'User').toString();
        final callerEmail =
            (data['callerEmail'] ?? fallbackCallerEmail ?? '').toString();
        final receiverId =
            (data['receiverId'] ?? fallbackReceiverId ?? '').toString();
        final receiverName =
            (data['receiverName'] ?? fallbackReceiverName ?? 'User').toString();
        final receiverEmail =
            (data['receiverEmail'] ?? fallbackReceiverEmail ?? '').toString();
        final videoFlag =
            data.containsKey('isVideo') ? (data['isVideo'] == true) : isVideo;

        final connectedTs = data['connectedAt'] as Timestamp?;
        final DateTime? connectedTime =
            connectedTs?.toDate() ?? localConnectedAt;
        final wasAccepted = !forceMissed &&
            (connectedTime != null || data['status'] == 'accepted');

        int durationSec = 0;
        if (wasAccepted) {
          if (connectedTime != null) {
            final diff = DateTime.now().difference(connectedTime).inSeconds;
            durationSec = diff < 1 ? 1 : diff;
          } else {
            durationSec = 1;
          }
        }

        final callStatus = wasAccepted ? 'completed' : 'missed';
        final endedStatus =
            wasAccepted ? 'ended' : (forceMissed ? 'declined' : 'ended');

        tx.set(
          sessionRef,
          {
            'callId': callId,
            'status': endedStatus,
            'callStatus': callStatus,
            'durationSec': durationSec,
            'logged': true,
            'endedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        finalPayload = {
          'chatId': chatId,
          'callerId': callerId,
          'callerName': callerName,
          'callerEmail': callerEmail,
          'receiverId': receiverId,
          'receiverName': receiverName,
          'receiverEmail': receiverEmail,
          'isVideo': videoFlag,
          'callStatus': callStatus,
          'durationSec': durationSec,
        };
      });
    } catch (_) {
      return;
    }

    final payload = finalPayload;
    if (payload == null) return;

    final callerId = (payload['callerId'] ?? '').toString();
    final receiverId = (payload['receiverId'] ?? '').toString();
    var chatId = (payload['chatId'] ?? '').toString();

    if (chatId.isEmpty && callerId.isNotEmpty && receiverId.isNotEmpty) {
      final ids = [callerId, receiverId]..sort();
      chatId = '${ids[0]}_${ids[1]}';
    }
    if (chatId.isEmpty || callerId.isEmpty || receiverId.isEmpty) return;

    final videoFlag = payload['isVideo'] == true;
    final isMissed = payload['callStatus'] == 'missed';
    final durationSec = (payload['durationSec'] as int?) ?? 0;

    final summaryText = isMissed
        ? (videoFlag ? 'Missed video call' : 'Missed voice call')
        : '${videoFlag ? 'Video call' : 'Voice call'} • ${formatDuration(durationSec)}';

    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
        'senderId': callerId,
        'receiverId': receiverId,
        'text': summaryText,
        'type': 'call',
        'callId': callId,
        'isVideo': videoFlag,
        'callStatus': isMissed ? 'missed' : 'completed',
        'durationSec': durationSec,
        'isSeen': !isMissed,
        'isEdited': false,
        'timestamp': FieldValue.serverTimestamp(),
      });

      final chatUpdate = <String, dynamic>{
        'chatId': chatId,
        'participants': [callerId, receiverId],
        'lastMessage': summaryText,
        'lastMessageType': 'call',
        'lastCallStatus': isMissed ? 'missed' : 'completed',
        'lastCallIsVideo': videoFlag,
        'lastCallDurationSec': durationSec,
        'lastCallCallerId': callerId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastSenderId': callerId,
        'users': {
          callerId: {
            'name': payload['callerName'] ?? 'User',
            'email': payload['callerEmail'] ?? '',
          },
          receiverId: {
            'name': payload['receiverName'] ?? 'User',
            'email': payload['receiverEmail'] ?? '',
          },
        },
      };

      if (isMissed) {
        chatUpdate['unreadCount'] = {
          receiverId: FieldValue.increment(1),
        };
        chatUpdate['missedCallCount'] = {
          receiverId: FieldValue.increment(1),
        };
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .set(chatUpdate, SetOptions(merge: true));
    } catch (_) {}
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

    CallLogHelper.finalizeCall(
      callId: widget.callID,
      isVideo: widget.isVideoCall,
      forceMissed: true,
      fallbackChatId: widget.chatId,
      fallbackCallerId: widget.callerId,
      fallbackCallerName: widget.callerName,
      fallbackCallerEmail: widget.callerEmail,
      fallbackReceiverId: currentUser?.uid ?? widget.callDocId,
      fallbackReceiverName:
          currentUser?.displayName ?? currentUser?.email ?? 'User',
      fallbackReceiverEmail: currentUser?.email ?? '',
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
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0A192F), Color(0xFF0F2B46), Color(0xFF07131F)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
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
                              color: Colors.lightBlueAccent.withOpacity(alpha),
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
                                color: Color(0xFFE53935),
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
                                color: Color(0xFF2E9E47),
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

  StreamSubscription<DocumentSnapshot>? _callDocSub;
  StreamSubscription<DocumentSnapshot>? _sessionDocSub;
  late final ValueNotifier<bool> _screenShareNotifier;

  bool _allowPop = false;
  bool _cleanedUp = false;
  bool _remoteEnded = false;
  bool _isMinimizing = false;
  bool _callDocExisted = false;
  bool _wasScreenSharing = false;
  DateTime? _connectedAt;

  String? get _effectiveCallDocId =>
      widget.callDocId ?? widget.receiverIdForCleanup;

  bool _isEndedStatus(String status) {
    return status == 'ended' ||
        status == 'declined' ||
        status == 'rejected' ||
        status == 'cancelled';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CallCleanupCoordinator.attachActiveCall(_handleAppKilledDuringCall);

    NotificationAndPresenceService.isInActiveCall = true;
    NotificationAndPresenceService.stopNativeCallRingtone();
    NotificationAndPresenceService.showOngoingCallNotification(
      isVideo: widget.isVideoCall,
      otherName: widget.otherUserName ?? 'Call',
      isScreenSharing: false,
    );

    if (!widget.isCaller) {
      _connectedAt = DateTime.now();
      CallLogHelper.markConnected(widget.callID);
    }
    _screenShareNotifier = ZegoUIKit().getScreenSharingStateNotifier();
    _screenShareNotifier.addListener(_onScreenShareStateChanged);
    _setNativeCallState(true);
    _stopNativeRingtone();
    _listenForRemoteHangUp();
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
    _cleanupCallStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CallCleanupCoordinator.detachActiveCall(_handleAppKilledDuringCall);
    _screenShareNotifier.removeListener(_onScreenShareStateChanged);
    _callDocSub?.cancel();
    _sessionDocSub?.cancel();
    if (!_isMinimizing) {
      CallCleanupCoordinator.releaseAllHardwareAndRoom();
      _cleanupCallStatus();
    }
    super.dispose();
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

    if (!_cleanedUp) {
      NotificationAndPresenceService.showOngoingCallNotification(
        isVideo: widget.isVideoCall,
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
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    _sessionDocSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .snapshots()
        .listen((snap) {
      if (_remoteEnded || _cleanedUp || !snap.exists) return;
      final data = snap.data();
      if (data == null) return;
      final status = (data['status'] ?? '').toString();
      if (status == 'accepted' && _connectedAt == null) {
        final ts = data['connectedAt'] as Timestamp?;
        _connectedAt = ts?.toDate() ?? DateTime.now();
      }
      if (_isEndedStatus(status)) {
        _endCallFromRemote();
      }
    });

    final docId =
        (_effectiveCallDocId != null && _effectiveCallDocId!.isNotEmpty)
            ? _effectiveCallDocId!
            : (currentUid ?? '');
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
        if (status == 'accepted' && _connectedAt == null) {
          _connectedAt = DateTime.now();
        }
        if (_isEndedStatus(status)) {
          _endCallFromRemote();
        }
      }
    });
  }

  void _recordCallLog() {
    final user = FirebaseAuth.instance.currentUser;
    final myUid = user?.uid ?? '';
    final myName = user?.displayName ?? user?.email ?? 'User';
    final myEmail = user?.email ?? '';

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

    CallLogHelper.finalizeCall(
      callId: widget.callID,
      isVideo: widget.isVideoCall,
      localConnectedAt: _connectedAt,
      fallbackChatId: widget.chatId,
      fallbackCallerId: callerId,
      fallbackCallerName: callerName,
      fallbackCallerEmail: callerEmail,
      fallbackReceiverId: receiverId,
      fallbackReceiverName: receiverName,
      fallbackReceiverEmail: receiverEmail,
    );
  }

  Future<void> _endCallFromRemote() async {
    if (_remoteEnded) return;
    _remoteEnded = true;
    _cleanedUp = true;
    NotificationAndPresenceService.isInActiveCall = false;
    NotificationAndPresenceService.clearCallNotifications();
    await CallCleanupCoordinator.releaseAllHardwareAndRoom();
    _setNativeCallState(false);
    _stopNativeRingtone();
    _recordCallLog();

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

  void _cleanupCallStatus() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    NotificationAndPresenceService.isInActiveCall = false;
    NotificationAndPresenceService.clearCallNotifications();
    _stopScreenSharingImmediately();
    _setNativeCallState(false);
    _stopNativeRingtone();
    _recordCallLog();

    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
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
  }

  void _minimizeCall() {
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

  Widget _buildScreenShareButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: _screenShareNotifier,
      builder: (context, isSharing, _) {
        return GestureDetector(
          onTap: _toggleScreenSharing,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isSharing ? Colors.redAccent : Colors.white24,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSharing
                  ? Icons.stop_screen_share_rounded
                  : Icons.screen_share_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        );
      },
    );
  }

  // Clean English-only Messenger-style screen sharing view
  Widget _buildMessengerScreenSharingOverlay() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF0E141B),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: const Color(0xFF1A73E8).withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.screen_share_rounded,
              color: Color(0xFF42A5F5),
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
                backgroundColor: const Color(0xFF1A73E8),
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
                backgroundColor: const Color(0xFFE53935),
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
            icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
            label: const Text(
              'End call',
              style: TextStyle(color: Colors.redAccent),
            ),
            onPressed: () async {
              _isMinimizing = false;
              await CallCleanupCoordinator.releaseAllHardwareAndRoom();
              _cleanupCallStatus();
              if (mounted) setState(() => _allowPop = true);
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!mounted) return;
                try {
                  await ZegoUIKitPrebuiltCallController().hangUp(context);
                } catch (_) {}
                if (mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              });
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser!;
    final userName =
        currentUser.displayName ?? currentUser.email?.split('@').first ?? 'User';

    final config = widget.isVideoCall
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

    config.layout = ZegoLayout.gallery(
      showScreenSharingFullscreenModeToggleButtonRules:
          ZegoShowFullscreenModeToggleButtonRules.alwaysShow,
      showNewScreenSharingViewInFullscreenMode: true,
    );

    config.turnOnCameraWhenJoining = widget.isVideoCall;
    config.turnOnMicrophoneWhenJoining = true;
    config.useSpeakerWhenJoining = widget.isVideoCall;

    config.topMenuBar.isVisible = true;
    config.topMenuBar.hideAutomatically = false;
    config.topMenuBar.hideByClick = false;
    config.topMenuBar.buttons = [
      ZegoCallMenuBarButtonName.minimizingButton,
      ZegoCallMenuBarButtonName.showMemberListButton,
    ];

    config.bottomMenuBar.isVisible = true;
    config.bottomMenuBar.hideAutomatically = false;
    config.bottomMenuBar.hideByClick = false;
    config.bottomMenuBar.maxCount = 5;
    config.bottomMenuBar.buttons = widget.isVideoCall
        ? [
            ZegoCallMenuBarButtonName.toggleCameraButton,
            ZegoCallMenuBarButtonName.switchCameraButton,
            ZegoCallMenuBarButtonName.hangUpButton,
            ZegoCallMenuBarButtonName.toggleMicrophoneButton,
          ]
        : [
            ZegoCallMenuBarButtonName.toggleMicrophoneButton,
            ZegoCallMenuBarButtonName.switchAudioOutputButton,
            ZegoCallMenuBarButtonName.hangUpButton,
          ];
    config.bottomMenuBar.extendButtons = [_buildScreenShareButton()];

    config.pip.enableWhenBackground = false;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _minimizeCall();
        }
      },
      child: SafeArea(
        child: Stack(
          children: [
            ZegoUIKitPrebuiltCall(
              appID: CallScreen.zegoAppID,
              appSign: CallScreen.zegoAppSign,
              userID: currentUser.uid,
              userName: userName,
              callID: widget.callID,
              config: config,
              events: ZegoUIKitPrebuiltCallEvents(
                onCallEnd: (event, defaultAction) {
                  _isMinimizing = false;
                  CallCleanupCoordinator.releaseAllHardwareAndRoom();
                  _cleanupCallStatus();
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
                    if (user.id != currentUser.uid && _connectedAt == null) {
                      _connectedAt = DateTime.now();
                      CallLogHelper.markConnected(widget.callID);
                    }
                  },
                  onLeave: (user) {
                    if (user.id != currentUser.uid) {
                      _isMinimizing = false;
                      CallCleanupCoordinator.releaseAllHardwareAndRoom();
                      _cleanupCallStatus();
                      _endCallFromRemote();
                    }
                  },
                ),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _screenShareNotifier,
              builder: (_, isSharing, __) {
                if (!isSharing) return const SizedBox.shrink();
                return _buildMessengerScreenSharingOverlay();
              },
            ),
          ],
        ),
      ),
    );
  }
}
