import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

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

class _CallScreenState extends State<CallScreen> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');

  StreamSubscription<DocumentSnapshot>? _callDocSub;
  StreamSubscription<DocumentSnapshot>? _sessionDocSub;
  late final ValueNotifier<bool> _screenShareNotifier;
  Timer? _audioTuneTimer;

  bool _allowPop = false;
  bool _cleanedUp = false;
  bool _remoteEnded = false;
  bool _isMinimizing = false;
  bool _callDocExisted = false;
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
    if (!widget.isCaller) {
      _connectedAt = DateTime.now();
      CallLogHelper.markConnected(widget.callID);
    }
    _screenShareNotifier = ZegoUIKit().getScreenSharingStateNotifier();
    _screenShareNotifier.addListener(_onScreenShareStateChanged);
    _setNativeCallState(true);
    _stopNativeRingtone();
    _listenForRemoteHangUp();

    // Apply clear voice DSP + hardware acceleration after Zego engine boots
    _audioTuneTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && !_cleanedUp) {
        _applyClearAudioAndHardwareSettings();
      }
    });
  }

  @override
  void dispose() {
    _audioTuneTimer?.cancel();
    _screenShareNotifier.removeListener(_onScreenShareStateChanged);
    _callDocSub?.cancel();
    _sessionDocSub?.cancel();
    if (!_isMinimizing) {
      _stopScreenSharingImmediately();
      _cleanupCallStatus();
    }
    super.dispose();
  }

  Future<void> _applyClearAudioAndHardwareSettings() async {
    try {
      final engine = ZegoExpressEngine.instance;
      // Hardware acceleration keeps video & screen share real-time and lag-free
      await engine.enableHardwareEncoder(true);
      await engine.enableHardwareDecoder(true);
      // Aggressive echo cancellation + noise suppression + auto gain for clear soft speech
      await engine.enableAEC(true);
      await engine.enableHeadphoneAEC(true);
      await engine.setAECMode(ZegoAECMode.Aggressive);
      await engine.enableANS(true);
      await engine.setANSMode(ZegoANSMode.Aggressive);
      await engine.enableAGC(true);
      await engine.setCaptureVolume(155);
    } catch (_) {}
  }

  Future<void> _optimizeScreenShareStream() async {
    try {
      final engine = ZegoExpressEngine.instance;
      await engine.enableHardwareEncoder(true);
      await engine.enableHardwareDecoder(true);
      // 540P @ 20fps / 1000kbps gives crisp, low-latency real-time screen share on mobile data
      final auxConfig = ZegoVideoConfig.preset(ZegoVideoConfigPreset.Preset540P);
      auxConfig.fps = 20;
      auxConfig.bitrate = 1000;
      await engine.setVideoConfig(auxConfig, channel: ZegoPublishChannel.Aux);
    } catch (_) {}
  }

  void _onScreenShareStateChanged() {
    final sharing = _screenShareNotifier.value;
    _setNativeScreenSharing(sharing);
    if (sharing) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _screenShareNotifier.value && !_cleanedUp) {
          _optimizeScreenShareStream();
        }
      });
    }
  }

  Future<void> _setNativeCallState(bool active) async {
    try {
      await _nativeChannel.invokeMethod('setCallActive', {'active': active});
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

  void _stopScreenSharingImmediately() {
    try {
      ZegoUIKit().stopSharingScreen();
    } catch (_) {}
    try {
      _nativeChannel.invokeMethod('stopScreenShareService');
    } catch (_) {}
  }

  Future<void> _toggleScreenSharing() async {
    final currentlySharing = _screenShareNotifier.value;
    if (currentlySharing) {
      _stopScreenSharingImmediately();
      return;
    }

    try {
      await _nativeChannel.invokeMethod('suppressPipOnce', true);
      await _nativeChannel.invokeMethod('setScreenSharing', {'active': true});
    } catch (_) {}

    await _optimizeScreenShareStream();

    try {
      ZegoUIKit().startSharingScreen();
    } catch (_) {
      await _setNativeScreenSharing(false);
    }

    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _screenShareNotifier.value && !_cleanedUp) {
        _optimizeScreenShareStream();
      }
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && !_screenShareNotifier.value) {
        _setNativeScreenSharing(false);
      }
    });
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
    _stopScreenSharingImmediately();
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
        child: ZegoUIKitPrebuiltCall(
          appID: CallScreen.zegoAppID,
          appSign: CallScreen.zegoAppSign,
          userID: currentUser.uid,
          userName: userName,
          callID: widget.callID,
          config: config,
          events: ZegoUIKitPrebuiltCallEvents(
            onCallEnd: (event, defaultAction) {
              _isMinimizing = false;
              _stopScreenSharingImmediately();
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
                  _applyClearAudioAndHardwareSettings();
                }
              },
              onLeave: (user) {
                if (user.id != currentUser.uid) {
                  _isMinimizing = false;
                  _stopScreenSharingImmediately();
                  _cleanupCallStatus();
                  _endCallFromRemote();
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}
