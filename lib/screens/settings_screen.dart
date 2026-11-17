import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppSettingsController {
  static const MethodChannel _nativeChannel = MethodChannel('com.universal.messenger/icon');
  static const Color defaultPrimaryColor = Color(0xFF008069);
  static const Color defaultChatBgColor = Color(0xFFECE5DD);

  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.light);
  static final ValueNotifier<Color> appThemeColor = ValueNotifier(defaultPrimaryColor);
  static final ValueNotifier<String?> appThemeImage = ValueNotifier(null);
  static final ValueNotifier<Color> chatThemeColor = ValueNotifier(defaultChatBgColor);
  static final ValueNotifier<String?> chatThemeImage = ValueNotifier(null);

  static final ValueNotifier<bool> chatSounds = ValueNotifier(true);
  static final ValueNotifier<bool> videoCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> audioCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> vibrate = ValueNotifier(true);

  /// শুধুমাত্র ফোনের হোম স্ক্রিনের লোগো নিয়ন্ত্রণ করে ('default' | 'google' | 'aqua' | 'dark' | 'sunset' | 'custom')
  static final ValueNotifier<String> iconType = ValueNotifier('default');
  static final ValueNotifier<String?> customIconPath = ValueNotifier(null);

  static Directory get _appDir {
    final dir = Directory('/data/user/0/com.universal.messenger/files');
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  static File get _settingsFile => File('${_appDir.path}/app_settings.json');

  static Future<String> savePermanentImage(String sourcePath, String prefix) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return sourcePath;
      final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'jpg';
      final dest = File('${_appDir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return sourcePath;
    }
  }

  /// ফোনের হোম স্ক্রিনের অ্যাপ লোগো পরিবর্তন করে (অ্যাপের ভেতরের কোনো আইকন নয়)
  static Future<void> applyLauncherIcon(String type, {String? customPath}) async {
    try {
      await _nativeChannel.invokeMethod('setAppIcon', {'type': type});
      if (type == 'custom' && customPath != null) {
        await _nativeChannel.invokeMethod('pinCustomShortcut', {'path': customPath});
      }
    } catch (_) {}
  }

  /// অ্যাপের ভেতরে লোগো পরিবর্তন না করার জন্য খালি রাখা হয়েছে
  static Widget buildAppIcon({double radius = 16}) => const SizedBox.shrink();

  static Future<void> load() async {
    try {
      final file = _settingsFile;
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      themeMode.value = (data['isDark'] == true) ? ThemeMode.dark : ThemeMode.light;
      if (data['appThemeColor'] != null) appThemeColor.value = Color(data['appThemeColor']);
      appThemeImage.value = data['appThemeImage'];
      if (data['chatThemeColor'] != null) chatThemeColor.value = Color(data['chatThemeColor']);
      chatThemeImage.value = data['chatThemeImage'];
      chatSounds.value = data['chatSounds'] ?? true;
      videoCallSounds.value = data['videoCallSounds'] ?? true;
      audioCallSounds.value = data['audioCallSounds'] ?? true;
      vibrate.value = data['vibrate'] ?? true;
      iconType.value = data['iconType'] ?? 'default';
      customIconPath.value = data['customIconPath'];
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      final data = {
        'isDark': themeMode.value == ThemeMode.dark,
        'appThemeColor': appThemeColor.value.value,
        'appThemeImage': appThemeImage.value,
        'chatThemeColor': chatThemeColor.value.value,
        'chatThemeImage': chatThemeImage.value,
        'chatSounds': chatSounds.value,
        'videoCallSounds': videoCallSounds.value,
        'audioCallSounds': audioCallSounds.value,
        'vibrate': vibrate.value,
        'iconType': iconType.value,
        'customIconPath': customIconPath.value,
      };
      await _settingsFile.writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}

class NotificationAndPresenceService {
  static const MethodChannel _nativeChannel = MethodChannel('com.universal.messenger/icon');
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static String? activeChatId;
  static String? _lastNotifiedCallId;
  static bool _initialChatsLoaded = false;
  static final Map<String, int> _lastChatMsgMillis = {};

  static StreamSubscription<DocumentSnapshot>? _callSub;
  static StreamSubscription<QuerySnapshot>? _chatSub;
  static Timer? _heartbeatTimer;

  static Future<void> start() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (!_initialized) {
      _initialized = true;
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _notifications.initialize(initSettings);

      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    await setOnlineStatus(true);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) => setOnlineStatus(true));

    _listenIncomingCalls(user.uid);
    _listenIncomingMessages(user.uid);
  }

  /// মোবাইলে Wi-Fi বা Mobile Data চালু এবং ইন্টারনেট সক্রিয় আছে কি না তা যাচাই করে
  static Future<bool> isDataOrWifiActive() async {
    try {
      final nativeConnected = await _nativeChannel.invokeMethod<bool>('isNetworkConnected');
      if (nativeConnected == false) return false;
      final result = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setOnlineStatus(bool isOnline) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final connected = await isDataOrWifiActive();
      if (isOnline && !connected) return;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> setOfflineAndStop() async {
    await setOnlineStatus(false);
    _heartbeatTimer?.cancel();
    await _callSub?.cancel();
    await _chatSub?.cancel();
    _callSub = null;
    _chatSub = null;
    _initialChatsLoaded = false;
    _lastChatMsgMillis.clear();
  }

  /// শুধুমাত্র ডাটা/ওয়াইফাই চালু রেখে অ্যাপে সক্রিয় থাকলে Active দেখাবে (২৫ সেকেন্ডের মধ্যে হার্টবিট থাকলে)
  static bool isUserActive(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (data['isOnline'] != true) return false;
    final lastSeen = data['lastSeen'];
    if (lastSeen is! Timestamp) return false;
    final diffSeconds = DateTime.now().difference(lastSeen.toDate()).inSeconds;
    return diffSeconds >= -20 && diffSeconds <= 25;
  }

  /// অ্যাপ থেকে কত সময় আগে বের হয়েছেন তা দেখায় (যেমন: Active 5m ago, Active 2h ago)
  static String formatLastSeen(Map<String, dynamic>? data) {
    if (isUserActive(data)) return 'Active now';
    if (data == null || data['lastSeen'] is! Timestamp) return 'Offline';
    final lastSeen = (data['lastSeen'] as Timestamp).toDate();
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return 'Active 1m ago';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
    if (diff.inDays < 30) return 'Active ${diff.inDays}d ago';
    return 'Offline';
  }

  /// প্রোফাইল ছবির পাশে সংক্ষিপ্ত সময় (যেমন: 5m, 2h, 1d) দেখায়
  static String formatLastSeenShort(Map<String, dynamic>? data) {
    if (isUserActive(data) || data == null || data['lastSeen'] is! Timestamp) return '';
    final lastSeen = (data['lastSeen'] as Timestamp).toDate();
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return '1m';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 30) return '${diff.inDays}d';
    return '';
  }

  static void _listenIncomingCalls(String uid) {
    _callSub?.cancel();
    _callSub = FirebaseFirestore.instance.collection('calls').doc(uid).snapshots().listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null || data['status'] != 'ringing') return;

      final callId = (data['callId'] ?? '').toString();
      if (callId.isEmpty || callId == _lastNotifiedCallId) return;
      _lastNotifiedCallId = callId;

      final callerName = (data['callerName'] ?? 'কেউ একজন').toString();
      final isVideo = data['isVideo'] == true;
      final playSound = isVideo
          ? AppSettingsController.videoCallSounds.value
          : AppSettingsController.audioCallSounds.value;

      final androidDetails = AndroidNotificationDetails(
        'incoming_calls_high_v1',
        'Incoming Calls',
        channelDescription: 'Heads-up pop-up notifications for incoming calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        playSound: playSound,
        enableVibration: AppSettingsController.vibrate.value,
        visibility: NotificationVisibility.public,
      );

      await _notifications.show(
        callId.hashCode,
        isVideo ? 'ইনকামিং ভিডিও কল' : 'ইনকামিং অডিও কল',
        '$callerName আপনাকে কল দিচ্ছেন...',
        NotificationDetails(android: androidDetails),
      );
    });
  }

  static void _listenIncomingMessages(String uid) {
    _chatSub?.cancel();
    _initialChatsLoaded = false;
    _lastChatMsgMillis.clear();

    _chatSub = FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .listen((snap) async {
      if (!_initialChatsLoaded) {
        for (final doc in snap.docs) {
          final ts = doc.data()['lastMessageTime'] as Timestamp?;
          if (ts != null) _lastChatMsgMillis[doc.id] = ts.millisecondsSinceEpoch;
        }
        _initialChatsLoaded = true;
        return;
      }

      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.modified && change.type != DocumentChangeType.added) {
          continue;
        }
        final doc = change.doc;
        final data = doc.data();
        if (data == null) continue;

        final ts = data['lastMessageTime'] as Timestamp?;
        final millis = ts?.millisecondsSinceEpoch ?? 0;
        final prevMillis = _lastChatMsgMillis[doc.id] ?? 0;
        if (millis <= prevMillis) continue;
        _lastChatMsgMillis[doc.id] = millis;

        if (activeChatId == doc.id) continue;

        final lastSenderId = (data['lastSenderId'] ?? '').toString();
        if (lastSenderId == uid) continue;

        final unreadMap = (data['unreadCount'] as Map<String, dynamic>?) ?? {};
        final unread = (unreadMap[uid] as num?)?.toInt() ?? 0;
        if (unread <= 0) continue;

        final participants = List<String>.from(data['participants'] ?? []);
        final otherId = participants.firstWhere((id) => id != uid, orElse: () => '');
        final usersMap = (data['users'] as Map<String, dynamic>?) ?? {};
        final senderInfo = (usersMap[otherId] as Map<String, dynamic>?) ?? {};
        final senderName = (senderInfo['name'] ?? 'নতুন মেসেজ').toString();
        final lastMsg = (data['lastMessage'] ?? 'নতুন মেসেজ এসেছে').toString();

        final androidDetails = AndroidNotificationDetails(
          'chat_messages_high_v1',
          'Chat Messages',
          channelDescription: 'Heads-up pop-up notifications for new messages',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          playSound: AppSettingsController.chatSounds.value,
          enableVibration: AppSettingsController.vibrate.value,
          visibility: NotificationVisibility.public,
        );

        await _notifications.show(
          doc.id.hashCode,
          senderName,
          lastMsg,
          NotificationDetails(android: androidDetails),
        );
      }
    });
  }

  static Widget buildUserAvatarWithStatus({
    required String userId,
    required Widget avatar,
    double dotSize = 13,
    bool showOfflineTime = true,
  }) {
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 8), (i) => i),
      builder: (context, _) {
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() as Map<String, dynamic>?;
            final isActive = isUserActive(data);
            final shortAgo = showOfflineTime ? formatLastSeenShort(data) : '';

            return Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                if (isActive)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        color: const Color(0xFF31A24C),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2,
                        ),
                      ),
                    ),
                  )
                else if (shortAgo.isNotEmpty)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        shortAgo,
                        style: const TextStyle(
                          color: Color(0xFF8BE9A1),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onLoggedOut;
  const SettingsScreen({super.key, this.onLoggedOut});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final User? _user = FirebaseAuth.instance.currentUser;
  String _displayName = '';
  String? _photoUrl;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _displayName = _user?.displayName ?? 'User';
    _photoUrl = _user?.photoURL;
    _loadUserFromFirestore();
  }

  Future<void> _loadUserFromFirestore() async {
    if (_user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(_user!.uid).get();
      if (doc.exists && mounted) {
        final d = doc.data()!;
        setState(() {
          _displayName = (d['name'] ?? d['username'] ?? _displayName).toString();
          _photoUrl = (d['photoUrl'] ?? d['profilePic'] ?? _photoUrl)?.toString();
        });
      }
    } catch (_) {}
  }

  void _showMsg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _changeNameDialog() async {
    final ctrl = TextEditingController(text: _displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Name'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Enter new name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || _user == null) return;

    setState(() => _isBusy = true);
    try {
      await _user!.updateDisplayName(newName);
      await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({'name': newName}, SetOptions(merge: true));
      setState(() => _displayName = newName);
      _showMsg('Name updated successfully');
    } catch (e) {
      _showMsg('Failed to update name: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _changeProfilePhoto() async {
    if (_user == null) return;
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return;

    setState(() => _isBusy = true);
    try {
      final file = files.first;
      String photoValue = file.path ?? '';
      if (file.path != null) {
        final bytes = await File(file.path!).readAsBytes();
        if (bytes.length <= 500 * 1024) {
          photoValue = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        } else {
          photoValue = await AppSettingsController.savePermanentImage(file.path!, 'profile');
        }
      }
      await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({'photoUrl': photoValue}, SetOptions(merge: true));
      setState(() => _photoUrl = photoValue);
      _showMsg('Profile photo updated');
    } catch (e) {
      _showMsg('Photo update failed: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _changePasswordDialog() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: oldCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Current Password', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: newCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'New Password (min 6 chars)', border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
        ],
      ),
    );
    if (ok != true || _user == null) return;
    if (newCtrl.text.trim().length < 6) {
      _showMsg('New password must be at least 6 characters');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final email = _user!.email;
      if (email != null && oldCtrl.text.isNotEmpty) {
        final cred = EmailAuthProvider.credential(email: email, password: oldCtrl.text.trim());
        await _user!.reauthenticateWithCredential(cred);
      }
      await _user!.updatePassword(newCtrl.text.trim());
      _showMsg('Password changed successfully');
    } catch (e) {
      _showMsg('Error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await NotificationAndPresenceService.setOfflineAndStop();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    if (widget.onLoggedOut != null) {
      widget.onLoggedOut!();
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _openThemePicker({required bool isChatTheme}) async {
    final colors = isChatTheme
        ? [
            const Color(0xFFECE5DD),
            const Color(0xFF008069),
            const Color(0xFF1A73E8),
            const Color(0xFF6A1B9A),
            const Color(0xFFE53935),
            const Color(0xFF2E7D32),
            const Color(0xFF263238),
            const Color(0xFFFFF3E0),
          ]
        : [
            const Color(0xFF008069),
            const Color(0xFF1A73E8),
            const Color(0xFF00897B),
            const Color(0xFF6A1B9A),
            const Color(0xFFE53935),
            const Color(0xFF2E7D32),
            const Color(0xFF263238),
            const Color(0xFFEF6C00),
          ];

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isChatTheme ? 'Chat Theme' : 'App Theme', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors.map((c) {
                return GestureDetector(
                  onTap: () async {
                    if (isChatTheme) {
                      AppSettingsController.chatThemeColor.value = c;
                      AppSettingsController.chatThemeImage.value = null;
                    } else {
                      AppSettingsController.appThemeColor.value = c;
                      AppSettingsController.appThemeImage.value = null;
                    }
                    await AppSettingsController.save();
                    if (mounted) setState(() {});
                    if (ctx.mounted) Navigator.pop(ctx);
                    _showMsg(isChatTheme ? 'Chat theme updated' : 'App theme updated');
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.grey.shade400, width: 1.5)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.image),
                label: const Text('Choose Image from Gallery'),
                onPressed: () async {
                  final files = await FilePicker.pickFiles(type: FileType.image);
                  if (files.isNotEmpty && files.single.path != null) {
                    final savedPath = await AppSettingsController.savePermanentImage(
                      files.single.path!,
                      isChatTheme ? 'chat_theme' : 'app_theme',
                    );
                    if (isChatTheme) {
                      AppSettingsController.chatThemeImage.value = savedPath;
                    } else {
                      AppSettingsController.appThemeImage.value = savedPath;
                    }
                    await AppSettingsController.save();
                    if (mounted) setState(() {});
                    if (ctx.mounted) Navigator.pop(ctx);
                    _showMsg('Theme image applied');
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reset to Default'),
                onPressed: () async {
                  if (isChatTheme) {
                    AppSettingsController.chatThemeColor.value = AppSettingsController.defaultChatBgColor;
                    AppSettingsController.chatThemeImage.value = null;
                  } else {
                    AppSettingsController.appThemeColor.value = AppSettingsController.defaultPrimaryColor;
                    AppSettingsController.appThemeImage.value = null;
                  }
                  await AppSettingsController.save();
                  if (mounted) setState(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                  _showMsg('Reset to default theme');
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectPresetIcon(String type, String label) async {
    AppSettingsController.iconType.value = type;
    await AppSettingsController.save();
    await AppSettingsController.applyLauncherIcon(type);
    if (mounted) setState(() {});
    _showMsg('ফোনের হোম স্ক্রিনে $label লোগো সেট করা হয়েছে');
  }

  Future<void> _pickCustomPhotoIcon() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isNotEmpty && files.single.path != null) {
      final savedPath = await AppSettingsController.savePermanentImage(files.single.path!, 'custom_icon');
      AppSettingsController.iconType.value = 'custom';
      AppSettingsController.customIconPath.value = savedPath;
      await AppSettingsController.save();
      await AppSettingsController.applyLauncherIcon('custom', customPath: savedPath);
      if (mounted) setState(() {});
      _showMsg('হোম স্ক্রিনে কাস্টম ছবির লোগো যোগ করার পপ-আপ পাঠানো হয়েছে');
    }
  }

  Widget _buildAppIconTile({
    required String type,
    required String label,
    required String currentType,
    required Widget preview,
    required VoidCallback onTap,
  }) {
    final selected = currentType == type;
    const activeBorder = Color(0xFF42A5F5);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 74,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 62,
              height: 62,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? activeBorder : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: preview,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                color: selected ? activeBorder : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  ImageProvider? _buildAvatarProvider(String? src) {
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('data:image')) return MemoryImage(base64Decode(src.split(',').last));
    if (src.startsWith('http')) return NetworkImage(src);
    final f = File(src);
    if (f.existsSync()) return FileImage(f);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: AppSettingsController.appThemeColor,
      builder: (context, themeColor, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings'), backgroundColor: themeColor, foregroundColor: Colors.white),
          body: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      leading: CircleAvatar(
                        backgroundImage: _buildAvatarProvider(_photoUrl),
                        child: _photoUrl == null ? const Icon(Icons.person) : null,
                      ),
                      title: const Text('Account Info', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(_displayName),
                      children: [
                        ListTile(leading: const Icon(Icons.edit), title: const Text('Change name'), onTap: _changeNameDialog),
                        ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Change photo'), onTap: _changeProfilePhoto),
                        ListTile(leading: const Icon(Icons.lock_reset), title: const Text('Change password'), onTap: _changePasswordDialog),
                        ListTile(leading: const Icon(Icons.logout, color: Colors.red), title: const Text('Log out', style: TextStyle(color: Colors.red)), onTap: _logout),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.color_lens),
                      title: const Text('Change Theme', style: TextStyle(fontWeight: FontWeight.bold)),
                      children: [
                        ListTile(
                          leading: const Icon(Icons.chat_bubble_outline),
                          title: const Text('Chat Theme'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ValueListenableBuilder<Color>(
                                valueListenable: AppSettingsController.chatThemeColor,
                                builder: (_, c, __) => CircleAvatar(radius: 10, backgroundColor: c),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () => _openThemePicker(isChatTheme: true),
                        ),
                        ListTile(
                          leading: const Icon(Icons.wallpaper),
                          title: const Text('App Theme'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(radius: 10, backgroundColor: themeColor),
                              const SizedBox(width: 6),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () => _openThemePicker(isChatTheme: false),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: ValueListenableBuilder<ThemeMode>(
                      valueListenable: AppSettingsController.themeMode,
                      builder: (context, mode, _) {
                        final isDark = mode == ThemeMode.dark;
                        return ListTile(
                          leading: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                          title: const Text('Day or Dark Mode', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(isDark ? 'Dark Mode Active' : 'Day Mode Active'),
                          trailing: Switch(
                            value: isDark,
                            onChanged: (val) {
                              AppSettingsController.themeMode.value = val ? ThemeMode.dark : ThemeMode.light;
                              AppSettingsController.save();
                            },
                          ),
                          onTap: () {
                            AppSettingsController.themeMode.value = isDark ? ThemeMode.light : ThemeMode.dark;
                            AppSettingsController.save();
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.notifications_active),
                      title: const Text('Notification', style: TextStyle(fontWeight: FontWeight.bold)),
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: AppSettingsController.chatSounds,
                          builder: (_, val, __) => SwitchListTile(
                            secondary: const Icon(Icons.message),
                            title: const Text('Chat sounds'),
                            value: val,
                            onChanged: (v) {
                              AppSettingsController.chatSounds.value = v;
                              if (v) SystemSound.play(SystemSoundType.click);
                              AppSettingsController.save();
                            },
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: AppSettingsController.videoCallSounds,
                          builder: (_, val, __) => SwitchListTile(
                            secondary: const Icon(Icons.videocam),
                            title: const Text('Video call sounds'),
                            value: val,
                            onChanged: (v) {
                              AppSettingsController.videoCallSounds.value = v;
                              if (v) SystemSound.play(SystemSoundType.click);
                              AppSettingsController.save();
                            },
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: AppSettingsController.audioCallSounds,
                          builder: (_, val, __) => SwitchListTile(
                            secondary: const Icon(Icons.call),
                            title: const Text('Audio call sounds'),
                            value: val,
                            onChanged: (v) {
                              AppSettingsController.audioCallSounds.value = v;
                              if (v) SystemSound.play(SystemSoundType.click);
                              AppSettingsController.save();
                            },
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: AppSettingsController.vibrate,
                          builder: (_, val, __) => SwitchListTile(
                            secondary: const Icon(Icons.vibration),
                            title: const Text('Vibrate'),
                            value: val,
                            onChanged: (v) {
                              AppSettingsController.vibrate.value = v;
                              if (v) HapticFeedback.vibrate();
                              AppSettingsController.save();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ফোনের হোম স্ক্রিনের লোগো পরিবর্তনের কার্ড
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'App Icon',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF42A5F5),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'ফোনের হোম স্ক্রিনের অ্যাপ লোগো পরিবর্তন করুন',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                          ),
                          const SizedBox(height: 14),
                          ValueListenableBuilder<String>(
                            valueListenable: AppSettingsController.iconType,
                            builder: (_, currentType, __) {
                              final customImg = _buildAvatarProvider(AppSettingsController.customIconPath.value);
                              return SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _buildAppIconTile(
                                      type: 'default',
                                      label: 'Default',
                                      currentType: currentType,
                                      preview: Container(
                                        color: const Color(0xFF008069),
                                        child: const Icon(Icons.forum_rounded, color: Colors.white, size: 30),
                                      ),
                                      onTap: () => _selectPresetIcon('default', 'Default'),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildAppIconTile(
                                      type: 'google',
                                      label: 'Google',
                                      currentType: currentType,
                                      preview: Container(
                                        color: Colors.white,
                                        alignment: Alignment.center,
                                        child: const Text(
                                          'G',
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 28, color: Color(0xFF4285F4)),
                                        ),
                                      ),
                                      onTap: () => _selectPresetIcon('google', 'Google'),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildAppIconTile(
                                      type: 'aqua',
                                      label: 'Aqua',
                                      currentType: currentType,
                                      preview: Container(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [Color(0xFF1DA1F2), Color(0xFF00C896)],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                        ),
                                        child: const Icon(Icons.send_rounded, color: Colors.white, size: 28),
                                      ),
                                      onTap: () => _selectPresetIcon('aqua', 'Aqua'),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildAppIconTile(
                                      type: 'dark',
                                      label: 'Dark',
                                      currentType: currentType,
                                      preview: Container(
                                        color: const Color(0xFF141A21),
                                        child: const Icon(Icons.forum_rounded, color: Color(0xFF00E676), size: 30),
                                      ),
                                      onTap: () => _selectPresetIcon('dark', 'Dark'),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildAppIconTile(
                                      type: 'sunset',
                                      label: 'Sunset',
                                      currentType: currentType,
                                      preview: Container(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [Color(0xFFF4511E), Color(0xFF8E24AA)],
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                          ),
                                        ),
                                        child: const Icon(Icons.star_rounded, color: Colors.white, size: 32),
                                      ),
                                      onTap: () => _selectPresetIcon('sunset', 'Sunset'),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildAppIconTile(
                                      type: 'custom',
                                      label: 'Custom',
                                      currentType: currentType,
                                      preview: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade800,
                                          image: customImg != null ? DecorationImage(image: customImg, fit: BoxFit.cover) : null,
                                        ),
                                        child: customImg == null
                                            ? const Icon(Icons.add_a_photo, color: Colors.white, size: 26)
                                            : null,
                                      ),
                                      onTap: _pickCustomPhotoIcon,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (_isBusy)
                Container(color: Colors.black38, child: const Center(child: CircularProgressIndicator())),
            ],
          ),
        );
      },
    );
  }
}
