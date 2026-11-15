import 'package:edu/presentation/home_shell.dart';
import 'package:flutter/material.dart';

final class EduApp extends StatelessWidget {
  const EduApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Edu Tutor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3659A2)),
          useMaterial3: true,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: const HomeShell(),
      );
}
