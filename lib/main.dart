import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/auth/password/change_password_screen.dart';
import 'screens/sos/background_service.dart'; // تأكد من أن هذا الملف لا يستورد Facebook SDK
import 'screens/sos/home_screen.dart';
import 'screens/auth/splash_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/auth/confirmed_screen.dart';
import 'screens/auth/how_screen.dart';
import 'screens/auth/permissions_screen.dart';
import 'screens/trust_contacts/add_trust_contact_screen.dart';
import 'screens/trust_contacts/add_contact_screen.dart';
import 'screens/trust_contacts/contact_added_screen.dart';
import 'screens/auth/password/forgot_password_screen.dart';
import 'screens/auth/password/verification_screen.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. تهيئة الإشعارات بدقة بناءً على متطلبات الـ IDE التي أظهرتها
  await _setupNotifications();

  runApp(const VoxGuardApp());

  // 2. تشغيل الخدمة بعد وقت قصير لضمان استقرار التطبيق
  _startServiceSafely();
}

Future<void> _setupNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  // الكود المصحح بناءً على طلب الـ IDE لـ 'settings' كـ Named Parameter
  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      debugPrint("Notification clicked: ${response.payload}");
    },
  );

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'voxguard_emergency',
    'VoxGuard Emergency Service',
    description: 'This channel is used for vital personal safety features.',
    importance: Importance.high,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

Future<void> _startServiceSafely() async {
  await Future.delayed(const Duration(seconds: 3));

  // التحقق من الأذونات قبل التشغيل
  final status = await Permission.microphone.status;
  final locStatus = await Permission.locationAlways.status;

  if (status.isGranted && locStatus.isGranted) {
    await initializeBackgroundService();
  } else {
    debugPrint("Permissions not granted, service not started.");
  }
}

class VoxGuardApp extends StatelessWidget {
  const VoxGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/login': (context) => const LoginScreen(),
        '/signup': (context) => const SignupScreen(),
        '/confirmed': (context) => const ConfirmedScreen(),
        '/how_safe': (context) => const HowWeKeepSafeScreen(),
        '/permissions': (context) => const PermissionsScreen(),
        '/trust_contacts': (context) => const AddTrustedContactsScreen(),
        '/add_contact': (context) => const AddContactScreen(),
        '/contact_added': (context) => const ContactAddedScreen(),
        '/forgot_password': (context) => const ForgotPasswordScreen(),
        '/verification': (context) => const VerificationScreen(),
        '/home': (context) => const HomeScreen(),
        '/change_password': (context) => const ChangePasswordScreen(),
      },
    );
  }
}