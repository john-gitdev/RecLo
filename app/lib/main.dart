import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:reclo/pages/home_screen.dart';
import 'package:reclo/pages/conversation_detail_screen.dart';
import 'package:reclo/pages/device_scan_screen.dart';
import 'package:reclo/pages/device_settings_screen.dart';
import 'package:reclo/pages/settings_screen.dart';
import 'package:reclo/providers/reclo_provider.dart';
import 'package:reclo/services/audio_chunk_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A0A0A),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const RecLoApp());
}

class RecLoApp extends StatelessWidget {
  const RecLoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => RecLoProvider()..init(),
      child: MaterialApp(
        title: 'RecLo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: false,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0A0A0A),
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            secondary: Color(0xFF4ADE80),
            surface: Color(0xFF111111),
          ),
          fontFamily: 'SF Pro Display',
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: const _RootScreen(),
      ),
    );
  }
}

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RecLoProvider>();

    return HomeScreen(
      isConnected: provider.isConnected,
      isScanning: provider.isScanning,
      isRecording: provider.isRecording,
      conversations: provider.conversations,
      pendingChunks: provider.pendingChunks,
      onFinalizePressed: () => provider.finalizeNow(),
      onConversationTapped: (conversation) =>
          _openConversation(context, conversation, provider.silenceThresholdDb),
      onScanPressed: () => _handleDeviceTap(context, provider),
      onSettingsPressed: () => _openSettings(context),
    );
  }

  void _handleDeviceTap(BuildContext context, RecLoProvider provider) {
    if (provider.isConnected) {
      _openDeviceSettings(context);
    } else {
      _openDeviceScan(context, provider);
    }
  }

  void _openDeviceScan(BuildContext context, RecLoProvider provider) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceScanScreen(
          onDeviceSelected: (device) async {
            // Pop the scan screen first
            Navigator.of(context).pop();
            // Then connect
            await provider.connectToDevice(device);
          },
        ),
      ),
    );
  }

  void _openDeviceSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DeviceSettingsScreen()),
    );
  }

  void _openConversation(
    BuildContext context,
    Conversation conversation,
    double silenceThresholdDb,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(
          conversation: conversation,
          silenceThresholdDb: silenceThresholdDb,
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }
}
