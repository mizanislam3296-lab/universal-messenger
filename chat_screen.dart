import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

class _UploadCancelledException implements Exception {}

class _NativeChatInputController {
  MethodChannel? _channel;
  String _text = '';

  String get text => _text;

  void attach(MethodChannel channel) {
    _channel = channel;
  }

  void detach(MethodChannel channel) {
    if (_channel == channel) {
      _channel = null;
    }
  }

  void updateLocalText(String val) {
    _text = val;
  }

  Future<String> fetchLatestText() async {
    final ch = _channel;
    if (ch != null) {
      try {
        final latest = await ch.invokeMethod<String>('getText');
        if (latest != null) {
          _text = latest;
        }
      } catch (_) {}
    }
    return _text;
  }

  Future<void> clear() async {
    _text = '';
    try {
      await _channel?.invokeMethod('clear');
    } catch (_) {}
  }

  Future<void> requestFocus() async {
    try {
      await _channel?.invokeMethod('requestFocus');
    } catch (_) {}
  }
}

class _NativeAndroidChatInput extends StatefulWidget {
  final _NativeChatInputController controller;
  final bool isDark;
  final ValueChanged<String> onChanged;

  const _NativeAndroidChatInput({
    super.key,
    required this.controller,
    required this.isDark,
    required this.onChanged,
  });

  @override
  State<_NativeAndroidChatInput> createState() =>
      _NativeAndroidChatInputState();
}

