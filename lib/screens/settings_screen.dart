import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// অ্যাপের সব সেটিংস লাইভ নিয়ন্ত্রণ ও সেভ করার কন্ট্রোলার
class AppSettingsController {
  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.light);
  static final ValueNotifier<Color> appThemeColor = ValueNotifier(const Color(0xFF1A73E8));
  static final ValueNotifier<String?> appThemeImage = ValueNotifier(null);
  static final ValueNotifier<Color> chatThemeColor = ValueNotifier(const Color(0xFFECE5DD));
  static final ValueNotifier<String?> chatThemeImage = ValueNotifier(null);

  static final ValueNotifier<bool> chatSounds = ValueNotifier(true);
  static final ValueNotifier<bool> videoCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> audioCallSounds = ValueNotifier(true);
  static final ValueNotifier<bool> vibrate = ValueNotifier(true);

  /// 'default' | 'google' | 'custom'
  static final ValueNotifier<String> iconType = ValueNotifier('default');
  static final ValueNotifier<String?> customIconPath = ValueNotifier(null);

  static File get _settingsFile {
    final dir = Directory('/data/user/0/com.universal.messenger/files');
    if (dir.existsSync()) {
      return File('${dir.path}/app_settings.json');
    }
    return File('${Directory.systemTemp.path}/universal_messenger_settings.json');
  }

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

  // ১. Change Name
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
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
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
      setState(() => _displayName = newName);
      _showMsg('Name updated successfully');
    } catch (e) {
      _showMsg('Failed to update name: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ১. Change Photo
  Future<void> _changeProfilePhoto() async {
    if (_user == null) return;
    final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (res == null || res.files.isEmpty) return;

    setState(() => _isBusy = true);
    try {
      final file = res.files.first;
      String photoValue = file.path ?? '';
      if (file.bytes != null && file.bytes!.length <= 500 * 1024) {
        photoValue = 'data:image/jpeg;base64,${base64Encode(file.bytes!)}';
      }
      await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({
        'photoUrl': photoValue,
      }, SetOptions(merge: true));
      setState(() => _photoUrl = photoValue);
      _showMsg('Profile photo updated');
    } catch (e) {
      _showMsg('Photo update failed: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ১. Change Password
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

  // ১. Log Out
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
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    if (widget.onLoggedOut != null) {
      widget.onLoggedOut!();
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  // ২. Change Theme (Chat Theme / App Theme + File Image)
  Future<void> _openThemePicker({required bool isChatTheme}) async {
    final colors = [
      const Color(0xFF1A73E8),
      const Color(0xFF00897B),
      const Color(0xFF6A1B9A),
      const Color(0xFFE53935),
      const Color(0xFF2E7D32),
      const Color(0xFF263238),
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
                  onTap: () {
                    if (isChatTheme) {
                      AppSettingsController.chatThemeColor.value = c;
                      AppSettingsController.chatThemeImage.value = null;
                    } else {
                      AppSettingsController.appThemeColor.value = c;
                      AppSettingsController.appThemeImage.value = null;
                    }
                    AppSettingsController.save();
                    Navigator.pop(ctx);
                    _showMsg(isChatTheme ? 'Chat theme color updated' : 'App theme color updated');
                  },
                  child: CircleAvatar(backgroundColor: c, radius: 22),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.image),
                label: const Text('Choose File Image from Gallery'),
                onPressed: () async {
                  final res = await FilePicker.platform.pickFiles(type: FileType.image);
                  if (res != null && res.files.single.path != null) {
                    final path = res.files.single.path!;
                    if (isChatTheme) {
                      AppSettingsController.chatThemeImage.value = path;
                    } else {
                      AppSettingsController.appThemeImage.value = path;
                    }
                    await AppSettingsController.save();
                    if (ctx.mounted) Navigator.pop(ctx);
                    _showMsg('Custom theme image applied');
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ৫. Icon (Google Icon & Custom Photo Icon)
  Future<void> _pickCustomPhotoIcon() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res != null && res.files.single.path != null) {
      AppSettingsController.iconType.value = 'custom';
      AppSettingsController.customIconPath.value = res.files.single.path!;
      await AppSettingsController.save();
      setState(() {});
      _showMsg('Custom photo icon selected');
    }
  }

  ImageProvider? _buildAvatarProvider(String? src) {
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('data:image')) {
      final b64 = src.split(',').last;
      return MemoryImage(base64Decode(b64));
    }
    if (src.startsWith('http')) return NetworkImage(src);
    final f = File(src);
    if (f.existsSync()) return FileImage(f);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // 1. Account Info
              Card(
                child: ExpansionTile(
                  initiallyExpanded: true,
                  leading: CircleAvatar(
                    backgroundImage: _buildAvatarProvider(_photoUrl),
                    child: _photoUrl == null ? const Icon(Icons.person) : null,
                  ),
                  title: const Text('1. Account Info', style: TextStyle(fontWeight: FontWeight.bold)),
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

              // 2. Change Theme
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.color_lens),
                  title: const Text('2. Change Theme', style: TextStyle(fontWeight: FontWeight.bold)),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: const Text('Chat Theme (Color / File Image)'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openThemePicker(isChatTheme: true),
                    ),
                    ListTile(
                      leading: const Icon(Icons.wallpaper),
                      title: const Text('App Theme (Color / File Image)'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openThemePicker(isChatTheme: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // 3. Day or Dark Mode (Clickable)
              Card(
                child: ValueListenableBuilder<ThemeMode>(
                  valueListenable: AppSettingsController.themeMode,
                  builder: (context, mode, _) {
                    final isDark = mode == ThemeMode.dark;
                    return ListTile(
                      leading: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                      title: const Text('3. Day or Dark Mode', style: TextStyle(fontWeight: FontWeight.bold)),
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

              // 4. Notification
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.notifications_active),
                  title: const Text('4. Notification', style: TextStyle(fontWeight: FontWeight.bold)),
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

              // 5. Icon (Google Icon & Custom Photo Icon)
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.app_shortcut),
                  title: const Text('5. Icon', style: TextStyle(fontWeight: FontWeight.bold)),
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: AppSettingsController.iconType,
                      builder: (_, type, __) => Column(
                        children: [
                          ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: Colors.white,
                              child: Text('G', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Colors.blue)),
                            ),
                            title: const Text('Google icon'),
                            trailing: type == 'google' ? const Icon(Icons.check_circle, color: Colors.green) : null,
                            onTap: () {
                              AppSettingsController.iconType.value = 'google';
                              AppSettingsController.save();
                              _showMsg('Google icon applied');
                            },
                          ),
                          ListTile(
                            leading: CircleAvatar(
                              backgroundImage: _buildAvatarProvider(AppSettingsController.customIconPath.value),
                              child: AppSettingsController.customIconPath.value == null ? const Icon(Icons.add_a_photo) : null,
                            ),
                            title: const Text('Custom photo icon (file photo)'),
                            trailing: type == 'custom' ? const Icon(Icons.check_circle, color: Colors.green) : null,
                            onTap: _pickCustomPhotoIcon,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isBusy)
            Container(
              color: Colors.black38,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
