import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

class CallScreen extends StatefulWidget {
  static const int zegoAppID = 1555115721;
  static const String zegoAppSign =
      'fef324f61318308645c2181add9d7a299ae4018c7ef2ff4341d17dab38b81bef';

  final String callID;
  final bool isVideoCall;
  final String? receiverIdForCleanup;
  final String? callDocId;

  const CallScreen({
    super.key,
    required this.callID,
    required this.isVideoCall,
    this.receiverIdForCleanup,
    this.callDocId,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');

  StreamSubscription<DocumentSnapshot>? _callDocSub;
  StreamSubscription<DocumentSnapshot>? _sessionDocSub;
  bool _allowPop = false;
  bool _cleanedUp = false;
  bool _remoteEnded = false;
  bool _isMinimizing = false;
  bool _callDocExisted = false;

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
    _setNativeCallState(true);
    _stopNativeRingtone();
    _listenForRemoteHangUp();
  }

  @override
  void dispose() {
    _callDocSub?.cancel();
    _sessionDocSub?.cancel();
    if (!_isMinimizing) {
      _cleanupCallStatus();
    }
    super.dispose();
  }

  Future<void> _setNativeCallState(bool active) async {
    try {
      await _nativeChannel.invokeMethod('setCallActive', {'active': active});
    } catch (_) {}
  }

  Future<void> _stopNativeRingtone() async {
    try {
      await _nativeChannel.invokeMethod('stopRingtone');
    } catch (_) {}
  }

  void _listenForRemoteHangUp() {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    // 1. Shared session listener by callID (works reliably for BOTH caller & receiver)
    _sessionDocSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .snapshots()
        .listen((snap) {
      if (_remoteEnded || _cleanedUp || !snap.exists) return;
      final data = snap.data();
      if (data == null) return;
      final status = (data['status'] ?? '').toString();
      if (_isEndedStatus(status)) {
        _endCallFromRemote();
      }
    });

    // 2. Direct calls/{docId} listener (handles ring-time decline/cancel/delete)
    final docId = (_effectiveCallDocId != null && _effectiveCallDocId!.isNotEmpty)
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
        if (_isEndedStatus(status)) {
          _endCallFromRemote();
        }
      }
    });
  }

  Future<void> _endCallFromRemote() async {
    if (_remoteEnded) return;
    _remoteEnded = true;
    _cleanedUp = true;
    _setNativeCallState(false);
    _stopNativeRingtone();

    if (!mounted) return;
    setState(() => _allowPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ZegoUIKitPrebuiltCallController().hangUp(context);
      } catch (_) {}
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  void _cleanupCallStatus() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _setNativeCallState(false);
    _stopNativeRingtone();

    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final payload = {
      'callId': widget.callID,
      'status': 'ended',
      'endedBy': currentUid,
      'endedAt': FieldValue.serverTimestamp(),
    };

    // Always broadcast hang-up on the shared call_sessions doc
    FirebaseFirestore.instance
        .collection('call_sessions')
        .doc(widget.callID)
        .set(payload, SetOptions(merge: true))
        .catchError((_) {});

    // Also update calls/{docId} so ringing/incoming UI stops immediately
    final docId = _effectiveCallDocId;
    if (docId != null && docId.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('calls')
          .doc(docId)
          .set(payload, SetOptions(merge: true))
          .catchError((_) {});
    }

    // If receiver didn't have callDocId passed, also mark their own calls/{uid} doc ended
    if (currentUid.isNotEmpty && currentUid != docId) {
      final ownRef = FirebaseFirestore.instance.collection('calls').doc(currentUid);
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

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser!;
    final userName =
        currentUser.displayName ?? currentUser.email?.split('@').first ?? 'User';

    final config = widget.isVideoCall
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

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
            ZegoCallMenuBarButtonName.toggleScreenSharingButton,
          ]
        : [
            ZegoCallMenuBarButtonName.toggleMicrophoneButton,
            ZegoCallMenuBarButtonName.switchAudioOutputButton,
            ZegoCallMenuBarButtonName.hangUpButton,
            ZegoCallMenuBarButtonName.toggleScreenSharingButton,
          ];

    config.pip.enableWhenBackground = true;

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
              _cleanupCallStatus();
              if (mounted) {
                setState(() => _allowPop = true);
              }
              WidgetsBinding.instance.addPostFrameCallback((_) {
                defaultAction.call();
              });
            },
            user: ZegoCallUserEvents(
              onLeave: (user) {
                if (user.id != currentUser.uid) {
                  _isMinimizing = false;
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
