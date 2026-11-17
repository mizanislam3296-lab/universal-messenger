import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:universal_messenger/screens/auth_screen.dart';
import 'package:universal_messenger/screens/verify_email_screen.dart';
import 'package:universal_messenger/screens/home_screen.dart';
import 'package:universal_messenger/screens/settings_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AppSettingsController.load();
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
