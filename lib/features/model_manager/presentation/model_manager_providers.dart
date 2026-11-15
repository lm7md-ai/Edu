import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped after an import/removal so every runtime/model provider resolves the
/// current app-private artifact paths and rebuilds lazy model resources.
final StateProvider<int> modelCatalogRevisionProvider =
    StateProvider<int>((ref) => 0);
