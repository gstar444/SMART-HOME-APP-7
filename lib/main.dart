import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dashboard_page.dart';
import 'esp32_api.dart';
import 'home_controller.dart';
import 'mqtt_service.dart';
import 'mqtt_transport.dart';
import 'secure_storage.dart';
import 'settings.dart';

export 'settings.dart' show esp32Url, defaultEsp32Url;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Settings are read once before the first frame, so the page URL is known
  // immediately and the app does not need a second "loading" screen.
  final controller = await SettingsController.load();

  // Everything else is created synchronously and cheaply; nothing here waits for the network.
  final store = SecureStore();
  final local = Esp32Controller(controller, store); // loads its token and polls asynchronously
  final mqtt = MqttService(transportFactory: MqttClientTransport.new);
  final home = HomeController(settings: controller, mqtt: mqtt, local: local);
  runApp(SmartHomeApp(controller: controller, store: store, local: local, mqtt: mqtt, home: home));

  // Cloud connection: started AFTER the first frame, so the TLS handshake (and a secure-storage
  // read, which can take tens of milliseconds on a cold start) never delays the UI.
  unawaited(() async {
    final cloud = await store.loadCloud();
    if (cloud != null) await mqtt.configure(cloud);
  }());
}

ThemeData buildTheme(Color accent, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
  final background = dark ? const Color(0xFF0C1117) : const Color(0xFFF5F8FC);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class SmartHomeApp extends StatelessWidget {
  const SmartHomeApp({
    super.key,
    required this.controller,
    required this.store,
    required this.local,
    required this.mqtt,
    required this.home,
  });

  final SettingsController controller;
  final SecureStore store;
  final Esp32Controller local;
  final MqttService mqtt;
  final HomeController home;

  @override
  Widget build(BuildContext context) {
    // Providers sit ABOVE MaterialApp, so every pushed screen (settings, boards, cloud) can read them.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: controller),
        Provider<SecureStore>.value(value: store),
        ChangeNotifierProvider<Esp32Controller>.value(value: local),
        ChangeNotifierProvider<MqttService>.value(value: mqtt),
        ChangeNotifierProvider<HomeController>.value(value: home),
      ],
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final s = controller.value;
          final accent = Color(s.accent);
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: s.title,
            themeMode: s.themeMode,
            theme: buildTheme(accent, Brightness.light),
            darkTheme: buildTheme(accent, Brightness.dark),
            // The dashboard lives *below* MaterialApp, so dialogs, snack bars and
            // navigation get a valid Navigator / ScaffoldMessenger context.
            home: DashboardPage(settings: controller, esp: home),
          );
        },
      ),
    );
  }
}
