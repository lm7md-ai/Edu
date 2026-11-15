import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Model roles the app can install into private, app-owned storage.
enum OnDeviceModelId {
  gemma4E4b,
  gemma4E2b,
  kokoro82m,
  sileroVad,
  bgeM3,
  moonshineAsr,
}

final class OnDeviceModelSpec {
  const OnDeviceModelSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.allowedExtensions,
    required this.defaultExtension,
    required this.defaultDownloadUrl,
    required this.downloadSourceLabel,
  });

  final OnDeviceModelId id;
  final String title;
  final String description;
  final List<String> allowedExtensions;
  final String defaultExtension;
  final String? defaultDownloadUrl;
  final String downloadSourceLabel;

  static const List<OnDeviceModelSpec> all = <OnDeviceModelSpec>[
    OnDeviceModelSpec(
      id: OnDeviceModelId.gemma4E4b,
      title: 'Gemma 4 E4B',
      description: 'Gemma 4 E4B, LiteRT-LM package (about 3.66 GB).',
      allowedExtensions: <String>['litertlm', 'tflite', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/28299f30ee4d43294517a4ac93abd6163412f07f/gemma-4-E4B-it.litertlm?download=true',
      downloadSourceLabel: 'LiteRT Community on Hugging Face • Gemma 4',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.gemma4E2b,
      title: 'Gemma 4 E2B',
      description: 'Gemma 4 E2B, LiteRT-LM package (about 2.59 GB).',
      allowedExtensions: <String>['litertlm', 'tflite', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm?download=true',
      downloadSourceLabel: 'LiteRT Community on Hugging Face • Gemma 4',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.kokoro82m,
      title: 'Kokoro-82M',
      description: 'Kokoro-82M LiteRT-LM package (about 295 MB; no Arabic voice).',
      allowedExtensions: <String>['litertlm', 'tflite', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl:
          'https://huggingface.co/litert-community/Kokoro-82M/resolve/81e43a025bccabcbbd487f08bc3ebd65b5fc7295/kokoro_int8_fp16.litertlm?download=true',
      downloadSourceLabel: 'LiteRT Community on Hugging Face • Kokoro',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.sileroVad,
      title: 'Silero VAD',
      description: 'Silero VAD role. No default file: the discovered source is standalone TFLite, and app-backend compatibility is unverified.',
      allowedExtensions: <String>['litertlm', 'tflite', 'task', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl: null,
      downloadSourceLabel: 'No verified default source for this runtime role',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.bgeM3,
      title: 'Text embeddings (BGE-M3 / multilingual E5 role)',
      description: 'No default file: EmbeddingGemma 2 is not a drop-in BGE-M3/E5 replacement, and integration compatibility is unverified.',
      allowedExtensions: <String>['litertlm', 'tflite', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl: null,
      downloadSourceLabel: 'No verified default source for this runtime role',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.moonshineAsr,
      title: 'Moonshine / Whisper ASR (Arabic + English role)',
      description: 'No default file: Moonshine Tiny is English-only; other ASR bundles need explicit verification with this app backend.',
      allowedExtensions: <String>['litertlm', 'tflite', 'task', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
      defaultDownloadUrl: null,
      downloadSourceLabel: 'No verified default source for this runtime role',
    ),
  ];

  static OnDeviceModelSpec forId(OnDeviceModelId id) =>
      all.firstWhere((spec) => spec.id == id);
}

final class ModelInstallRecord {
  const ModelInstallRecord({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.importedAt,
  });

  final OnDeviceModelId id;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final DateTime importedAt;

  Map<String, Object> toJson() => <String, Object>{
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'imported_at': importedAt.toUtc().toIso8601String(),
      };
}

/// Persistent, app-private model installation catalog.
///
/// Downloads stream into a temporary file, compute SHA-256, then atomically move
/// into the models directory and update the manifest. A checksum proves file
/// integrity only; it does not prove the publisher or runtime compatibility.
final class OnDeviceModelCatalog {
  OnDeviceModelCatalog._(this.supportDirectory)
      : modelsDirectory = Directory(
          '${supportDirectory.path}${Platform.pathSeparator}models',
        ),
        _manifest = File(
          '${supportDirectory.path}${Platform.pathSeparator}models'
          '${Platform.pathSeparator}catalog.json',
        );

  static OnDeviceModelCatalog? _instance;

  static OnDeviceModelCatalog get instance => _instance ??
      (throw StateError('OnDeviceModelCatalog.initialize must run before app startup.'));

  static Future<OnDeviceModelCatalog> initialize({Directory? supportDirectory}) async {
    final support = supportDirectory ?? await _resolveSupportDirectory();
    await support.create(recursive: true);
    final catalog = OnDeviceModelCatalog._(support);
    await catalog.modelsDirectory.create(recursive: true);
    await catalog._loadManifest();
    await catalog._installGrammarAsset();
    _instance = catalog;
    return catalog;
  }

  final Directory supportDirectory;
  final Directory modelsDirectory;
  final File _manifest;
  final Map<OnDeviceModelId, ModelInstallRecord> _records =
      <OnDeviceModelId, ModelInstallRecord>{};

  Map<OnDeviceModelId, ModelInstallRecord> get records =>
      Map<OnDeviceModelId, ModelInstallRecord>.unmodifiable(_records);

  String get grammarPath =>
      '${supportDirectory.path}${Platform.pathSeparator}grammar'
      '${Platform.pathSeparator}whiteboard.gbnf';

  String pathFor(OnDeviceModelId id) {
    final record = _records[id];
    if (record != null) {
      return '${modelsDirectory.path}${Platform.pathSeparator}${record.fileName}';
    }
    final spec = OnDeviceModelSpec.forId(id);
    return '${modelsDirectory.path}${Platform.pathSeparator}'
        '${id.name}.${spec.defaultExtension}';
  }

  /// Downloads a model file from an HTTPS URL into app-private storage.
  ///
  /// Extensions are used for file naming and a basic type allowlist only; they
  /// do not validate the model architecture or runtime compatibility. The
  /// response is streamed to a temporary file and catalogued after its size and
  /// SHA-256 have been computed. A checksum verifies integrity, not publisher
  /// identity or compatibility.
  Future<ModelInstallRecord> downloadModel(
    OnDeviceModelId id,
    Uri source, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    void Function(int downloadedBytes)? onVerifying,
  }) async {
    if (source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      throw const FormatException('Model downloads require a direct HTTPS URL.');
    }
    final spec = OnDeviceModelSpec.forId(id);
    final sourceName = source.pathSegments.isEmpty ? '' : source.pathSegments.last;
    final sourceExtension = _extension(sourceName).toLowerCase();
    final extension = sourceExtension.isEmpty ? spec.defaultExtension : sourceExtension;
    if (!spec.allowedExtensions.contains(extension)) {
      throw FormatException(
        '${spec.title} accepts '
        '${spec.allowedExtensions.map((value) => '.$value').join(', ')} URLs.',
      );
    }

    final temporary = File(
      '${modelsDirectory.path}${Platform.pathSeparator}'
      '.${id.name}-${DateTime.now().microsecondsSinceEpoch}.downloading',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      var finalUri = source;
      var request = await client.getUrl(finalUri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      var response = await request.close();
      var redirectCount = 0;
      while (response.isRedirect) {
        if (redirectCount >= 8) {
          await response.drain<void>();
          throw const FormatException('The model download redirected too many times.');
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          await response.drain<void>();
          throw const FormatException('The model download redirect did not include a destination.');
        }
        final destination = finalUri.resolve(location);
        if (destination.scheme != 'https' || destination.userInfo.isNotEmpty) {
          await response.drain<void>();
          throw const FormatException('Model download redirects must remain on HTTPS.');
        }
        await response.drain<void>();
        finalUri = destination;
        request = await client.getUrl(finalUri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
        response = await request.close();
        redirectCount++;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'Model download failed with HTTP ${response.statusCode}.',
          finalUri,
        );
      }
      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      if (contentType == 'text/html' || contentType == 'application/xhtml+xml') {
        await response.drain<void>();
        throw const FormatException(
          'The URL returned a web page, not a model file. Use a direct file-download URL.',
        );
      }
      final expectedSize = response.contentLength;
      if (expectedSize == 0) {
        await response.drain<void>();
        throw const FormatException('The model download returned an empty file.');
      }

      final output = temporary.openWrite();
      var receivedBytes = 0;
      try {
        await for (final chunk in response) {
          output.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(
            receivedBytes,
            expectedSize > 0 ? expectedSize : null,
          );
        }
        await output.flush();
      } finally {
        await output.close();
      }
      final size = await temporary.length();
      if (size <= 0 || (expectedSize > 0 && size != expectedSize)) {
        throw const FormatException('Downloaded model size did not match the server response.');
      }
      onVerifying?.call(size);
      return await _installTemporaryModel(id, temporary, extension, size);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<ModelInstallRecord> _installTemporaryModel(
    OnDeviceModelId id,
    File temporary,
    String extension,
    int size,
  ) async {
    final hash = await _sha256File(temporary.path);
    final spec = OnDeviceModelSpec.forId(id);
    final fileName = '${id.name}-$hash.${extension.isEmpty ? spec.defaultExtension : extension}';
    final destination = File(
      '${modelsDirectory.path}${Platform.pathSeparator}$fileName',
    );
    if (await destination.exists()) {
      await temporary.delete();
    } else {
      await temporary.rename(destination.path);
    }

    final old = _records[id];
    final record = ModelInstallRecord(
      id: id,
      fileName: fileName,
      sizeBytes: size,
      sha256: hash,
      importedAt: DateTime.now().toUtc(),
    );
    _records[id] = record;
    await _saveManifest();
    if (old != null && old.fileName != fileName) {
      final oldFile = File(
        '${modelsDirectory.path}${Platform.pathSeparator}${old.fileName}',
      );
      if (await oldFile.exists()) await oldFile.delete();
    }
    return record;
  }

  Future<ModelInstallRecord> verify(OnDeviceModelId id) async {
    final record = _records[id];
    if (record == null) throw StateError('${OnDeviceModelSpec.forId(id).title} is not imported.');
    final file = File('${modelsDirectory.path}${Platform.pathSeparator}${record.fileName}');
    if (!await file.exists()) throw StateError('The imported model file is missing from app storage.');
    final size = await file.length();
    if (size != record.sizeBytes) throw StateError('Model file size changed after import.');
    final digest = await _sha256File(file.path);
    if (digest != record.sha256) {
      throw StateError('Model SHA-256 does not match the import manifest.');
    }
    return record;
  }

  Future<void> remove(OnDeviceModelId id) async {
    final record = _records.remove(id);
    if (record == null) return;
    await _saveManifest();
    final file = File('${modelsDirectory.path}${Platform.pathSeparator}${record.fileName}');
    if (await file.exists()) await file.delete();
  }

  Future<void> _loadManifest() async {
    if (!await _manifest.exists()) return;
    Object? decoded;
    try {
      decoded = jsonDecode(await _manifest.readAsString());
    } on Object {
      final corrupt = File('${_manifest.path}.corrupt');
      try {
        await _manifest.rename(corrupt.path);
      } on Object {
        await _manifest.delete();
      }
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    for (final entry in decoded.entries) {
      final id = OnDeviceModelId.values.where((value) => value.name == entry.key);
      final value = entry.value;
      if (id.isEmpty || value is! Map<String, dynamic>) continue;
      final fileName = value['file_name'];
      final size = value['size_bytes'];
      final digest = value['sha256'];
      final importedAt = value['imported_at'];
      if (fileName is! String || !_isSafeFileName(fileName) ||
          size is! int || size <= 0 || digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) || importedAt is! String) {
        continue;
      }
      final date = DateTime.tryParse(importedAt);
      if (date == null) continue;
      _records[id.first] = ModelInstallRecord(
        id: id.first,
        fileName: fileName,
        sizeBytes: size,
        sha256: digest,
        importedAt: date.toUtc(),
      );
    }
  }

  Future<void> _saveManifest() async {
    final temporary = File('${_manifest.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object>{
        for (final entry in _records.entries) entry.key.name: entry.value.toJson(),
      }),
      flush: true,
    );
    await temporary.rename(_manifest.path);
  }

  Future<void> _installGrammarAsset() async {
    final file = File(grammarPath);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    final data = await rootBundle.load('assets/grammar/whiteboard.gbnf');
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  static Future<String> _sha256File(String path) => Isolate.run<String>(() async {
        final digest = await sha256.bind(File(path).openRead()).first;
        return digest.toString();
      });

  static bool _isSafeFileName(String value) =>
      value.isNotEmpty && value != '.' && value != '..' &&
      !value.contains('/') && !value.contains('\\');

  static String _extension(String fileName) {
    final index = fileName.lastIndexOf('.');
    return index < 0 || index == fileName.length - 1
        ? ''
        : fileName.substring(index + 1);
  }

  static Future<Directory> _resolveSupportDirectory() async {
    try {
      return await getApplicationSupportDirectory();
    } on Object {
      return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}edu-tutor-support',
      );
    }
  }
}
