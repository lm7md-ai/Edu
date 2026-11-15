import 'package:edu/app/app.dart';
import 'package:edu/features/model_manager/data/on_device_model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OnDeviceModelCatalog.initialize();
  runApp(const ProviderScope(child: EduApp()));
}
