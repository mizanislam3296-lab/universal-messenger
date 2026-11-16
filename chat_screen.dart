import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:universal_messenger/screens/call_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

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

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  late final String _chatId;
  late final User _currentUser;

  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadingFileName = '';
  bool _isTyping = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser!;
    final ids = [_currentUser.uid, widget.receiverId]..sort();
    _chatId = '${ids[0]}_${ids[1]}';
    NotificationAndPresenceService.activeChatId = _chatId;
    _markAsRead();
  }

  @override
  void dispose() {
    if (NotificationAndPresenceService.activeChatId == _chatId) {
      NotificationAndPresenceService.activeChatId = null;
    }
    _typingTimer?.cancel();
    if (_isTyping) {
      FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'typing': {_currentUser.uid: false},
      }, SetOptions(merge: true));
    }
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markAsRead() async {
    try {
      await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
        'unreadCount': {_currentUser.uid: 0},
      }, SetOptions(merge: true));
    } catch (_) {}
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
      _setTypingStatus(true);
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 3), () => _setTypingStatus(false));
    } else {
      _typingTimer?.cancel();
      _setTypingStatus(false);
    }
  }

  Future<void> _startCall(bool isVideo) async {
    final callId = '${_chatId}_${DateTime.now().millisecondsSinceEpoch}';
    final callerName = _currentUser.displayName ?? _currentUser.email ?? 'User';

    await FirebaseFirestore.instance.collection('calls').doc(widget.receiverId).set({
      'callId': callId,
      'callerId': _currentUser.uid,
      'callerName': callerName,
      'receiverId': widget.receiverId,
      'isVideo': isVideo,
      'status': 'ringing',
      'timestamp': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callID: callId,
          isVideoCall: isVideo,
          receiverIdForCleanup: widget.receiverId,
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _detectFileType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.gif') || lower.endsWith('.webp')) return 'image';
    if (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov') || lower.endsWith('.avi')) return 'video';
    if (lower.endsWith('.pdf')) return 'pdf';
    return 'file';
  }

  Future<void> _updateChatSummary(String lastMessageText) async {
    await FirebaseFirestore.instance.collection('chats').doc(_chatId).set({
      'chatId': _chatId,
      'participants': [_currentUser.uid, widget.receiverId],
      'lastMessage': lastMessageText,
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

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    _typingTimer?.cancel();
    _isTyping = false;

    await FirebaseFirestore.instance.collection('chats').doc(_chatId).collection('messages').add({
      'senderId': _currentUser.uid,
      'receiverId': widget.receiverId,
      'text': text,
      'type': 'text',
      'timestamp': FieldValue.serverTimestamp(),
    });
    await _updateChatSummary(text);
  }

  Future<void> _pickAndSendFile() async {
    if (_isUploading) return;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty || files.first.path == null) return;

      final pickedFile = files.first;
      final file = File(pickedFile.path!);
      final fileName = pickedFile.name;
      final fileSize = _formatFileSize(await file.length());
      final fileType = _detectFileType(fileName);

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadingFileName = fileName;
      });

      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: fileName),
        'upload_preset': _uploadPreset,
        'folder': 'universal_messenger/$_chatId',
      });

      final response = await Dio().post(
        'https://api.cloudinary.com/v1_1/$_cloudName/auto/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0 && mounted) setState(() => _uploadProgress = sent / total);
        },
      );

      final downloadUrl = response.data['secure_url']?.toString() ?? '';
      if (downloadUrl.isEmpty) throw Exception('ফাইল লিংক পাওয়া যায়নি।');

      await FirebaseFirestore.instance.collection('chats').doc(_chatId).collection('messages').add({
        'senderId': _currentUser.uid,
        'receiverId': widget.receiverId,
        'text': fileName,
        'type': fileType,
        'fileUrl': downloadUrl,
        'fileName': fileName,
        'fileSize': fileSize,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _updateChatSummary('📎 $fileName');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ফাইল পাঠাতে সমস্যা হয়েছে: $e'), backgroundColor: Colors.red.shade700),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = 0.0;
          _uploadingFileName = '';
        });
      }
    }
  }

  Future<void> _openFileUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ফাইলটি ওপেন করা যায়নি।')));
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

    if (type == 'text' || fileUrl.isEmpty) {
      return Text(text, style: const TextStyle(fontSize: 15, color: Colors.black87));
    }

    if (type == 'image') {
      return GestureDetector(
        onTap: () => _openFileUrl(fileUrl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                fileUrl,
                width: 220,
                height: 220,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.broken_image, size: 40)),
              ),
            ),
            if (fileSize.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(fileSize, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
            ],
          ],
        ),
      );
    }

    IconData iconData = Icons.insert_drive_file;
    Color iconColor = accentColor;
    if (type == 'pdf') {
      iconData = Icons.picture_as_pdf;
      iconColor = Colors.red.shade700;
    } else if (type == 'video') {
      iconData = Icons.video_file;
      iconColor = Colors.deepPurple;
    }

    return InkWell(
      onTap: () => _openFileUrl(fileUrl),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.05), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(backgroundColor: iconColor.withOpacity(0.15), child: Icon(iconData, color: iconColor)),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black87)),
                  Text('${fileSize.isNotEmpty ? '$fileSize • ' : ''}ট্যাপ করে খুলুন', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.download_rounded, size: 20, color: iconColor),
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
            final isDefaultBg = chatColor.value == AppSettingsController.defaultChatBgColor.value;
            final barColor = isDefaultBg ? AppSettingsController.appThemeColor.value : chatColor;
            final hasChatBgImage = chatImagePath != null && File(chatImagePath).existsSync();
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
                      avatar: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.white24,
                        child: Text(widget.receiverName.isNotEmpty ? widget.receiverName[0].toUpperCase() : 'U', style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StreamBuilder<DocumentSnapshot>(
                        stream: FirebaseFirestore.instance.collection('users').doc(widget.receiverId).snapshots(),
                        builder: (context, snap) {
                          final uData = snap.data?.data() as Map<String, dynamic>?;
                          final isOnline = uData?['isOnline'] == true;
                          final lastSeen = uData?['lastSeen'] as Timestamp?;
                          final activeNow = isOnline && (lastSeen == null || DateTime.now().difference(lastSeen.toDate()).inSeconds < 90);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.receiverName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                              Text(
                                activeNow ? 'Active now' : widget.receiverEmail,
                                style: TextStyle(fontSize: 11, color: activeNow ? Colors.lightGreenAccent : Colors.white70, fontWeight: activeNow ? FontWeight.w600 : FontWeight.normal),
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
                  IconButton(icon: const Icon(Icons.call), onPressed: () => _startCall(false)),
                  IconButton(icon: const Icon(Icons.videocam), onPressed: () => _startCall(true)),
                ],
              ),
              body: Container(
                decoration: hasChatBgImage
                    ? BoxDecoration(image: DecorationImage(image: FileImage(File(chatImagePath)), fit: BoxFit.cover))
                    : BoxDecoration(
                        color: isDark
                            ? (isDefaultBg ? const Color(0xFF0B141A) : chatColor.withOpacity(0.25))
                            : (isDefaultBg ? const Color(0xFFECE5DD) : chatColor.withOpacity(0.18)),
                      ),
                child: Column(
                  children: [
                    if (_isUploading)
                      Container(
                        color: Colors.teal.shade50,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(child: Text('আপলোড হচ্ছে: $_uploadingFileName', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87))),
                                Text('${(_uploadProgress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: barColor)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: _uploadProgress > 0 ? _uploadProgress : null, color: barColor),
                          ],
                        ),
                      ),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance.collection('chats').doc(_chatId).collection('messages').orderBy('timestamp', descending: true).snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                            return Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
                                child: const Text('এখনো কোনো মেসেজ নেই।\nনিচে লিখে কথোপকথন শুরু করুন!', textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
                              ),
                            );
                          }

                          _markAsRead();
                          final messages = snapshot.data!.docs;

                          return ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              final data = messages[index].data() as Map<String, dynamic>;
                              final isMe = data['senderId'] == _currentUser.uid;
                              final time = _formatTime(data['timestamp'] as Timestamp?);

                              return Align(
                                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                                  decoration: BoxDecoration(
                                    color: isMe ? (isDefaultBg ? const Color(0xFFD9FDD3) : Color.lerp(Colors.white, chatColor, 0.25)) : Colors.white,
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(14),
                                      topRight: const Radius.circular(14),
                                      bottomLeft: Radius.circular(isMe ? 14 : 2),
                                      bottomRight: Radius.circular(isMe ? 2 : 14),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      _buildMessageContent(data, barColor),
                                      const SizedBox(height: 4),
                                      Text(time, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
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
                      stream: FirebaseFirestore.instance.collection('chats').doc(_chatId).snapshots(),
                      builder: (context, snapshot) {
                        final chatData = snapshot.data?.data() as Map<String, dynamic>?;
                        final typingMap = chatData?['typing'] as Map<String, dynamic>?;
                        if (typingMap?[widget.receiverId] != true) return const SizedBox.shrink();

                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(left: 14, bottom: 6, top: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    SafeArea(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        color: isDark ? const Color(0xFF1F2C34) : Colors.grey.shade100,
                        child: Row(
                          children: [
                            IconButton(icon: Icon(Icons.attach_file, color: barColor), onPressed: _isUploading ? null : _pickAndSendFile),
                            Expanded(
                              child: TextField(
                                controller: _messageController,
                                onChanged: _onTextChanged,
                                textCapitalization: TextCapitalization.sentences,
                                minLines: 1,
                                maxLines: 4,
                                style: const TextStyle(color: Colors.black87),
                                decoration: InputDecoration(
                                  hintText: 'মেসেজ লিখুন...',
                                  hintStyle: TextStyle(color: Colors.grey.shade600),
                                  filled: true,
                                  fillColor: Colors.white,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            CircleAvatar(
                              backgroundColor: barColor,
                              radius: 23,
                              child: IconButton(icon: const Icon(Icons.send, color: Colors.white, size: 20), onPressed: _sendMessage),
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

class _AnimatedWaitIndicator extends StatefulWidget {
  final Color color;
  const _AnimatedWaitIndicator({required this.color});

  @override
  State<_AnimatedWaitIndicator> createState() => _AnimatedWaitIndicatorState();
}

class _AnimatedWaitIndicatorState extends State<_AnimatedWaitIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
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
            Text('wait', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: widget.color)),
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
                    child: Text('.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, height: 0.9, color: widget.color)),
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
