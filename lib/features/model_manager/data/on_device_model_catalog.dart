import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
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
  });

  final OnDeviceModelId id;
  final String title;
  final String description;
  final List<String> allowedExtensions;
  final String defaultExtension;

  static const List<OnDeviceModelSpec> all = <OnDeviceModelSpec>[
    OnDeviceModelSpec(
      id: OnDeviceModelId.gemma4E4b,
      title: 'Gemma 4 E4B',
      description: 'Standalone host language model (LiteRT-LM compatible conversion).',
      allowedExtensions: <String>['litertlm', 'tflite', 'bin'],
      defaultExtension: 'litertlm',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.gemma4E2b,
      title: 'Gemma 4 E2B',
      description: 'Light Edge language model (LiteRT-LM compatible conversion).',
      allowedExtensions: <String>['litertlm', 'tflite', 'bin'],
      defaultExtension: 'litertlm',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.kokoro82m,
      title: 'Kokoro-82M',
      description: 'Local speech synthesis model.',
      allowedExtensions: <String>['litertlm', 'tflite', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.sileroVad,
      title: 'Silero VAD',
      description: 'Voice activity detection model.',
      allowedExtensions: <String>['litertlm', 'tflite', 'task', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.bgeM3,
      title: 'BGE-M3 / multilingual E5',
      description: 'Local multilingual note and query embeddings.',
      allowedExtensions: <String>['litertlm', 'tflite', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
    ),
    OnDeviceModelSpec(
      id: OnDeviceModelId.moonshineAsr,
      title: 'Moonshine / Whisper ASR (optional)',
      description: 'Arabic and English speech recognition model.',
      allowedExtensions: <String>['litertlm', 'tflite', 'task', 'onnx', 'bin'],
      defaultExtension: 'litertlm',
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
/// Imports stream into a temporary file, compute SHA-256, then atomically move
/// into the models directory and update the manifest. A checksum proves file
/// integrity only; it does not prove that a vendor runtime accepts the model.
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

  Future<ModelInstallRecord> importModel(
    OnDeviceModelId id,
    PlatformFile selectedFile,
  ) async {
    final spec = OnDeviceModelSpec.forId(id);
    final extension = (selectedFile.extension ?? _extension(selectedFile.name)).toLowerCase();
    if (!spec.allowedExtensions.contains(extension)) {
      throw FormatException(
        '${spec.title} accepts ${spec.allowedExtensions.map((value) => '.$value').join(', ')} files.',
      );
    }
    if (selectedFile.size <= 0) throw const FormatException('The selected model file is empty.');

    final temporary = File(
      '${modelsDirectory.path}${Platform.pathSeparator}'
      '.${id.name}-${DateTime.now().microsecondsSinceEpoch}.importing',
    );
    try {
      final output = temporary.openWrite();
      try {
        final source = selectedFile.readStream ??
            (selectedFile.path == null ? null : File(selectedFile.path!).openRead());
        if (source != null) {
          await output.addStream(source);
        } else if (selectedFile.bytes != null) {
          output.add(selectedFile.bytes!);
        } else {
          throw const FormatException('The selected file cannot be read by this device.');
        }
        await output.flush();
      } finally {
        await output.close();
      }

      final size = await temporary.length();
      if (size <= 0 || size != selectedFile.size) {
        throw const FormatException('Imported model size did not match the selected file.');
      }
      final hash = await _sha256File(temporary.path);
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
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
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
