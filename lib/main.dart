import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:universal_messenger/screens/auth_screen.dart';
import 'package:universal_messenger/screens/verify_email_screen.dart';
import 'package:universal_messenger/screens/home_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await AppSettingsController.load();
  if (!AppSettingsController.notificationsEnabled.value) return;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await NotificationAndPresenceService.rebuildNotificationChannels();

  final data = message.data;
  final isCall = data['type'] == 'call';
  final title = (data['title'] ?? message.notification?.title ?? 'Universal Messenger').toString();
  final body = (data['body'] ?? message.notification?.body ?? 'নতুন মেসেজ এসেছে').toString();
  final idKey = isCall ? (data['callId'] ?? 'call') : (data['chatId'] ?? 'msg');

  await plugin.show(
    idKey.hashCode,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        isCall ? 'call_ch_master_v1' : 'msg_ch_master_v1',
        isCall ? 'Incoming Calls' : 'Chat Messages',
        importance: Importance.max,
        priority: Priority.max,
        category: isCall
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
        fullScreenIntent: isCall,
        playSound: true,
        sound: UriAndroidNotificationSound(
          isCall
              ? 'content://settings/system/ringtone'
              : 'content://settings/system/notification_sound',
        ),
        enableVibration: true,
        vibrationPattern: Int64List.fromList(
          isCall ? [0, 800, 400, 800] : [0, 250, 150, 250],
        ),
        visibility: NotificationVisibility.public,
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 50 * 1024 * 1024,
  );
  await AppSettingsController.load();
  await NotificationAndPresenceService.rebuildNotificationChannels();
  runApp(const UniversalMessengerApp());
}

class UniversalMessengerApp extends StatelessWidget {
  const UniversalMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettingsController.themeMode,
      builder: (context, mode, _) {
        return ValueListenableBuilder<Color>(
          valueListenable: AppSettingsController.appThemeColor,
          builder: (context, seedColor, __) {
            return MaterialApp(
              navigatorKey: navigatorKey,
              title: 'Universal Messenger',
              debugShowCheckedModeBanner: false,
              themeMode: mode,
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: seedColor,
                  brightness: Brightness.light,
                ),
                useMaterial3: true,
              ),
              darkTheme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: seedColor,
                  brightness: Brightness.dark,
                ),
                useMaterial3: true,
              ),
              builder: (context, child) {
                return Stack(
                  children: [
                    child!,
                    ZegoUIKitPrebuiltCallMiniOverlayPage(
                      contextQuery: () => navigatorKey.currentState!.context,
                    ),
                  ],
                );
              },
              home: const AuthGate(),
            );
          },
        );
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          return const AuthScreen();
        }

        if (!user.emailVerified) {
          return const VerifyEmailScreen();
        }

        return const HomeScreen();
      },
    );
  }
}
