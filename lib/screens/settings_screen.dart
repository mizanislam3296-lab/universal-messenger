import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:googleapis_auth/auth_io.dart';

class FcmPushService {
  static const String _fcmSaB64 = String.fromEnvironment('FCM_SA_B64');
  static String? _cachedAccessToken;
  static DateTime? _tokenExpiry;
  static String? _projectId;

  static bool get isConfigured => _fcmSaB64.trim().isNotEmpty;

  static Future<String?> _getAccessToken() async {
    if (!isConfigured) return null;
    if (_cachedAccessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(minutes: 5)))) {
      return _cachedAccessToken;
    }

    try {
      final jsonStr = utf8.decode(base64Decode(_fcmSaB64.trim()));
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      _projectId = jsonMap['project_id']?.toString();
      if (_projectId == null || _projectId!.isEmpty) return null;

      final credentials = ServiceAccountCredentials.fromJson(jsonMap);
      final client = await clientViaServiceAccount(
        credentials,
        ['https://www.googleapis.com/auth/firebase.messaging'],
      );
      _cachedAccessToken = client.credentials.accessToken.data;
      _tokenExpiry = client.credentials.accessToken.expiry;
      client.close();
      return _cachedAccessToken;
    } catch (_) {
      return null;
    }
  }

  static Future<void> syncDeviceTokenAndPrefs() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final messaging = FirebaseMessaging.instance;
      if (!AppSettingsController.notificationsEnabled.value) {
        await messaging.deleteToken();
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': FieldValue.delete(),
          'notifPrefs': {
            'enabled': false,
            'headsUpPopup': AppSettingsController.headsUpPopup.value,
            'statusBar': AppSettingsController.statusBarNotification.value,
            'chatSounds': AppSettingsController.chatSounds.value,
            'videoCallSounds': AppSettingsController.videoCallSounds.value,
            'audioCallSounds': AppSettingsController.audioCallSounds.value,
            'vibrate': AppSettingsController.vibrate.value,
          },
        }, SetOptions(merge: true));
        return;
      }

      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        if (token != null && token.isNotEmpty) 'fcmToken': token,
        'notifPrefs': {
          'enabled': true,
          'headsUpPopup': AppSettingsController.headsUpPopup.value,
          'statusBar': AppSettingsController.statusBarNotification.value,
          'chatSounds': AppSettingsController.chatSounds.value,
          'videoCallSounds': AppSettingsController.videoCallSounds.value,
          'audioCallSounds': AppSettingsController.audioCallSounds.value,
          'vibrate': AppSettingsController.vibrate.value,
        },
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> sendPushToUser({
    required String receiverId,
    required String title,
    required String body,
    bool isCall = false,
    bool isVideo = false,
    String? chatId,
    String? callId,
  }) async {
    if (!isConfigured) return;
    try {
      final accessToken = await _getAccessToken();
      if (accessToken == null || _projectId == null) return;

      final userDoc = await FirebaseFirestore.instance.collection('users').doc(receiverId).get();
      final data = userDoc.data();
      if (data == null) return;

      final targetToken = (data['fcmToken'] ?? '').toString().trim();
      if (targetToken.isEmpty) return;

      final prefs = (data['notifPrefs'] as Map<String, dynamic>?) ?? {};
      if (prefs['enabled'] == false) return;

      final showPopup = prefs['headsUpPopup'] != false;
      final showStatusBar = prefs['statusBar'] != false;

      // পপ-আপ এবং স্ট্যাটাস বার দুটোই বন্ধ থাকলে উপরে কোনো পুশ নোটিফিকেশন যাবে না
      if (!isCall && !showPopup && !showStatusBar) return;

      final playSound = isCall
          ? (isVideo ? prefs['videoCallSounds'] != false : prefs['audioCallSounds'] != false)
          : (prefs['chatSounds'] != false);
      final shouldVibrate = prefs['vibrate'] != false;

      String channelId;
      if (isCall) {
        channelId = playSound ? 'fcm_call_sound_v1' : 'fcm_call_silent_v1';
      } else if (showPopup && playSound) {
        channelId = 'fcm_heads_up_sound_v1';
      } else if (showPopup && !playSound) {
        channelId = 'fcm_heads_up_silent_v1';
      } else if (!showPopup && playSound) {
        channelId = 'fcm_normal_sound_v1';
      } else {
        channelId = 'fcm_normal_silent_v1';
      }

      await Dio().post(
        'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'message': {
            'token': targetToken,
            'notification': {
              'title': title,
              'body': body,
            },
            'android': {
              'priority': 'HIGH',
              'notification': {
                'channel_id': channelId,
                if (playSound) 'sound': 'default',
                'default_sound': playSound,
                'default_vibrate_timings': shouldVibrate,
                'notification_priority': showPopup ? 'PRIORITY_MAX' : 'PRIORITY_DEFAULT',
                'visibility': 'PUBLIC',
              },
            },
            'data': {
              'type': isCall ? 'call' : 'message',
              'title': title,
              'body': body,
              'chatId': chatId ?? '',
              'callId': callId ?? '',
              'isVideo': isVideo ? 'true' : 'false',
            },
          },
        },
      );
    } catch (_) {}
  }
}

