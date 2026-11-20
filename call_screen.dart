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
        'videoUsers': {callerId: isVideo},
        'screenShareUsers': {},
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
        backgroundColor: const Color(0xFF0B141A),
        body: Stack(
          children: [
            const Positioned.fill(
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
  late final ZegoUIKitPrebuiltCallConfig _zegoConfig;
  late final ValueNotifier<bool> _screenShareNotifier;
  final ValueNotifier<int> _elapsedSecondsNotifier = ValueNotifier<int>(0);

  StreamSubscription<DocumentSnapshot>? _callDocSub;
  StreamSubscription<DocumentSnapshot>? _sessionDocSub;
  Stream<DocumentSnapshot>? _otherUserStream;
  Timer? _durationTimer;

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
  bool _controlsVisible = true;

  String? get _effectiveCallDocId =>
      widget.callDocId ?? widget.receiverIdForCleanup;

  bool get _hasAnyVideoOrRemoteShare =>
      _isCameraOn || _isRemoteCameraOn || _isRemoteScreenSharing;

  bool _isEndedStatus(String status) {
    return status == 'ended' ||
        status == 'declined' ||
        status == 'rejected' ||
        status == 'cancelled';
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

    // Use oneOnOneVideoCall base config so tapping 'Video' works seamlessly even in a voice call
    _zegoConfig = ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall();
    _zegoConfig.layout = ZegoLayout.gallery(
      showScreenSharingFullscreenModeToggleButtonRules:
          ZegoShowFullscreenModeToggleButtonRules.alwaysShow,
      showNewScreenSharingViewInFullscreenMode: true,
    );
    _zegoConfig.turnOnCameraWhenJoining = widget.isVideoCall;
    _zegoConfig.turnOnMicrophoneWhenJoining = true;
    _zegoConfig.useSpeakerWhenJoining = widget.isVideoCall;
    _zegoConfig.topMenuBar.isVisible = false;
    _zegoConfig.bottomMenuBar.isVisible = false;
    _zegoConfig.pip.enableWhenBackground = false;

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
      _markLocallyConnected();
      CallLogHelper.markConnected(widget.callID);
    }

    _screenShareNotifier = ZegoUIKit().getScreenSharingStateNotifier();
    _screenShareNotifier.addListener(_onScreenShareStateChanged);

    _setNativeCallState(true);
    _stopNativeRingtone();
    _syncLocalMediaFlags();
    _listenForRemoteHangUp();

    // Sync initial speaker/earpiece route after Zego audio session boots
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && !_cleanedUp) {
        _applySpeakerRouting(_isSpeakerOn);
      }
    });
  }

  void _markLocallyConnected([DateTime? serverTime]) {
    if (_isConnected) return;
    _isConnected = true;
    _connectedAt ??= serverTime ?? DateTime.now();
    _durationTimer?.cancel();
    _elapsedSecondsNotifier.value =
        DateTime.now().difference(_connectedAt!).inSeconds.clamp(0, 86400);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cleanedUp) return;
      final start = _connectedAt ?? DateTime.now();
      _elapsedSecondsNotifier.value =
          DateTime.now().difference(start).inSeconds.clamp(0, 86400);
    });
    if (mounted) setState(() {});
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
    _durationTimer?.cancel();
    _elapsedSecondsNotifier.dispose();
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
    setState(() {
      _isCameraOn = next;
      _controlsVisible = true;
    });
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
        _markLocallyConnected(ts?.toDate());
      }

      // Sync remote camera & remote screen-share state to toggle voice avatar vs live video
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
        _endCallFromRemote();
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
          _endCallFromRemote();
        }
      }
    });
  }

  void _recordCallLog() {
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

    CallLogHelper.finalizeCall(
      callId: widget.callID,
      isVideo: widget.isVideoCall || _isCameraOn || _isRemoteCameraOn,
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

  Future<void> _hangUpNow() async {
    HapticFeedback.mediumImpact();
    _isMinimizing = false;
    await CallCleanupCoordinator.releaseAllHardwareAndRoom();
    _cleanupCallStatus();
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

  Widget _buildWhatsAppButton({
    required IconData icon,
    required String label,
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
      bgColor = const Color(0xFF2B353B);
      iconColor = Colors.white;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bgColor,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 58,
              height: 58,
              child: Icon(icon, color: iconColor, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildWhatsAppTopBar() {
    final displayName = widget.otherUserName ?? 'User';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Top-left Minimize Button (checked in screenshot)
          Material(
            color: const Color(0xFF222C32).withOpacity(0.85),
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
          // Top-center Caller Name + Ringing.../Live Timer (checked in screenshot)
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
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Top-right kept empty (Add Person removed as crossed out)
          const SizedBox(width: 44, height: 44),
        ],
      ),
    );
  }

  Widget _buildWhatsAppControlCard() {
    return ValueListenableBuilder<bool>(
      valueListenable: _screenShareNotifier,
      builder: (_, isSharing, __) {
        return Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2227).withOpacity(0.95),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: Speaker | Video | Mute
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Expanded(
                    child: _buildWhatsAppButton(
                      icon: _isSpeakerOn
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      label: 'Speaker',
                      isActive: _isSpeakerOn,
                      onTap: _toggleSpeaker,
                    ),
                  ),
                  Expanded(
                    child: _buildWhatsAppButton(
                      icon: _isCameraOn
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                      label: 'Video',
                      isActive: _isCameraOn,
                      onTap: _toggleCamera,
                    ),
                  ),
                  Expanded(
                    child: _buildWhatsAppButton(
                      icon: _isMuted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      label: 'Mute',
                      isActive: _isMuted,
                      onTap: _toggleMute,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Row 2: [Flip when Video ON] | Share | End
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Expanded(
                    child: _isCameraOn
                        ? _buildWhatsAppButton(
                            icon: Icons.cameraswitch_rounded,
                            label: 'Flip',
                            isActive: false,
                            onTap: _flipCamera,
                          )
                        : const SizedBox(height: 82),
                  ),
                  Expanded(
                    child: _buildWhatsAppButton(
                      icon: isSharing
                          ? Icons.stop_screen_share_rounded
                          : Icons.present_to_all_rounded,
                      label: 'Share',
                      isActive: isSharing,
                      onTap: _toggleScreenSharing,
                    ),
                  ),
                  Expanded(
                    child: _buildWhatsAppButton(
                      icon: Icons.call_end_rounded,
                      label: 'End',
                      isDestructive: true,
                      onTap: _hangUpNow,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessengerScreenSharingOverlay() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF0B141A),
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
            icon: const Icon(Icons.call_end_rounded, color: Color(0xFFE51C44)),
            label: const Text(
              'End call',
              style: TextStyle(color: Color(0xFFE51C44)),
            ),
            onPressed: _hangUpNow,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userName = _currentUser.displayName ??
        _currentUser.email?.split('@').first ??
        'User';

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
          children: [
            // Underlying Zego audio/video/screen-share engine view
            Positioned.fill(
              child: ZegoUIKitPrebuiltCall(
                appID: CallScreen.zegoAppID,
                appSign: CallScreen.zegoAppSign,
                userID: _currentUser.uid,
                userName: userName,
                callID: widget.callID,
                config: _zegoConfig,
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
                      if (user.id != _currentUser.uid) {
                        _markLocallyConnected();
                        CallLogHelper.markConnected(widget.callID);
                      }
                    },
                    onLeave: (user) {
                      if (user.id != _currentUser.uid) {
                        _isMinimizing = false;
                        CallCleanupCoordinator.releaseAllHardwareAndRoom();
                        _cleanupCallStatus();
                        _endCallFromRemote();
                      }
                    },
                  ),
                ),
              ),
            ),

            // WhatsApp dark voice-call background + center avatar (auto-hides on video/screen share)
            if (!_hasAnyVideoOrRemoteShare)
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF0B141A),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: CustomPaint(painter: _WhatsAppDoodlePainter()),
                      ),
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

            // Tap video area to hide/show controls cleanly during video or screen share
            if (_hasAnyVideoOrRemoteShare)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () =>
                      setState(() => _controlsVisible = !_controlsVisible),
                ),
              ),

            // WhatsApp Top Bar + Bottom Rounded Control Card
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    if (!_hasAnyVideoOrRemoteShare || _controlsVisible)
                      _buildWhatsAppTopBar(),
                    const Spacer(),
                    if (!_hasAnyVideoOrRemoteShare || _controlsVisible)
                      _buildWhatsAppControlCard(),
                  ],
                ),
              ),
            ),

            // Local Screen Sharing Overlay (prevents infinity mirror)
            ValueListenableBuilder<bool>(
              valueListenable: _screenShareNotifier,
              builder: (_, isSharing, __) {
                if (!isSharing) return const SizedBox.shrink();
                return Positioned.fill(
                  child: SafeArea(
                    child: _buildMessengerScreenSharingOverlay(),
                  ),
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
