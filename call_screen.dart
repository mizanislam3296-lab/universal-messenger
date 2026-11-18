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
  bool _allowPop = false;
  bool _cleanedUp = false;
  bool _remoteEnded = false;

  String? get _effectiveCallDocId =>
      widget.callDocId ?? widget.receiverIdForCleanup;

  @override
  void initState() {
    super.initState();
    _setNativeCallState(true);
    _listenForRemoteHangUp();
  }

  @override
  void dispose() {
    _callDocSub?.cancel();
    _cleanupCallStatus();
    super.dispose();
  }

  Future<void> _setNativeCallState(bool active) async {
    try {
      await _nativeChannel.invokeMethod('setCallActive', {'active': active});
    } catch (_) {}
  }

  void _listenForRemoteHangUp() {
    final docId = _effectiveCallDocId;
    if (docId == null || docId.isEmpty) return;

    _callDocSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(docId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || _remoteEnded || _cleanedUp) return;
      final data = snap.data();
      if (data == null) return;

      final docCallId = (data['callId'] ?? '').toString();
      final status = (data['status'] ?? '').toString();

      if (docCallId == widget.callID &&
          (status == 'ended' || status == 'declined')) {
        _endCallFromRemote();
      }
    });
  }

  void _endCallFromRemote() {
    if (_remoteEnded) return;
    _remoteEnded = true;
    _cleanedUp = true;
    _setNativeCallState(false);

    if (!mounted) return;
    setState(() => _allowPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ZegoUIKitPrebuiltCallController().hangUp(context);
      } catch (_) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  void _cleanupCallStatus() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _setNativeCallState(false);

    final docId = _effectiveCallDocId;
    if (docId != null && docId.isNotEmpty) {
      FirebaseFirestore.instance.collection('calls').doc(docId).set({
        'callId': widget.callID,
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  void _minimizeCall() {
    if (_allowPop || _remoteEnded) return;
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
              setState(() => _allowPop = true);
              _cleanupCallStatus();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                defaultAction.call();
              });
            },
            user: ZegoCallUserEvents(
              onLeave: (user) {
                if (user.id != currentUser.uid) {
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