class AppSettingsController {
  static const MethodChannel _nativeChannel = MethodChannel('com.universal.messenger/icon');
  static const Color defaultPrimaryColor = Color(0xFF008069);
  static const Color defaultChatBgColor = Color(0xFFECE5DD);

  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.light);
  static final ValueNotifier<Color> appThemeColor = ValueNotifier(defaultPrimaryColor);
  static final ValueNotifier<String?> appThemeImage = ValueNotifier(null);
  static final ValueNotifier<Color> chatThemeColor = ValueNotifier(defaultChatBgColor);
  static final ValueNotifier<String?> chatThemeImage = ValueNotifier(null);

  static final ValueNotifier<bool> batteryOptimization = ValueNotifier(true);
  static final ValueNotifier<bool> notificationsEnabled = ValueNotifier(true);
  static final ValueNotifier<bool> headsUpPopup = ValueNotifier(true);
  static final ValueNotifier<bool> statusBarNotification = ValueNotifier(true);
  static final ValueNotifier<bool> chatSounds = ValueNotifier(true);
  static final ValueNotifier<bool> videoCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> audioCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> vibrate = ValueNotifier(true);

  static ValueNotifier<bool> get popupNotificationsEnabled => notificationsEnabled;

  static final ValueNotifier<String?> customCallRingtonePath = ValueNotifier(null);
  static final ValueNotifier<String?> customCallRingtoneName = ValueNotifier(null);
  static final ValueNotifier<String?> customMsgSoundPath = ValueNotifier(null);
  static final ValueNotifier<String?> customMsgSoundName = ValueNotifier(null);

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

  static Future<String> savePermanentAudio(String sourcePath, String prefix) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return sourcePath;
      final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'mp3';
      final dest = File('${_appDir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return sourcePath;
    }
  }

  static Future<void> applyLauncherIcon(String type, {String? customPath}) async {
    try {
      await _nativeChannel.invokeMethod('setAppIcon', {'type': type});
      if (type == 'custom' && customPath != null) {
        await _nativeChannel.invokeMethod('pinCustomShortcut', {'path': customPath});
      }
    } catch (_) {}
  }

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
      batteryOptimization.value = data['batteryOptimization'] ?? true;
      notificationsEnabled.value = data['notificationsEnabled'] ?? true;
      headsUpPopup.value = data['headsUpPopup'] ?? true;
      statusBarNotification.value = data['statusBarNotification'] ?? true;
      chatSounds.value = data['chatSounds'] ?? true;
      videoCallSounds.value = data['videoCallSounds'] ?? true;
      audioCallSounds.value = data['audioCallSounds'] ?? true;
      vibrate.value = data['vibrate'] ?? true;
      customCallRingtonePath.value = data['customCallRingtonePath'];
      customCallRingtoneName.value = data['customCallRingtoneName'];
      customMsgSoundPath.value = data['customMsgSoundPath'];
      customMsgSoundName.value = data['customMsgSoundName'];
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
        'batteryOptimization': batteryOptimization.value,
        'notificationsEnabled': notificationsEnabled.value,
        'headsUpPopup': headsUpPopup.value,
        'statusBarNotification': statusBarNotification.value,
        'chatSounds': chatSounds.value,
        'videoCallSounds': videoCallSounds.value,
        'audioCallSounds': audioCallSounds.value,
        'vibrate': vibrate.value,
        'customCallRingtonePath': customCallRingtonePath.value,
        'customCallRingtoneName': customCallRingtoneName.value,
        'customMsgSoundPath': customMsgSoundPath.value,
        'customMsgSoundName': customMsgSoundName.value,
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
  static bool isAppInForeground = true;
  static String? activeChatId;
  static String? _lastNotifiedCallId;
  static bool _initialChatsLoaded = false;
  static final Map<String, int> _lastChatMsgMillis = {};

  static StreamSubscription<DocumentSnapshot>? _callSub;
  static StreamSubscription<QuerySnapshot>? _chatSub;
  static StreamSubscription<String>? _fcmTokenRefreshSub;
  static Timer? _heartbeatTimer;

  static Future<String> _resolveCallSoundUri() async {
    final callPath = AppSettingsController.customCallRingtonePath.value;
    if (callPath != null && File(callPath).existsSync()) {
      try {
        final contentUri = await _nativeChannel.invokeMethod<String>('getContentUri', {'path': callPath});
        if (contentUri != null && contentUri.isNotEmpty) return contentUri;
      } catch (_) {}
    }
    return 'content://settings/system/ringtone';
  }

  static Future<String> _resolveMsgSoundUri() async {
    final msgPath = AppSettingsController.customMsgSoundPath.value;
    if (msgPath != null && File(msgPath).existsSync()) {
      try {
        final contentUri = await _nativeChannel.invokeMethod<String>('getContentUri', {'path': msgPath});
        if (contentUri != null && contentUri.isNotEmpty) return contentUri;
      } catch (_) {}
    }
    return 'content://settings/system/notification_sound';
  }

  static Future<void> _createFcmChannels() async {
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    final channels = [
      const AndroidNotificationChannel(
        'fcm_heads_up_sound_v1',
        'Push Messages (Pop-up & Sound)',
        description: 'Background pop-up message alerts with sound',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
      const AndroidNotificationChannel(
        'fcm_heads_up_silent_v1',
        'Push Messages (Pop-up Silent)',
        description: 'Background pop-up message alerts without sound',
        importance: Importance.max,
        playSound: false,
        enableVibration: true,
        showBadge: true,
      ),
      const AndroidNotificationChannel(
        'fcm_normal_sound_v1',
        'Push Messages (Status Bar & Sound)',
        description: 'Status bar message alerts with sound',
        importance: Importance.defaultImportance,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
      const AndroidNotificationChannel(
        'fcm_normal_silent_v1',
        'Push Messages (Silent)',
        description: 'Silent status bar message alerts',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: true,
      ),
      const AndroidNotificationChannel(
        'fcm_call_sound_v1',
        'Incoming Push Calls (Ringtone)',
        description: 'Incoming call push notifications with sound',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
      const AndroidNotificationChannel(
        'fcm_call_silent_v1',
        'Incoming Push Calls (Silent)',
        description: 'Silent incoming call push notifications',
        importance: Importance.max,
        playSound: false,
        enableVibration: true,
        showBadge: true,
      ),
    ];

    for (final ch in channels) {
      await androidPlugin.createNotificationChannel(ch);
    }
  }

  static Future<String> _ensureMessageChannel({
    required bool playSound,
    required bool shouldVibrate,
    required bool showPopup,
  }) async {
    final soundUri = playSound ? await _resolveMsgSoundUri() : 'silent';
    final channelId =
        'msg_ch_${playSound ? 1 : 0}_${shouldVibrate ? 1 : 0}_${showPopup ? 1 : 0}_${soundUri.hashCode.abs()}';

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final channel = AndroidNotificationChannel(
        channelId,
        playSound ? 'Chat Messages (Sound)' : 'Chat Messages (Silent)',
        description: 'Chat message notifications',
        importance: showPopup ? Importance.max : Importance.defaultImportance,
        playSound: playSound,
        sound: playSound ? UriAndroidNotificationSound(soundUri) : null,
        audioAttributesUsage: AudioAttributesUsage.notification,
        enableVibration: shouldVibrate,
        vibrationPattern: shouldVibrate ? Int64List.fromList([0, 250, 150, 250]) : null,
        enableLights: true,
        showBadge: true,
      );
      await androidPlugin.createNotificationChannel(channel);
    }
    return channelId;
  }

  static Future<String> _ensureCallChannel({
    required bool playSound,
    required bool shouldVibrate,
    required bool showPopup,
  }) async {
    final soundUri = playSound ? await _resolveCallSoundUri() : 'silent';
    final channelId =
        'call_ch_${playSound ? 1 : 0}_${shouldVibrate ? 1 : 0}_${showPopup ? 1 : 0}_${soundUri.hashCode.abs()}';

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final channel = AndroidNotificationChannel(
        channelId,
        playSound ? 'Incoming Calls (Ringtone)' : 'Incoming Calls (Silent)',
        description: 'Incoming call notifications',
        importance: showPopup ? Importance.max : Importance.defaultImportance,
        playSound: playSound,
        sound: playSound ? UriAndroidNotificationSound(soundUri) : null,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        enableVibration: shouldVibrate,
        vibrationPattern: shouldVibrate ? Int64List.fromList([0, 800, 400, 800]) : null,
        enableLights: true,
        showBadge: true,
      );
      await androidPlugin.createNotificationChannel(channel);
    }
    return channelId;
  }

  static Future<void> rebuildNotificationChannels() async {
    await _createFcmChannels();
    final showPopup = AppSettingsController.headsUpPopup.value;
    final shouldVibrate = AppSettingsController.vibrate.value;
    await _ensureMessageChannel(
      playSound: AppSettingsController.chatSounds.value,
      shouldVibrate: shouldVibrate,
      showPopup: showPopup,
    );
    await _ensureCallChannel(
      playSound: AppSettingsController.audioCallSounds.value || AppSettingsController.videoCallSounds.value,
      shouldVibrate: shouldVibrate,
      showPopup: showPopup,
    );
  }

  static Future<void> playNativeCallRingtone() async {
    try {
      await _nativeChannel.invokeMethod('playRingtone', {
        'path': AppSettingsController.customCallRingtonePath.value,
      });
    } catch (_) {}
  }

  static Future<void> stopNativeCallRingtone() async {
    try {
      await _nativeChannel.invokeMethod('stopRingtone');
    } catch (_) {}
  }

  static Future<void> playNativeMessageSound() async {
    try {
      await _nativeChannel.invokeMethod('playMessageSound', {
        'path': AppSettingsController.customMsgSoundPath.value,
      });
    } catch (_) {}
  }

  static Future<void> cancelAllNotifications() async {
    try {
      await _notifications.cancelAll();
    } catch (_) {}
  }

  static Future<void> start() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await AppSettingsController.load();

    if (!_initialized) {
      _initialized = true;
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _notifications.initialize(initSettings);

      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();

      _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        if (AppSettingsController.notificationsEnabled.value && newToken.isNotEmpty) {
          FirebaseFirestore.instance.collection('users').doc(user.uid).set({
            'fcmToken': newToken,
          }, SetOptions(merge: true));
        }
      });
    }

    await rebuildNotificationChannels();
    await FcmPushService.syncDeviceTokenAndPrefs();
    await setOnlineStatus(true);

    final intervalSeconds = AppSettingsController.batteryOptimization.value ? 25 : 12;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      if (isAppInForeground) {
        setOnlineStatus(true);
      }
    });

    _listenIncomingCalls(user.uid);
    _listenIncomingMessages(user.uid);
  }

  static void setAppForeground(bool inForeground) {
    isAppInForeground = inForeground;
    setOnlineStatus(inForeground);
  }

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

  static Future<void> stop() async {
    await setOfflineAndStop();
  }

  static Future<void> setOfflineAndStop() async {
    _stopCallRing();
    await setOnlineStatus(false);
    _heartbeatTimer?.cancel();
    await _callSub?.cancel();
    await _chatSub?.cancel();
    _callSub = null;
    _chatSub = null;
    _initialChatsLoaded = false;
    _lastChatMsgMillis.clear();
  }

  static void _stopCallRing() {
    stopNativeCallRingtone();
    if (_lastNotifiedCallId != null) {
      _notifications.cancel(_lastNotifiedCallId.hashCode);
      _lastNotifiedCallId = null;
    }
  }

  static bool isUserActive(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (data['isOnline'] != true) return false;
    final lastSeen = data['lastSeen'];
    if (lastSeen is! Timestamp) return false;
    final diffSeconds = DateTime.now().difference(lastSeen.toDate()).inSeconds;
    return diffSeconds >= -20 && diffSeconds <= 35;
  }

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
      if (!snap.exists) {
        _stopCallRing();
        return;
      }
      final data = snap.data();
      if (data == null) {
        _stopCallRing();
        return;
      }

      final status = (data['status'] ?? '').toString();
      final callId = (data['callId'] ?? '').toString();

      if (status != 'ringing') {
        _stopCallRing();
        return;
      }

      if (callId.isEmpty || callId == _lastNotifiedCallId) return;
      _stopCallRing();
      _lastNotifiedCallId = callId;

      if (!AppSettingsController.notificationsEnabled.value) return;

      final callerName = (data['callerName'] ?? 'কেউ একজন').toString();
      final isVideo = data['isVideo'] == true;
      final playSound = isVideo
          ? AppSettingsController.videoCallSounds.value
          : AppSettingsController.audioCallSounds.value;
      final shouldVibrate = AppSettingsController.vibrate.value;
      final showPopup = AppSettingsController.headsUpPopup.value;

      if (playSound) {
        await playNativeCallRingtone();
      }
      if (shouldVibrate) HapticFeedback.heavyImpact();

      final channelId = await _ensureCallChannel(
        playSound: playSound,
        shouldVibrate: shouldVibrate,
        showPopup: showPopup,
      );
      final soundUri = playSound ? await _resolveCallSoundUri() : null;

      final androidDetails = AndroidNotificationDetails(
        channelId,
        playSound ? 'Incoming Calls (Ringtone)' : 'Incoming Calls (Silent)',
        channelDescription: 'Incoming call notifications',
        importance: showPopup ? Importance.max : Importance.defaultImportance,
        priority: showPopup ? Priority.max : Priority.defaultPriority,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: showPopup,
        ongoing: true,
        autoCancel: false,
        playSound: playSound,
        sound: soundUri != null ? UriAndroidNotificationSound(soundUri) : null,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        enableVibration: shouldVibrate,
        vibrationPattern: shouldVibrate ? Int64List.fromList([0, 800, 400, 800]) : null,
        additionalFlags: playSound ? Int32List.fromList([4]) : null,
        channelShowBadge: true,
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
        .limit(50)
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

        if (!AppSettingsController.notificationsEnabled.value) continue;
        if (isAppInForeground && activeChatId == doc.id) continue;
        if (!isAppInForeground && FcmPushService.isConfigured) continue;

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

        final playSound = AppSettingsController.chatSounds.value;
        final shouldVibrate = AppSettingsController.vibrate.value;
        final showPopup = AppSettingsController.headsUpPopup.value;
        final showStatusBar = AppSettingsController.statusBarNotification.value;

        if (playSound) {
          await playNativeMessageSound();
        }
        if (shouldVibrate) HapticFeedback.mediumImpact();

        // পপ-আপ এবং স্ট্যাটাস বার দুটোই বন্ধ থাকলে উপরে কোনো নোটিফিকেশন দেখাবে না
        if (!showPopup && !showStatusBar) continue;

        final channelId = await _ensureMessageChannel(
          playSound: playSound,
          shouldVibrate: shouldVibrate,
          showPopup: showPopup,
        );
        final soundUri = playSound ? await _resolveMsgSoundUri() : null;

        final androidDetails = AndroidNotificationDetails(
          channelId,
          playSound ? 'Chat Messages (Sound)' : 'Chat Messages (Silent)',
          channelDescription: 'Chat message notifications',
          importance: showPopup ? Importance.max : Importance.defaultImportance,
          priority: showPopup ? Priority.max : Priority.defaultPriority,
          category: AndroidNotificationCategory.message,
          playSound: playSound,
          sound: soundUri != null ? UriAndroidNotificationSound(soundUri) : null,
          audioAttributesUsage: AudioAttributesUsage.notification,
          enableVibration: shouldVibrate,
          vibrationPattern: shouldVibrate ? Int64List.fromList([0, 250, 150, 250]) : null,
          channelShowBadge: showStatusBar,
          timeoutAfter: (!showStatusBar && showPopup) ? 4000 : null,
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
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>?;
        final isActive = isUserActive(data);
        final shortAgo = showOfflineTime ? formatLastSeenShort(data) : '';
        final photoUrl = (data?['photoUrl'] ?? data?['profilePic'] ?? '').toString().trim();

        Widget effectiveAvatar = avatar;
        if (photoUrl.isNotEmpty && avatar is CircleAvatar) {
          final double diameter = (avatar.radius ?? 20) * 2;
          if (photoUrl.startsWith('http')) {
            effectiveAvatar = ClipOval(
              child: SizedBox(
                width: diameter,
                height: diameter,
                child: Image.network(
                  photoUrl,
                  fit: BoxFit.cover,
                  cacheWidth: 200,
                  errorBuilder: (_, __, ___) => avatar,
                ),
              ),
            );
          } else if (photoUrl.startsWith('data:image')) {
            try {
              effectiveAvatar = ClipOval(
                child: SizedBox(
                  width: diameter,
                  height: diameter,
                  child: Image.memory(
                    base64Decode(photoUrl.split(',').last),
                    fit: BoxFit.cover,
                    cacheWidth: 200,
                    errorBuilder: (_, __, ___) => avatar,
                  ),
                ),
              );
            } catch (_) {}
          }
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            effectiveAvatar,
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
  }
}

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onLoggedOut;
  const SettingsScreen({super.key, this.onLoggedOut});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _cloudName = 'tcdkckrl';
  static const String _uploadPreset = 'ml_default';

  final User? _user = FirebaseAuth.instance.currentUser;
  String _displayName = '';
  String? _photoUrl;
  bool _isBusy = false;
  Timer? _previewStopTimer;

  @override
  void initState() {
    super.initState();
    _displayName = _user?.displayName ?? 'User';
    _photoUrl = _user?.photoURL;
    _loadUserFromFirestore();
  }

  @override
  void dispose() {
    _previewStopTimer?.cancel();
    NotificationAndPresenceService.stopNativeCallRingtone();
    super.dispose();
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

  void _playShortRingtonePreview() {
    _previewStopTimer?.cancel();
    NotificationAndPresenceService.playNativeCallRingtone();
    _previewStopTimer = Timer(const Duration(seconds: 2), () {
      NotificationAndPresenceService.stopNativeCallRingtone();
    });
  }

  Future<void> _pickCustomCallRingtone() async {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty || files.first.path == null) return;

    final picked = files.first;
    final savedPath = await AppSettingsController.savePermanentAudio(picked.path!, 'call_ringtone');
    AppSettingsController.customCallRingtonePath.value = savedPath;
    AppSettingsController.customCallRingtoneName.value = picked.name;
    await AppSettingsController.save();
    await NotificationAndPresenceService.rebuildNotificationChannels();

    _previewStopTimer?.cancel();
    await NotificationAndPresenceService.playNativeCallRingtone();
    _previewStopTimer = Timer(const Duration(seconds: 4), () {
      NotificationAndPresenceService.stopNativeCallRingtone();
    });

    if (mounted) setState(() {});
    _showMsg('Call ringtone set: ${picked.name}');
  }

  Future<void> _resetCallRingtone() async {
    _previewStopTimer?.cancel();
    await NotificationAndPresenceService.stopNativeCallRingtone();
    AppSettingsController.customCallRingtonePath.value = null;
    AppSettingsController.customCallRingtoneName.value = null;
    await AppSettingsController.save();
    await NotificationAndPresenceService.rebuildNotificationChannels();
    if (mounted) setState(() {});
    _showMsg('Default call ringtone restored');
  }

  Future<void> _pickCustomMessageSound() async {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty || files.first.path == null) return;

    final picked = files.first;
    final savedPath = await AppSettingsController.savePermanentAudio(picked.path!, 'msg_sound');
    AppSettingsController.customMsgSoundPath.value = savedPath;
    AppSettingsController.customMsgSoundName.value = picked.name;
    await AppSettingsController.save();
    await NotificationAndPresenceService.rebuildNotificationChannels();
    await NotificationAndPresenceService.playNativeMessageSound();

    if (mounted) setState(() {});
    _showMsg('Message sound set: ${picked.name}');
  }

  Future<void> _resetMessageSound() async {
    AppSettingsController.customMsgSoundPath.value = null;
    AppSettingsController.customMsgSoundName.value = null;
    await AppSettingsController.save();
    await NotificationAndPresenceService.rebuildNotificationChannels();
    if (mounted) setState(() {});
    _showMsg('Default message sound restored');
  }

  Future<void> _syncUserProfileAcrossChats({String? newName, String? newPhotoUrl}) async {
    if (_user == null) return;
    try {
      final chatsSnap = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: _user!.uid)
          .get();
      if (chatsSnap.docs.isEmpty) return;

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in chatsSnap.docs) {
        final updates = <String, dynamic>{};
        if (newName != null) updates['users.${_user!.uid}.name'] = newName;
        if (newPhotoUrl != null) updates['users.${_user!.uid}.photoUrl'] = newPhotoUrl;
        if (updates.isNotEmpty) {
          batch.update(doc.reference, updates);
        }
      }
      await batch.commit();
    } catch (_) {}
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
      await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({
        'name': newName,
      }, SetOptions(merge: true));
      await _syncUserProfileAcrossChats(newName: newName);
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
    if (files.isEmpty || files.first.path == null) return;

    setState(() => _isBusy = true);
    try {
      final picked = files.first;
      final file = File(picked.path!);

      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: picked.name),
        'upload_preset': _uploadPreset,
        'folder': 'universal_messenger/profiles',
      });

      final response = await Dio().post(
        'https://api.cloudinary.com/v1_1/$_cloudName/image/upload',
        data: formData,
      );

      final downloadUrl = response.data['secure_url']?.toString() ?? '';
      if (downloadUrl.isEmpty) {
        throw Exception('Could not upload photo to server.');
      }

      await _user!.updatePhotoURL(downloadUrl);
      await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({
        'photoUrl': downloadUrl,
      }, SetOptions(merge: true));
      await _syncUserProfileAcrossChats(newPhotoUrl: downloadUrl);

      setState(() => _photoUrl = downloadUrl);
      _showMsg('Profile photo updated for everyone');
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
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current Password', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New Password (min 6 chars)', border: OutlineInputBorder()),
            ),
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
            Text(
              isChatTheme ? 'Chat Theme' : 'App Theme',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
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
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade400, width: 1.5),
                    ),
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
    if (src.startsWith('data:image')) {
      try {
        return MemoryImage(base64Decode(src.split(',').last));
      } catch (_) {
        return null;
      }
    }
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
        final avatarProvider = _buildAvatarProvider(_photoUrl);
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
                        backgroundImage: avatarProvider,
                        child: avatarProvider == null ? const Icon(Icons.person) : null,
                      ),
                      title: const Text('Account Info', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(_displayName),
                      children: [
                        ListTile(
                          leading: const Icon(Icons.edit),
                          title: const Text('Change name'),
                          onTap: _changeNameDialog,
                        ),
                        ListTile(
                          leading: const Icon(Icons.photo_camera),
                          title: const Text('Change photo'),
                          onTap: _changeProfilePhoto,
                        ),
                        ListTile(
                          leading: const Icon(Icons.lock_reset),
                          title: const Text('Change password'),
                          onTap: _changePasswordDialog,
                        ),
                        ListTile(
                          leading: const Icon(Icons.logout, color: Colors.red),
                          title: const Text('Log out', style: TextStyle(color: Colors.red)),
                          onTap: _logout,
                        ),
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
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AppSettingsController.batteryOptimization,
                      builder: (context, isBatteryOpt, _) {
                        return SwitchListTile(
                          secondary: Icon(isBatteryOpt ? Icons.battery_saver : Icons.battery_std),
                          title: const Text('Battery Optimization', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            isBatteryOpt
                                ? 'Active: Low power mode & smart background sync'
                                : 'Off: Full background speed mode',
                          ),
                          value: isBatteryOpt,
                          onChanged: (val) async {
                            AppSettingsController.batteryOptimization.value = val;
                            await AppSettingsController.save();
                            await NotificationAndPresenceService.start();
                            _showMsg(val ? 'Battery Optimization ON' : 'Battery Optimization OFF');
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
                          valueListenable: AppSettingsController.notificationsEnabled,
                          builder: (_, enabled, __) => Column(
                            children: [
                              SwitchListTile(
                                secondary: const Icon(Icons.notifications),
                                title: const Text('Notifications'),
                                subtitle: Text(
                                  enabled
                                      ? 'All notifications enabled (even when closed)'
                                      : 'All notifications muted',
                                ),
                                value: enabled,
                                onChanged: (v) async {
                                  AppSettingsController.notificationsEnabled.value = v;
                                  await AppSettingsController.save();
                                  await NotificationAndPresenceService.rebuildNotificationChannels();
                                  await FcmPushService.syncDeviceTokenAndPrefs();
                                  if (!v) {
                                    await NotificationAndPresenceService.stopNativeCallRingtone();
                                    await NotificationAndPresenceService.cancelAllNotifications();
                                  }
                                  _showMsg(v ? 'Notifications turned ON' : 'Notifications turned OFF');
                                },
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.headsUpPopup,
                                builder: (_, popupVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.branding_watermark_outlined),
                                  title: const Text('Pop-up on screen'),
                                  subtitle: Text(popupVal ? 'Top floating banner ON' : 'Top floating banner OFF'),
                                  value: enabled && popupVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.headsUpPopup.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (!v && !AppSettingsController.statusBarNotification.value) {
                                            await NotificationAndPresenceService.cancelAllNotifications();
                                          }
                                          _showMsg(v ? 'Top pop-up banner ON' : 'Top pop-up banner OFF');
                                        },
                                ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.statusBarNotification,
                                builder: (_, statusBarVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.notifications_none),
                                  title: const Text('Status bar notification'),
                                  subtitle: Text(
                                    statusBarVal
                                        ? 'Top status bar icon & tray ON'
                                        : 'Top status bar notification OFF',
                                  ),
                                  value: enabled && statusBarVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.statusBarNotification.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (!v && !AppSettingsController.headsUpPopup.value) {
                                            await NotificationAndPresenceService.cancelAllNotifications();
                                          }
                                          _showMsg(v ? 'Status bar notification ON' : 'Status bar notification OFF');
                                        },
                                ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.chatSounds,
                                builder: (_, chatVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.message),
                                  title: const Text('Chat sounds'),
                                  value: enabled && chatVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.chatSounds.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (v) NotificationAndPresenceService.playNativeMessageSound();
                                        },
                                ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.videoCallSounds,
                                builder: (_, videoVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.videocam),
                                  title: const Text('Video call sounds'),
                                  value: enabled && videoVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.videoCallSounds.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (v) _playShortRingtonePreview();
                                        },
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.audioCallSounds,
                                builder: (_, audioVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.call),
                                  title: const Text('Audio call sounds'),
                                  value: enabled && audioVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.audioCallSounds.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (v) _playShortRingtonePreview();
                                        },
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: AppSettingsController.vibrate,
                                builder: (_, vibVal, __) => SwitchListTile(
                                  secondary: const Icon(Icons.vibration),
                                  title: const Text('Vibrate'),
                                  value: enabled && vibVal,
                                  onChanged: !enabled
                                      ? null
                                      : (v) async {
                                          AppSettingsController.vibrate.value = v;
                                          await AppSettingsController.save();
                                          await NotificationAndPresenceService.rebuildNotificationChannels();
                                          await FcmPushService.syncDeviceTokenAndPrefs();
                                          if (v) HapticFeedback.vibrate();
                                        },
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        ValueListenableBuilder<String?>(
                          valueListenable: AppSettingsController.customCallRingtoneName,
                          builder: (_, ringtoneName, __) => ListTile(
                            leading: const Icon(Icons.ring_volume, color: Color(0xFF008069)),
                            title: const Text('Call ringtone (MP3)'),
                            subtitle: Text(
                              ringtoneName ?? 'Default system ringtone',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (ringtoneName != null)
                                  IconButton(
                                    icon: const Icon(Icons.restart_alt, color: Colors.orange),
                                    tooltip: 'Reset to default',
                                    onPressed: _resetCallRingtone,
                                  ),
                                const Icon(Icons.audio_file),
                              ],
                            ),
                            onTap: _pickCustomCallRingtone,
                          ),
                        ),
                        ValueListenableBuilder<String?>(
                          valueListenable: AppSettingsController.customMsgSoundName,
                          builder: (_, msgToneName, __) => ListTile(
                            leading: const Icon(Icons.music_note, color: Color(0xFF1A73E8)),
                            title: const Text('Message sound (MP3)'),
                            subtitle: Text(
                              msgToneName ?? 'Default notification sound',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (msgToneName != null)
                                  IconButton(
                                    icon: const Icon(Icons.restart_alt, color: Colors.orange),
                                    tooltip: 'Reset to default',
                                    onPressed: _resetMessageSound,
                                  ),
                                const Icon(Icons.audio_file),
                              ],
                            ),
                            onTap: _pickCustomMessageSound,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
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
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 28,
                                            color: Color(0xFF4285F4),
                                          ),
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
                                          image: customImg != null
                                              ? DecorationImage(image: customImg, fit: BoxFit.cover)
                                              : null,
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
