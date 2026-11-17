import 'package:flutter/material.dart';
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

  const CallScreen({
    super.key,
    required this.callID,
    required this.isVideoCall,
    this.receiverIdForCleanup,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _allowPop = false;

  void _cleanupCallStatus() {
    if (widget.receiverIdForCleanup != null) {
      FirebaseFirestore.instance
          .collection('calls')
          .doc(widget.receiverIdForCleanup)
          .set({'status': 'ended'}, SetOptions(merge: true));
    }
  }

  void _minimizeCall() {
    if (_allowPop) return;
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

    config.topMenuBar.isVisible = true;
    config.topMenuBar.buttons = [
      ZegoCallMenuBarButtonName.minimizingButton,
      ZegoCallMenuBarButtonName.showMemberListButton,
    ];

    config.pip.enableWhenBackground = true;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _minimizeCall();
        }
      },
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
        ),
      ),
    );
  }
}