class _NativeAndroidChatInputState extends State<_NativeAndroidChatInput> {
  static final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
    Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
  };

  MethodChannel? _channel;
  double _height = 44.0;

  @override
  void didUpdateWidget(covariant _NativeAndroidChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isDark != widget.isDark) {
      _channel?.invokeMethod('setTheme', widget.isDark).catchError((_) {});
    }
  }

  @override
  void dispose() {
    if (_channel != null) {
      _channel!.setMethodCallHandler(null);
      widget.controller.detach(_channel!);
    }
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    final ch = MethodChannel('com.universal.messenger/native_chat_input_$id');
    _channel = ch;
    widget.controller.attach(ch);
    ch.setMethodCallHandler((call) async {
      if (call.method == 'onTextChanged') {
        final text = (call.arguments as String?) ?? '';
        widget.controller.updateLocalText(text);
        widget.onChanged(text);
      } else if (call.method == 'onHeightChanged') {
        final h = (call.arguments as num?)?.toDouble();
        if (h != null && mounted && (h - _height).abs() >= 1.5) {
          setState(() => _height = h.clamp(44.0, 124.0));
        }
      }
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.isDark ? const Color(0xFF2A3942) : Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _height,
        child: PlatformViewLink(
          viewType: 'com.universal.messenger/native_chat_input',
          surfaceFactory: (context, controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers: _gestureRecognizers,
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            );
          },
          onCreatePlatformView: (params) {
            return PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: 'com.universal.messenger/native_chat_input',
              layoutDirection: TextDirection.ltr,
              creationParams: <String, dynamic>{
                'hint': 'মেসেজ লিখুন...',
                'isDark': widget.isDark,
              },
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () {
                params.onFocusChanged(true);
              },
            )
              ..addOnPlatformViewCreatedListener((int id) {
                params.onPlatformViewCreated(id);
                _onPlatformViewCreated(id);
              })
              ..create();
          },
        ),
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String receiverId;
  final String receiverName;
  final String receiverEmail;

  const ChatScreen({
    super.key,
    required this.receiverId,
    required this.receiverName,
    required this.receiverEmail,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const String _cloudName = 'tcdkckrl';
  static const String _uploadPreset = 'ml_default';
  static const int _pageSize = 40;
  static const int _chunkSizeBytes = 6 * 1024 * 1024; // 6 MB chunks for stability
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');
  static final Dio _sharedDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      sendTimeout: const Duration(minutes: 10),
    ),
  );
  static const List<String> _reactionEmojis = [
    '❤️',
    '😂',
    '😮',
    '😢',
    '😡',
    '👍',
    '🙏',
    '🔥',
  ];

  final _nativeInputController = _NativeChatInputController();
  final _scrollController = ScrollController();
  late final String _chatId;
  late final User _currentUser;

  late final Stream<DocumentSnapshot> _receiverUserStream;
  late final Stream<DocumentSnapshot> _chatDocStream;
  late final Stream<QuerySnapshot> _scheduledStream;
  late Stream<QuerySnapshot> _messagesStream;

  int _messageLimit = _pageSize;
  int _lastFetchedCount = 0;
  bool _isLoadingMore = false;
  final Set<String> _markedSeenIds = {};
  String? _lastMarkedLatestMsgId;

  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadingFileName = '';
  String _uploadingFileSize = '';
  CancelToken? _uploadCancelToken;

  bool _isTyping = false;
  Timer? _typingTimer;

  Map<String, dynamic>? _replyingTo;

  @override
  void initState() {
    super.initState();
    final imageCache = PaintingBinding.instance.imageCache;
    if (imageCache.maximumSize > 80) {
      imageCache.maximumSize = 80;
    }
    if (imageCache.maximumSizeBytes > (60 << 20)) {
      imageCache.maximumSizeBytes = 60 << 20;
    }

    _currentUser = FirebaseAuth.instance.currentUser!;
    final ids = [_currentUser.uid, widget.receiverId]..sort();
    _chatId = '${ids[0]}_${ids[1]}';
    NotificationAndPresenceService.activeChatId = _chatId;

    _receiverUserStream = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.receiverId)
        .snapshots();
    _chatDocStream = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .snapshots();
    _scheduledStream = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser.uid)
        .collection('scheduled_messages')
        .where('status', isEqualTo: 'pending')
        .snapshots();
    _messagesStream = _buildMessagesStream();

    _scrollController.addListener(_onScroll);
    _markAsRead();
    ScheduledMessageService.checkAndSendDueMessages();
  }

  Stream<QuerySnapshot> _buildMessagesStream() {
    return FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(_messageLimit)
        .snapshots();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isLoadingMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_lastFetchedCount >= _messageLimit) {
        setState(() {
          _isLoadingMore = true;
          _messageLimit += _pageSize;
          _messagesStream = _buildMessagesStream();
        });
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) setState(() => _isLoadingMore = false);
        });
      }
    }
  }

  @override
  void dispose() {
    if (NotificationAndPresenceService.activeChatId == _chatId) {
      NotificationAndPresenceService.activeChatId = null;
    }
    if (_uploadCancelToken != null && !_uploadCancelToken!.isCancelled) {
      _uploadCancelToken!.cancel('Chat screen closed');
    }
    _typingTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    if (_isTyping) {
      FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'typing': {_currentUser.uid: false},
      }, SetOptions(merge: true));
    }
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markAsRead() async {
    try {
      await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'unreadCount': {_currentUser.uid: 0},
        'missedCallCount': {_currentUser.uid: 0},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  void _markMessagesAsSeen(List<QueryDocumentSnapshot> docs) {
    if (docs.isEmpty) return;
    final latestId = docs.first.id;
    if (_lastMarkedLatestMsgId != latestId) {
      _lastMarkedLatestMsgId = latestId;
      _markAsRead();
    }

    final batch = FirebaseFirestore.instance.batch();
    bool hasUpdates = false;
    for (final doc in docs) {
      if (_markedSeenIds.contains(doc.id)) continue;
      final data = doc.data() as Map<String, dynamic>;
      if (data['senderId'] != _currentUser.uid &&
          (data['isSeen'] ?? false) == false) {
        _markedSeenIds.add(doc.id);
        batch.update(doc.reference, {'isSeen': true});
        hasUpdates = true;
      }
    }
    if (hasUpdates) batch.commit().catchError((_) {});
  }

  Future<void> _setTypingStatus(bool typing) async {
    if (_isTyping == typing) return;
    _isTyping = typing;
    try {
      await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'typing': {_currentUser.uid: typing},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  void _onTextChanged(String val) {
    if (val.trim().isNotEmpty) {
      if (!_isTyping) _setTypingStatus(true);
      _typingTimer?.cancel();
      _typingTimer =
          Timer(const Duration(seconds: 3), () => _setTypingStatus(false));
    } else {
      _typingTimer?.cancel();
      if (_isTyping) _setTypingStatus(false);
    }
  }

  Future<void> _startCall(bool isVideo) async {
    final callId = '${_chatId}_${DateTime.now().millisecondsSinceEpoch}';
    final callerName = _currentUser.displayName ?? _currentUser.email ?? 'User';
    final callerEmail = _currentUser.email ?? '';

    await CallLogHelper.startSession(
      callId: callId,
      chatId: _chatId,
      callerId: _currentUser.uid,
      callerName: callerName,
      callerEmail: callerEmail,
      receiverId: widget.receiverId,
      receiverName: widget.receiverName,
      receiverEmail: widget.receiverEmail,
      isVideo: isVideo,
    );

    await FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.receiverId)
        .set({
      'callId': callId,
      'chatId': _chatId,
      'callerId': _currentUser.uid,
      'callerName': callerName,
      'callerEmail': callerEmail,
      'receiverId': widget.receiverId,
      'receiverName': widget.receiverName,
      'receiverEmail': widget.receiverEmail,
      'isVideo': isVideo,
      'status': 'ringing',
      'timestamp': FieldValue.serverTimestamp(),
    });

    FcmPushService.sendPushToUser(
      receiverId: widget.receiverId,
      title: isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
      body: '$callerName is calling...',
      isCall: true,
      isVideo: isVideo,
      chatId: _chatId,
      callId: callId,
      callerId: _currentUser.uid,
      callerName: callerName,
      callerEmail: callerEmail,
    );

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callID: callId,
          isVideoCall: isVideo,
          receiverIdForCleanup: widget.receiverId,
          callDocId: widget.receiverId,
          chatId: _chatId,
          otherUserId: widget.receiverId,
          otherUserName: widget.receiverName,
          otherUserEmail: widget.receiverEmail,
          isCaller: true,
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _detectFileType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic')) return 'image';
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.3gp')) return 'video';
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus') ||
        lower.endsWith('.flac')) return 'audio';
    if (lower.endsWith('.pdf')) return 'pdf';
    return 'file';
  }

  Future<void> _updateChatSummary(String lastMessageText,
      {String messageType = 'text'}) async {
    await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
      'chatId': _chatId,
      'participants': [_currentUser.uid, widget.receiverId],
      'lastMessage': lastMessageText,
      'lastMessageType': messageType,
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastSenderId': _currentUser.uid,
      'unreadCount': {
        widget.receiverId: FieldValue.increment(1),
        _currentUser.uid: 0,
      },
      'typing': {_currentUser.uid: false},
      'users': {
        _currentUser.uid: {
          'name': _currentUser.displayName ?? _currentUser.email ?? 'User',
          'email': _currentUser.email ?? '',
        },
        widget.receiverId: {
          'name': widget.receiverName,
          'email': widget.receiverEmail,
        },
      },
    }, SetOptions(merge: true));
  }

  void _selectReplyMessage(String docId, Map<String, dynamic> data, bool isMe) {
    final type = (data['type'] ?? 'text').toString();
    String previewText = (data['text'] ?? '').toString();
    if (type == 'image') {
      previewText = '📷 ছবি';
    } else if (type == 'video') {
      previewText = '🎥 ভিডিও: $previewText';
    } else if (type == 'audio') {
      previewText = '🎵 অডিও: $previewText';
    } else if (type == 'pdf' || type == 'file') {
      previewText = '📎 $previewText';
    }

    setState(() {
      _replyingTo = {
        'id': docId,
        'text': previewText,
        'senderName': isMe ? 'আপনি' : widget.receiverName,
      };
    });
    _nativeInputController.requestFocus();
  }

  Future<void> _sendMessage() async {
    final text = (await _nativeInputController.fetchLatestText()).trim();
    if (text.isEmpty) return;

    final replyPayload = _replyingTo;
    await _nativeInputController.clear();
    _typingTimer?.cancel();
    _isTyping = false;
    if (_replyingTo != null && mounted) {
      setState(() => _replyingTo = null);
    }

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .add({
      'senderId': _currentUser.uid,
      'receiverId': widget.receiverId,
      'text': text,
      'type': 'text',
      'isSeen': false,
      'isEdited': false,
      if (replyPayload != null) 'replyTo': replyPayload,
      'timestamp': FieldValue.serverTimestamp(),
    });
    await _updateChatSummary(text, messageType: 'text');

    FcmPushService.sendPushToUser(
      receiverId: widget.receiverId,
      title: _currentUser.displayName ?? _currentUser.email ?? 'নতুন মেসেজ',
      body: text,
      chatId: _chatId,
    );
  }

  String _formatDateTime(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$day/$month/${dt.year} • $hour:$min $period';
  }

  Future<void> _saveScheduledMessage(String text, DateTime scheduledTime,
      Map<String, dynamic>? replyPayload) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser.uid)
          .collection('scheduled_messages')
          .add({
        'chatId': _chatId,
        'senderId': _currentUser.uid,
        'receiverId': widget.receiverId,
        'receiverName': widget.receiverName,
        'receiverEmail': widget.receiverEmail,
        'text': text,
        if (replyPayload != null) 'replyTo': replyPayload,
        'scheduledAt': Timestamp.fromDate(scheduledTime),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _nativeInputController.clear();
      _typingTimer?.cancel();
      if (_isTyping) _setTypingStatus(false);
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('মেসেজ শিডিউল হয়েছে: ${_formatDateTime(scheduledTime)}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('শিডিউল করতে সমস্যা হয়েছে: $e'),
            backgroundColor: Colors.red.shade700),
      );
    }
  }

  Future<void> _openScheduleMessageSheet(Color barColor) async {
    final text = (await _nativeInputController.fetchLatestText()).trim();
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('আগে মেসেজ লিখুন, তারপর সেন্ড বাটনে হোল্ড করে শিডিউল করুন'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    HapticFeedback.mediumImpact();
    final replyPayload = _replyingTo;
    DateTime selectedDateTime = DateTime.now().add(const Duration(minutes: 10));

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> pickCustomDateTime() async {
              final now = DateTime.now();
              final pickedDate = await showDatePicker(
                context: ctx,
                initialDate:
                    selectedDateTime.isAfter(now) ? selectedDateTime : now,
                firstDate: now,
                lastDate: now.add(const Duration(days: 365)),
              );
              if (pickedDate == null || !ctx.mounted) return;
              final pickedTime = await showTimePicker(
                context: ctx,
                initialTime: TimeOfDay.fromDateTime(selectedDateTime),
              );
              if (pickedTime == null) return;
              setSheetState(() {
                selectedDateTime = DateTime(
                  pickedDate.year,
                  pickedDate.month,
                  pickedDate.day,
                  pickedTime.hour,
                  pickedTime.minute,
                );
              });
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.grey.shade400,
                            borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(Icons.schedule_send_rounded, color: barColor),
                        const SizedBox(width: 8),
                        const Text('মেসেজ শিডিউল করুন',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: barColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.timer_outlined, size: 16),
                          label: const Text('৫ মিনিট পর'),
                          onPressed: () => setSheetState(() =>
                              selectedDateTime =
                                  DateTime.now().add(const Duration(minutes: 5))),
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.timer_outlined, size: 16),
                          label: const Text('১৫ মিনিট পর'),
                          onPressed: () => setSheetState(() =>
                              selectedDateTime = DateTime.now()
                                  .add(const Duration(minutes: 15))),
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.timer_outlined, size: 16),
                          label: const Text('১ ঘণ্টা পর'),
                          onPressed: () => setSheetState(() =>
                              selectedDateTime =
                                  DateTime.now().add(const Duration(hours: 1))),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.grey.shade400),
                      ),
                      leading:
                          Icon(Icons.calendar_month_rounded, color: barColor),
                      title: const Text('তারিখ ও সময়',
                          style: TextStyle(fontSize: 12)),
                      subtitle: Text(_formatDateTime(selectedDateTime),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      trailing: const Icon(Icons.edit_calendar_rounded),
                      onTap: pickCustomDateTime,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('বাতিল'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: barColor,
                                foregroundColor: Colors.white),
                            icon: const Icon(Icons.schedule_send_rounded,
                                size: 18),
                            label: const Text('শিডিউল করুন'),
                            onPressed: () async {
                              if (!selectedDateTime.isAfter(DateTime.now())) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'অনুগ্রহ করে ভবিষ্যতের সময় নির্বাচন করুন')),
                                );
                                return;
                              }
                              Navigator.pop(ctx);
                              await _saveScheduledMessage(
                                  text, selectedDateTime, replyPayload);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openPendingScheduledList(
      List<QueryDocumentSnapshot> pendingDocs, Color barColor) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(4))),
              ),
              const SizedBox(height: 12),
              Text('শিডিউল মেসেজ (${pendingDocs.length})',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: pendingDocs.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (_, idx) {
                    final doc = pendingDocs[idx];
                    final d = (doc.data() as Map<String, dynamic>?) ??
                        <String, dynamic>{};
                    final ts = (d['scheduledAt'] as Timestamp?)?.toDate();
                    final msgText = (d['text'] ?? '').toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                          backgroundColor: barColor.withOpacity(0.15),
                          child: Icon(Icons.schedule,
                              color: barColor, size: 20)),
                      title: Text(msgText,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          ts != null ? _formatDateTime(ts) : 'অপেক্ষমাণ',
                          style: const TextStyle(fontSize: 12)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'এখনই পাঠান',
                            icon: Icon(Icons.send_rounded,
                                color: barColor, size: 20),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await ScheduledMessageService.sendScheduledDoc(
                                  doc);
                            },
                          ),
                          IconButton(
                            tooltip: 'বাতিল করুন',
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red, size: 20),
                            onPressed: () async {
                              await doc.reference.delete();
                              if (ctx.mounted && pendingDocs.length <= 1) {
                                Navigator.pop(ctx);
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleReaction(
      DocumentSnapshot doc, Map<String, dynamic> data, String emoji) async {
    try {
      final rawReactions = (data['reactions'] as Map<String, dynamic>?) ?? {};
      final currentEmoji = rawReactions[_currentUser.uid]?.toString();
      final isSame = currentEmoji == emoji;
      await doc.reference.update({
        'reactions.${_currentUser.uid}': isSame ? FieldValue.delete() : emoji,
      });
    } catch (_) {
      try {
        await doc.reference.set({
          'reactions': {_currentUser.uid: emoji},
        }, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  void _showReactionPicker(
      DocumentSnapshot doc, Map<String, dynamic> data, Color barColor) {
    HapticFeedback.mediumImpact();
    final rawReactions = (data['reactions'] as Map<String, dynamic>?) ?? {};
    final myEmoji = rawReactions[_currentUser.uid]?.toString();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1F2C34) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 12,
                      offset: Offset(0, 4))
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _reactionEmojis.map((emoji) {
                        final selected = myEmoji == emoji;
                        return GestureDetector(
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _toggleReaction(doc, data, emoji);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? barColor.withOpacity(0.22)
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                              border: selected
                                  ? Border.all(color: barColor, width: 1.5)
                                  : null,
                            ),
                            child: Text(emoji,
                                style: const TextStyle(fontSize: 26)),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  if (myEmoji != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'সিলেক্ট করা ইমোজি ($myEmoji)-তে আবার ট্যাপ করলে মুছে যাবে',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              isDark ? Colors.white60 : Colors.grey.shade600),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildReactionBadges(DocumentSnapshot doc, Map<String, dynamic> data,
      bool isMe, Color barColor) {
    final raw = data['reactions'];
    if (raw is! Map || raw.isEmpty) return const SizedBox.shrink();

    final counts = <String, int>{};
    String? myEmoji;
    raw.forEach((uid, value) {
      final emoji = value?.toString() ?? '';
      if (emoji.isEmpty) return;
      counts[emoji] = (counts[emoji] ?? 0) + 1;
      if (uid.toString() == _currentUser.uid) {
        myEmoji = emoji;
      }
    });

    if (counts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(
        left: isMe ? 0 : 8,
        right: isMe ? 8 : 0,
        bottom: 4,
      ),
      child: GestureDetector(
        onTap: () => _showReactionPicker(doc, data, barColor),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
          children: counts.entries.map((entry) {
            final isMine = myEmoji == entry.key;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: isMine ? barColor.withOpacity(0.16) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: isMine ? barColor : Colors.grey.shade300, width: 1),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black12,
                      blurRadius: 2,
                      offset: Offset(0, 1))
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(entry.key, style: const TextStyle(fontSize: 13)),
                  if (entry.value > 1) ...[
                    const SizedBox(width: 3),
                    Text(
                      '${entry.value}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isMine ? barColor : Colors.black87),
                    ),
                  ],
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _cancelUpload() {
    if (_uploadCancelToken != null && !_uploadCancelToken!.isCancelled) {
      _uploadCancelToken!.cancel('User cancelled upload');
    }
  }

  Future<T> _uploadWithRetry<T>({
    required Future<T> Function() action,
    required CancelToken cancelToken,
    int maxAttempts = 3,
  }) async {
    int attempt = 0;
    while (true) {
      if (cancelToken.isCancelled) throw _UploadCancelledException();
      attempt++;
      try {
        return await action();
      } on DioException catch (e) {
        if (CancelToken.isCancel(e) || cancelToken.isCancelled) {
          throw _UploadCancelledException();
        }
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      } catch (e) {
        if (e is _UploadCancelledException || cancelToken.isCancelled) {
          throw _UploadCancelledException();
        }
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  Future<String> _uploadFileToCloudinary({
    required File file,
    required String fileName,
    required String fileType,
    required CancelToken cancelToken,
  }) async {
    final totalBytes = await file.length();
    if (totalBytes <= 0) {
      throw Exception('খালি ফাইল আপলোড করা যাবে না।');
    }

    // ছবি, ভিডিও ও অডিও বাদে বাকি সব ফরম্যাট (PDF, ZIP, APK, DOCX ইত্যাদি) 'raw' এন্ডপয়েন্টে যাবে
    final resourceType =
        (fileType == 'image' || fileType == 'video' || fileType == 'audio')
            ? 'auto'
            : 'raw';
    final uploadUrl =
        'https://api.cloudinary.com/v1_1/$_cloudName/$resourceType/upload';

    // ৬ MB বা তার ছোট ফাইল একবারে আপলোড (অটো-রিট্রাই সহ)
    if (totalBytes <= _chunkSizeBytes) {
      return _uploadWithRetry(
        cancelToken: cancelToken,
        action: () async {
          final formData = FormData.fromMap({
            'file': await MultipartFile.fromFile(file.path, filename: fileName),
            'upload_preset': _uploadPreset,
            'folder': 'universal_messenger/$_chatId',
          });
          final response = await _sharedDio.post(
            uploadUrl,
            data: formData,
            cancelToken: cancelToken,
            onSendProgress: (sent, total) {
              if (total > 0 && mounted) {
                setState(() {
                  _uploadProgress = (sent / total).clamp(0.0, 1.0);
                });
              }
            },
          );
          final url = response.data['secure_url']?.toString() ?? '';
          if (url.isEmpty) throw Exception('ফাইল লিংক পাওয়া যায়নি।');
          return url;
        },
      );
    }

    // ৬ MB-এর বড় ফাইল হলে ৬ MB করে চাঙ্কড আপলোড (errno 103 প্রতিরোধ ও দ্রুত আপলোড)
    final uniqueUploadId =
        'um_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(999999)}';
    final raf = await file.open(mode: FileMode.read);
    try {
      int offset = 0;
      String finalUrl = '';

      while (offset < totalBytes) {
        if (cancelToken.isCancelled) throw _UploadCancelledException();

        final int currentChunkSize =
            math.min(_chunkSizeBytes, totalBytes - offset);
        await raf.setPosition(offset);
        final Uint8List chunkBytes = await raf.read(currentChunkSize);
        final int start = offset;
        final int end = offset + chunkBytes.length - 1;

        final chunkResponse = await _uploadWithRetry(
          cancelToken: cancelToken,
          action: () async {
            final formData = FormData.fromMap({
              'file': MultipartFile.fromBytes(chunkBytes, filename: fileName),
              'upload_preset': _uploadPreset,
              'folder': 'universal_messenger/$_chatId',
            });

            return await _sharedDio.post(
              uploadUrl,
              data: formData,
              cancelToken: cancelToken,
              options: Options(
                headers: {
                  'X-Unique-Upload-Id': uniqueUploadId,
                  'Content-Range': 'bytes $start-$end/$totalBytes',
                },
              ),
              onSendProgress: (sent, total) {
                if (total > 0 && mounted) {
                  final chunkFraction = (sent / total).clamp(0.0, 1.0);
                  final uploadedSoFar =
                      start + (chunkFraction * chunkBytes.length);
                  setState(() {
                    _uploadProgress =
                        (uploadedSoFar / totalBytes).clamp(0.0, 1.0);
                  });
                }
              },
            );
          },
        );

        if (chunkResponse.data is Map &&
            chunkResponse.data['secure_url'] != null) {
          finalUrl = chunkResponse.data['secure_url'].toString();
        }

        offset += chunkBytes.length;
        if (mounted) {
          setState(() {
            _uploadProgress = (offset / totalBytes).clamp(0.0, 1.0);
          });
        }
      }

      if (finalUrl.isEmpty) {
        throw Exception('ফাইল লিংক পাওয়া যায়নি।');
      }
      return finalUrl;
    } finally {
      await raf.close();
    }
  }

  Future<void> _pickAndSendFile() async {
    if (_isUploading) return;
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      final files = res?.files ?? <PlatformFile>[];
      if (files.isEmpty || files.first.path == null) return;

      final pickedFile = files.first;
      final file = File(pickedFile.path!);
      final fileName = pickedFile.name;
      final fileSize = _formatFileSize(await file.length());
      final fileType = _detectFileType(fileName);
      final replyPayload = _replyingTo;
      final cancelToken = CancelToken();

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadingFileName = fileName;
        _uploadingFileSize = fileSize;
        _uploadCancelToken = cancelToken;
        _replyingTo = null;
      });

      final downloadUrl = await _uploadFileToCloudinary(
        file: file,
        fileName: fileName,
        fileType: fileType,
        cancelToken: cancelToken,
      );

      if (cancelToken.isCancelled) throw _UploadCancelledException();

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .add({
        'senderId': _currentUser.uid,
        'receiverId': widget.receiverId,
        'text': fileName,
        'type': fileType,
        'fileUrl': downloadUrl,
        'fileName': fileName,
        'fileSize': fileSize,
        'isSeen': false,
        'isEdited': false,
        if (replyPayload != null) 'replyTo': replyPayload,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _updateChatSummary(
        fileType == 'audio' ? '🎵 $fileName' : '📎 $fileName',
        messageType: fileType,
      );

      FcmPushService.sendPushToUser(
        receiverId: widget.receiverId,
        title: _currentUser.displayName ?? _currentUser.email ?? 'নতুন মেসেজ',
        body: fileType == 'image'
            ? '📷 একটি ছবি পাঠিয়েছেন'
            : (fileType == 'audio' ? '🎵 $fileName' : '📎 $fileName'),
        chatId: _chatId,
      );
    } on _UploadCancelledException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ফাইল আপলোড বাতিল করা হয়েছে'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ফাইল আপলোড বাতিল করা হয়েছে'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ফাইল পাঠাতে সমস্যা হয়েছে: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = 0.0;
          _uploadingFileName = '';
          _uploadingFileSize = '';
          _uploadCancelToken = null;
        });
      }
    }
  }

  Future<void> _downloadMediaToPhone({
    required String url,
    required String fileName,
    required String mediaType,
  }) async {
    if (url.isEmpty) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('ডাউনলোড হচ্ছে: $fileName'),
        duration: const Duration(seconds: 2),
      ),
    );

    final safeTempName =
        'dl_${DateTime.now().millisecondsSinceEpoch}_${fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}';
    final tempFile = File('${Directory.systemTemp.path}/$safeTempName');

    try {
      await _sharedDio.download(
        url,
        tempFile.path,
        options: Options(followRedirects: true, maxRedirects: 6),
      );

      final saved = await _nativeChannel.invokeMethod<bool>('saveMediaFile', {
        'path': tempFile.path,
        'fileName': fileName,
        'mediaType': mediaType,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved == true
                ? (mediaType == 'image'
                    ? 'ছবি গ্যালারিতে সেভ হয়েছে!'
                    : (mediaType == 'video'
                        ? 'ভিডিও গ্যালারিতে সেভ হয়েছে!'
                        : 'ফাইল Downloads ফোল্ডারে সেভ হয়েছে!'))
                : 'ফাইল সেভ করা যায়নি।',
          ),
          backgroundColor:
              saved == true ? const Color(0xFF2E7D32) : Colors.red.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ডাউনলোড করতে সমস্যা হয়েছে: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  void _openInAppMediaViewer({
    required String url,
    required String fileName,
    required bool isVideo,
    required Color accentColor,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _InAppMediaViewerScreen(
          url: url,
          fileName: fileName,
          isVideo: isVideo,
          accentColor: accentColor,
          dio: _sharedDio,
        ),
      ),
    );
  }

  void _showMessageOptions(DocumentSnapshot doc, Map<String, dynamic> data,
      bool isMe, Color barColor) {
    final type = (data['type'] ?? 'text').toString();
    final text = (data['text'] ?? '').toString();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 6),
            ListTile(
              leading: Icon(Icons.reply, color: barColor),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                _selectReplyMessage(doc.id, data, isMe);
              },
            ),
            if (type == 'text' && text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.blueGrey),
                title: const Text('Copy'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: text));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('মেসেজ কপি হয়েছে'),
                      duration: Duration(seconds: 1)));
                },
              ),
            if (isMe && type == 'text')
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.orange),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditMessageDialog(doc, text, barColor);
                },
              ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title:
                    const Text('Delete', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteMessage(doc);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showEditMessageDialog(
      DocumentSnapshot doc, String oldText, Color barColor) {
    final editController = TextEditingController(text: oldText);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('মেসেজ এডিট করুন'),
        content: TextField(
          controller: editController,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textCapitalization: TextCapitalization.none,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), hintText: 'নতুন মেসেজ লিখুন...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: barColor, foregroundColor: Colors.white),
            onPressed: () async {
              final updatedText = editController.text.trim();
              if (updatedText.isNotEmpty && updatedText != oldText) {
                await doc.reference
                    .update({'text': updatedText, 'isEdited': true});
                final latestSnap = await FirebaseFirestore.instance
                    .collection('chats')
                    .doc(_chatId)
                    .collection('messages')
                    .orderBy('timestamp', descending: true)
                    .limit(1)
                    .get();
                if (latestSnap.docs.isNotEmpty &&
                    latestSnap.docs.first.id == doc.id) {
                  await FirebaseFirestore.instance
                      .collection('chats')
                      .doc(_chatId)
                      .set({'lastMessage': updatedText},
                          SetOptions(merge: true));
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('সেভ করুন'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(DocumentSnapshot doc) async {
    try {
      await doc.reference.delete();
      final latestSnap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      String newLastMsg = '';
      String newType = 'text';
      if (latestSnap.docs.isNotEmpty) {
        final d = latestSnap.docs.first.data();
        final t = (d['type'] ?? 'text').toString();
        newType = t;
        newLastMsg = (t == 'text' || t == 'call')
            ? (d['text'] ?? '').toString()
            : '📎 ${d['fileName'] ?? 'File'}';
      }

      await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'lastMessage': newLastMsg,
        'lastMessageType': newType,
      }, SetOptions(merge: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ডিলিট করতে সমস্যা হয়েছে: $e')));
    }
  }

  Future<void> _openFileUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ফাইলটি ওপেন করা যায়নি।')));
    }
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return '...';
    final dt = timestamp.toDate();
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $period';
  }

  Widget _buildMessageContent(Map<String, dynamic> data, Color accentColor) {
    final type = (data['type'] ?? 'text').toString();
    final text = (data['text'] ?? '').toString();
    final fileUrl = (data['fileUrl'] ?? '').toString();
    final fileName = (data['fileName'] ?? text).toString();
    final fileSize = (data['fileSize'] ?? '').toString();

    if (type == 'call') {
      final isVideo = data['isVideo'] == true;
      final isMissed = (data['callStatus'] ?? '') == 'missed';
      final durationSec = (data['durationSec'] as num?)?.toInt() ?? 0;
      final iconColor = isMissed ? Colors.redAccent : const Color(0xFF2E7D32);
      final titleText = isMissed
          ? (isVideo ? 'Missed video call' : 'Missed voice call')
          : (isVideo ? 'Video call' : 'Voice call');
      final subText = isMissed
          ? 'Tap to call back'
          : 'Duration: ${CallLogHelper.formatDuration(durationSec)}';

      return InkWell(
        onTap: () => _startCall(isVideo),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: iconColor.withOpacity(0.18),
                child: Icon(
                  isMissed
                      ? Icons.call_missed
                      : (isVideo ? Icons.videocam_rounded : Icons.call_rounded),
                  color: iconColor,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleText,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isMissed ? Colors.red.shade700 : Colors.black87,
                    ),
                  ),
                  Text(
                    subText,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (type == 'text' || fileUrl.isEmpty) {
      return Text(text,
          style: const TextStyle(fontSize: 15, color: Colors.black87));
    }

    if (type == 'image') {
      return GestureDetector(
        onTap: () => _openInAppMediaViewer(
          url: fileUrl,
          fileName: fileName.isNotEmpty ? fileName : 'image.jpg',
          isVideo: false,
          accentColor: accentColor,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    fileUrl,
                    width: 220,
                    height: 220,
                    cacheWidth: 480,
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        width: 220,
                        height: 220,
                        color: Colors.black12,
                        alignment: Alignment.center,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: accentColor,
                        ),
                      );
                    },
                    errorBuilder: (_, __, ___) => const SizedBox(
                      width: 220,
                      height: 140,
                      child: Center(child: Icon(Icons.broken_image, size: 40)),
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: GestureDetector(
                    onTap: () => _downloadMediaToPhone(
                      url: fileUrl,
                      fileName: fileName.isNotEmpty ? fileName : 'image.jpg',
                      mediaType: 'image',
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.download_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (fileSize.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(fileSize,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            ],
          ],
        ),
      );
    }

    if (type == 'video') {
      return GestureDetector(
        onTap: () => _openInAppMediaViewer(
          url: fileUrl,
          fileName: fileName.isNotEmpty ? fileName : 'video.mp4',
          isVideo: true,
          accentColor: accentColor,
        ),
        child: Container(
          width: 225,
          decoration: BoxDecoration(
            color: const Color(0xFF141A21),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 130,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.movie_rounded,
                        size: 56, color: Colors.white24),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 32),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: () => _downloadMediaToPhone(
                          url: fileUrl,
                          fileName:
                              fileName.isNotEmpty ? fileName : 'video.mp4',
                          mediaType: 'video',
                        ),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.download_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${fileSize.isNotEmpty ? '$fileSize • ' : ''}ট্যাপ করে প্লে করুন',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    IconData iconData = Icons.insert_drive_file;
    Color iconColor = accentColor;
    final lowerName = fileName.toLowerCase();
    if (type == 'pdf') {
      iconData = Icons.picture_as_pdf;
      iconColor = Colors.red.shade700;
    } else if (type == 'audio') {
      iconData = Icons.audiotrack_rounded;
      iconColor = Colors.deepPurple;
    } else if (lowerName.endsWith('.zip') ||
        lowerName.endsWith('.rar') ||
        lowerName.endsWith('.7z')) {
      iconData = Icons.folder_zip_rounded;
      iconColor = Colors.amber.shade800;
    } else if (lowerName.endsWith('.apk')) {
      iconData = Icons.android_rounded;
      iconColor = Colors.green.shade700;
    } else if (lowerName.endsWith('.doc') ||
        lowerName.endsWith('.docx') ||
        lowerName.endsWith('.txt')) {
      iconData = Icons.description_rounded;
      iconColor = Colors.blue.shade700;
    }

    return InkWell(
      onTap: () => _openFileUrl(fileUrl),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
                backgroundColor: iconColor.withOpacity(0.15),
                child: Icon(iconData, color: iconColor)),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Colors.black87)),
                  Text(
                      '${fileSize.isNotEmpty ? '$fileSize • ' : ''}ট্যাপ করে খুলুন',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(Icons.download_rounded, size: 22, color: iconColor),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _downloadMediaToPhone(
                url: fileUrl,
                fileName: fileName,
                mediaType: 'file',
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: AppSettingsController.chatThemeColor,
      builder: (context, chatColor, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: AppSettingsController.chatThemeImage,
          builder: (context, chatImagePath, _) {
            final isDefaultBg = chatColor.value ==
                AppSettingsController.defaultChatBgColor.value;
            final barColor = isDefaultBg
                ? AppSettingsController.appThemeColor.value
                : chatColor;
            final hasChatBgImage =
                chatImagePath != null && File(chatImagePath).existsSync();
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return Scaffold(
              appBar: AppBar(
                backgroundColor: barColor,
                foregroundColor: Colors.white,
                titleSpacing: 0,
                title: Row(
                  children: [
                    NotificationAndPresenceService.buildUserAvatarWithStatus(
                      userId: widget.receiverId,
                      dotSize: 11,
                      showOfflineTime: false,
                      avatar: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.white24,
                        child: Text(
                            widget.receiverName.isNotEmpty
                                ? widget.receiverName[0].toUpperCase()
                                : 'U',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StreamBuilder<DocumentSnapshot>(
                        stream: _receiverUserStream,
                        builder: (context, snap) {
                          final uData =
                              snap.data?.data() as Map<String, dynamic>?;
                          final activeNow =
                              NotificationAndPresenceService.isUserActive(
                                  uData);
                          final statusText =
                              NotificationAndPresenceService.formatLastSeen(
                                  uData);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.receiverName,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis),
                              Text(
                                statusText,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: activeNow
                                        ? Colors.lightGreenAccent
                                        : Colors.white70,
                                    fontWeight: activeNow
                                        ? FontWeight.w600
                                        : FontWeight.normal),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                      icon: const Icon(Icons.call),
                      onPressed: () => _startCall(false)),
                  IconButton(
                      icon: const Icon(Icons.videocam),
                      onPressed: () => _startCall(true)),
                ],
              ),
              body: Container(
                decoration: hasChatBgImage
                    ? BoxDecoration(
                        image: DecorationImage(
                            image: FileImage(File(chatImagePath)),
                            fit: BoxFit.cover))
                    : BoxDecoration(
                        color: isDark
                            ? (isDefaultBg
                                ? const Color(0xFF0B141A)
                                : chatColor.withOpacity(0.25))
                            : (isDefaultBg
                                ? const Color(0xFFECE5DD)
                                : chatColor.withOpacity(0.18)),
                      ),
                child: Column(
                  children: [
                    if (_isUploading)
                      Container(
                        color: isDark
                            ? const Color(0xFF1F2C34)
                            : Colors.teal.shade50,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'আপলোড হচ্ছে: $_uploadingFileName${_uploadingFileSize.isNotEmpty ? ' ($_uploadingFileSize)' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${(_uploadProgress * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Colors.lightGreenAccent
                                        : barColor,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: _cancelUpload,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade600,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.close,
                                            size: 14, color: Colors.white),
                                        SizedBox(width: 2),
                                        Text(
                                          'বাতিল',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value:
                                  _uploadProgress > 0 ? _uploadProgress : null,
                              color: barColor,
                              minHeight: 4,
                            ),
                          ],
                        ),
                      ),
                    if (_isLoadingMore)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: barColor)),
                      ),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: _messagesStream,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !snapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final messages = snapshot.data?.docs ?? [];
                          _lastFetchedCount = messages.length;

                          if (messages.isEmpty) {
                            return Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                    color: Colors.black45,
                                    borderRadius: BorderRadius.circular(12)),
                                child: const Text(
                                    'এখনো কোনো মেসেজ নেই।\nনিচে লিখে কথোপকথন শুরু করুন!',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white)),
                              ),
                            );
                          }

                          _markMessagesAsSeen(messages);

                          return ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            cacheExtent: 600,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 16),
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              final doc = messages[index];
                              final data = doc.data() as Map<String, dynamic>;
                              final isMe =
                                  data['senderId'] == _currentUser.uid;
                              final time =
                                  _formatTime(data['timestamp'] as Timestamp?);
                              final isSeen = data['isSeen'] == true;
                              final isEdited = data['isEdited'] == true;
                              final isCallMsg = (data['type'] ?? '') == 'call';
                              final replyData =
                                  data['replyTo'] as Map<String, dynamic>?;

                              return Dismissible(
                                key: ValueKey(doc.id),
                                direction: DismissDirection.horizontal,
                                confirmDismiss: (_) async {
                                  _selectReplyMessage(doc.id, data, isMe);
                                  return false;
                                },
                                background: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 16),
                                    child: CircleAvatar(
                                        radius: 16,
                                        backgroundColor:
                                            barColor.withOpacity(0.2),
                                        child: Icon(Icons.reply,
                                            size: 18, color: barColor)),
                                  ),
                                ),
                                secondaryBackground: Align(
                                  alignment: Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 16),
                                    child: CircleAvatar(
                                        radius: 16,
                                        backgroundColor:
                                            barColor.withOpacity(0.2),
                                        child: Icon(Icons.reply,
                                            size: 18, color: barColor)),
                                  ),
                                ),
                                child: Align(
                                  alignment: isMe
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Column(
                                    crossAxisAlignment: isMe
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        onTap: () => _showMessageOptions(
                                            doc, data, isMe, barColor),
                                        onLongPress: () => _showReactionPicker(
                                            doc, data, barColor),
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 4),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                          constraints: BoxConstraints(
                                              maxWidth: MediaQuery.of(context)
                                                      .size
                                                      .width *
                                                  0.78),
                                          decoration: BoxDecoration(
                                            color: isMe
                                                ? (isDefaultBg
                                                    ? const Color(0xFFD9FDD3)
                                                    : Color.lerp(Colors.white,
                                                        chatColor, 0.25))
                                                : Colors.white,
                                            borderRadius: BorderRadius.only(
                                              topLeft:
                                                  const Radius.circular(14),
                                              topRight:
                                                  const Radius.circular(14),
                                              bottomLeft: Radius.circular(
                                                  isMe ? 14 : 2),
                                              bottomRight: Radius.circular(
                                                  isMe ? 2 : 14),
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (replyData != null)
                                                Container(
                                                  margin: const EdgeInsets.only(
                                                      bottom: 6),
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black
                                                        .withOpacity(0.06),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    border: Border(
                                                        left: BorderSide(
                                                            color: barColor,
                                                            width: 3)),
                                                  ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                          (replyData[
                                                                      'senderName'] ??
                                                                  '')
                                                              .toString(),
                                                          style: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              color: barColor)),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                          (replyData['text'] ??
                                                                  '')
                                                              .toString(),
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                                  fontSize: 12,
                                                                  color: Colors
                                                                      .black54)),
                                                    ],
                                                  ),
                                                ),
                                              _buildMessageContent(
                                                  data, barColor),
                                              const SizedBox(height: 4),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.end,
                                                children: [
                                                  if (isEdited)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              right: 5),
                                                      child: Text('Edited',
                                                          style: TextStyle(
                                                              fontSize: 10,
                                                              fontStyle:
                                                                  FontStyle
                                                                      .italic,
                                                              color: Colors
                                                                  .grey
                                                                  .shade600)),
                                                    ),
                                                  Text(time,
                                                      style: TextStyle(
                                                          fontSize: 10,
                                                          color: Colors
                                                              .grey.shade600)),
                                                  if (isMe && !isCallMsg) ...[
                                                    const SizedBox(width: 5),
                                                    Text(
                                                      isSeen ? 'Seen' : 'Sent',
                                                      style: TextStyle(
                                                          fontSize: 10,
                                                          fontWeight: isSeen
                                                              ? FontWeight.bold
                                                              : FontWeight
                                                                  .normal,
                                                          color: isSeen
                                                              ? const Color(
                                                                  0xFF1A73E8)
                                                              : Colors.grey
                                                                  .shade600),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      _buildReactionBadges(
                                          doc, data, isMe, barColor),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    StreamBuilder<DocumentSnapshot>(
                      stream: _chatDocStream,
                      builder: (context, snapshot) {
                        final chatData =
                            snapshot.data?.data() as Map<String, dynamic>?;
                        final typingMap =
                            chatData?['typing'] as Map<String, dynamic>?;
                        if (typingMap?[widget.receiverId] != true) {
                          return const SizedBox.shrink();
                        }

                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(
                                left: 14, bottom: 6, top: 2),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(14),
                                topRight: Radius.circular(14),
                                bottomLeft: Radius.circular(2),
                                bottomRight: Radius.circular(14),
                              ),
                            ),
                            child: _AnimatedWaitIndicator(color: barColor),
                          ),
                        );
                      },
                    ),
                    StreamBuilder<QuerySnapshot>(
                      stream: _scheduledStream,
                      builder: (context, snap) {
                        final docs = (snap.data?.docs ?? []).where((d) {
                          final map = d.data() as Map<String, dynamic>?;
                          return (map?['chatId'] ?? '') == _chatId;
                        }).toList();
                        if (docs.isEmpty) return const SizedBox.shrink();
                        return GestureDetector(
                          onTap: () =>
                              _openPendingScheduledList(docs, barColor),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 7),
                            color: barColor.withOpacity(0.14),
                            child: Row(
                              children: [
                                Icon(Icons.schedule_send_rounded,
                                    size: 16, color: barColor),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${docs.length}টি শিডিউল মেসেজ অপেক্ষায় আছে (দেখতে ট্যাপ করুন)',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87),
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    size: 18, color: barColor),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    SafeArea(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        color: isDark
                            ? const Color(0xFF1F2C34)
                            : Colors.grey.shade100,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_replyingTo != null)
                              Container(
                                margin: const EdgeInsets.only(
                                    bottom: 6, left: 4, right: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF2A3942)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border(
                                      left: BorderSide(
                                          color: barColor, width: 4)),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              'Replying to ${_replyingTo!['senderName']}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: barColor)),
                                          const SizedBox(height: 2),
                                          Text(
                                              (_replyingTo!['text'] ?? '')
                                                  .toString(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  color: isDark
                                                      ? Colors.white70
                                                      : Colors.black87)),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.close, size: 18),
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () =>
                                          setState(() => _replyingTo = null),
                                    ),
                                  ],
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                IconButton(
                                    icon: Icon(Icons.attach_file,
                                        color: barColor),
                                    onPressed:
                                        _isUploading ? null : _pickAndSendFile),
                                Expanded(
                                  child: _NativeAndroidChatInput(
                                    key: const ValueKey('native_chat_input'),
                                    controller: _nativeInputController,
                                    isDark: isDark,
                                    onChanged: _onTextChanged,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onLongPress: () =>
                                      _openScheduleMessageSheet(barColor),
                                  child: CircleAvatar(
                                    backgroundColor: barColor,
                                    radius: 23,
                                    child: IconButton(
                                      icon: const Icon(Icons.send,
                                          color: Colors.white, size: 20),
                                      tooltip:
                                          'পাঠাতে ট্যাপ করুন, শিডিউল করতে হোল্ড করুন',
                                      onPressed: _sendMessage,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _InAppMediaViewerScreen extends StatefulWidget {
  final String url;
  final String fileName;
  final bool isVideo;
  final Color accentColor;
  final Dio dio;

  const _InAppMediaViewerScreen({
    required this.url,
    required this.fileName,
    required this.isVideo,
    required this.accentColor,
    required this.dio,
  });

  @override
  State<_InAppMediaViewerScreen> createState() =>
      _InAppMediaViewerScreenState();
}

class _InAppMediaViewerScreenState extends State<_InAppMediaViewerScreen> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.universal.messenger/icon');

  VideoPlayerController? _videoController;
  bool _videoReady = false;
  bool _videoError = false;
  bool _isMuted = false;

  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _videoController = ctrl;
      await ctrl.initialize();
      ctrl.addListener(_onVideoTick);
      await ctrl.play();
      if (mounted) {
        setState(() => _videoReady = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _videoError = true);
      }
    }
  }

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onVideoTick);
    _videoController?.dispose();
    super.dispose();
  }

  String _fmtDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$mins:$secs';
    }
    return '$mins:$secs';
  }

  Future<void> _downloadToGallery() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
    });

    final safeTempName =
        'viewer_${DateTime.now().millisecondsSinceEpoch}_${widget.fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}';
    final tempFile = File('${Directory.systemTemp.path}/$safeTempName');

    try {
      await widget.dio.download(
        widget.url,
        tempFile.path,
        options: Options(followRedirects: true, maxRedirects: 6),
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _downloadProgress = received / total);
          }
        },
      );

      final saved = await _nativeChannel.invokeMethod<bool>('saveMediaFile', {
        'path': tempFile.path,
        'fileName': widget.fileName,
        'mediaType': widget.isVideo ? 'video' : 'image',
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved == true
                ? (widget.isVideo
                    ? 'ভিডিও গ্যালারিতে সেভ হয়েছে!'
                    : 'ছবি গ্যালারিতে সেভ হয়েছে!')
                : 'সেভ করতে সমস্যা হয়েছে।',
          ),
          backgroundColor:
              saved == true ? const Color(0xFF2E7D32) : Colors.red.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ডাউনলোড ব্যর্থ হয়েছে: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = 0.0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = _videoController;
    final isPlaying = vc?.value.isPlaying == true;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          if (_isDownloading)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  _downloadProgress > 0
                      ? '${(_downloadProgress * 100).toStringAsFixed(0)}%'
                      : '...',
                  style: const TextStyle(
                      color: Colors.lightGreenAccent,
                      fontWeight: FontWeight.bold),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'গ্যালারিতে সেভ করুন',
              onPressed: _downloadToGallery,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isDownloading)
            LinearProgressIndicator(
              value: _downloadProgress > 0 ? _downloadProgress : null,
              color: widget.accentColor,
              minHeight: 3,
            ),
          Expanded(
            child: Center(
              child: widget.isVideo
                  ? _buildVideoBody(vc, isPlaying)
                  : InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4.0,
                      child: Image.network(
                        widget.url,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          final expected = loadingProgress.expectedTotalBytes;
                          final val = expected != null && expected > 0
                              ? loadingProgress.cumulativeBytesLoaded / expected
                              : null;
                          return CircularProgressIndicator(
                            value: val,
                            color: widget.accentColor,
                          );
                        },
                        errorBuilder: (_, __, ___) => const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image,
                                color: Colors.white54, size: 54),
                            SizedBox(height: 8),
                            Text('ছবিটি লোড করা যায়নি',
                                style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoBody(VideoPlayerController? vc, bool isPlaying) {
    if (_videoError) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 10),
          const Text('ভিডিও প্লে করা যায়নি',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: widget.accentColor,
                foregroundColor: Colors.white),
            icon: const Icon(Icons.download_rounded),
            label: const Text('ডাউনলোড করে দেখুন'),
            onPressed: _downloadToGallery,
          ),
        ],
      );
    }

    if (!_videoReady || vc == null) {
      return CircularProgressIndicator(color: widget.accentColor);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: () {
                if (vc.value.isPlaying) {
                  vc.pause();
                } else {
                  vc.play();
                }
              },
              child: AspectRatio(
                aspectRatio: vc.value.aspectRatio > 0
                    ? vc.value.aspectRatio
                    : (16 / 9),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(vc),
                    if (!isPlaying)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 42),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoProgressIndicator(
                  vc,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: widget.accentColor,
                    bufferedColor: Colors.white30,
                    backgroundColor: Colors.white12,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: () {
                        if (vc.value.isPlaying) {
                          vc.pause();
                        } else {
                          vc.play();
                        }
                      },
                    ),
                    Text(
                      '${_fmtDuration(vc.value.position)} / ${_fmtDuration(vc.value.duration)}',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        _isMuted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          _isMuted = !_isMuted;
                          vc.setVolume(_isMuted ? 0.0 : 1.0);
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AnimatedWaitIndicator extends StatefulWidget {
  final Color color;
  const _AnimatedWaitIndicator({required this.color});

  @override
  State<_AnimatedWaitIndicator> createState() => _AnimatedWaitIndicatorState();
}

class _AnimatedWaitIndicatorState extends State<_AnimatedWaitIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('wait',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: widget.color)),
            const SizedBox(width: 2),
            ...List.generate(3, (index) {
              final phase = (_controller.value * 2 * math.pi) - (index * 0.9);
              final wave = math.sin(phase);
              return Transform.translate(
                offset: Offset(0, wave > 0 ? -wave * 4.5 : 0.0),
                child: Opacity(
                  opacity: 0.35 + (0.65 * ((wave + 1) / 2)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Text('.',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            height: 0.9,
                            color: widget.color)),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
