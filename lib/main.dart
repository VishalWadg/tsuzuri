import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'src/content/providers/content_source_providers.dart';
import 'src/data/content_db.dart';
import 'src/data/models.dart';
import 'src/data/user_db.dart';
import 'src/providers/app_providers.dart';
import 'src/ui/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appDocDir = await getApplicationDocumentsDirectory();
  final contentDb = await ContentDatabase.initialize(appStorageDir: appDocDir);
  final userDb = await UserDatabase.openFromDirectory(appDocDir);

  final container = ProviderContainer(
    overrides: [
      contentDatabaseProvider.overrideWithValue(contentDb),
      userDatabaseProvider.overrideWithValue(userDb),
      appDocumentsDirectoryProvider.overrideWithValue(appDocDir),
    ],
  );
  await container.read(contentSourceManagerProvider).hydrateOnStartup();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const OfflineKanjiPracticeApp(),
    ),
  );
}

class OfflineKanjiPracticeApp extends ConsumerWidget {
  const OfflineKanjiPracticeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final themeMode = switch (settings.themeMode) {
      AppThemeMode.system => ThemeMode.system,
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
    };

    return MaterialApp(
      title: 'Tsuzuri',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
          surface: const Color(0xFF0F172A),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        cardTheme: const CardThemeData(
          color: Color(0xFF1E293B),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
