import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'src/data/content_db.dart';
import 'src/data/user_db.dart';
import 'src/providers/app_providers.dart';
import 'src/ui/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appDocDir = await getApplicationDocumentsDirectory();
  final contentDb = await ContentDatabase.initialize(appStorageDir: appDocDir);
  final userDb = await UserDatabase.openFromDirectory(appDocDir);

  runApp(
    ProviderScope(
      overrides: [
        contentDatabaseProvider.overrideWithValue(contentDb),
        userDatabaseProvider.overrideWithValue(userDb),
      ],
      child: const OfflineKanjiPracticeApp(),
    ),
  );
}

class OfflineKanjiPracticeApp extends StatelessWidget {
  const OfflineKanjiPracticeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Kanji Practice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
