/// A typed, user-safe failure crossing a domain or application boundary.
///
/// [message] is suitable for diagnostic UI. Do not put credentials, raw
/// document contents, or model prompts in it. [cause] is retained for local
/// diagnostics and must not be serialized to remote peers.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  String get code;

  @override
  String toString() => 'AppFailure($code): $message';
}

final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.cause});

  @override
  String get code => 'validation';
}

final class StorageFailure extends AppFailure {
  const StorageFailure(super.message, {super.cause});

  @override
  String get code => 'storage';
}

final class EngineFailure extends AppFailure {
  const EngineFailure(super.message, {super.cause});

  @override
  String get code => 'engine';
}

final class TransportFailure extends AppFailure {
  const TransportFailure(super.message, {super.cause});

  @override
  String get code => 'transport';
}
