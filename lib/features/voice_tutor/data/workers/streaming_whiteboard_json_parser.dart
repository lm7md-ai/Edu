import 'dart:convert';

import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';

/// Extracts concatenated/array-contained JSON step objects from token chunks.
/// It tracks JSON string escapes and nested braces, so braces inside LaTeX or
/// quoted speech do not terminate a step early.
final class StreamingWhiteboardJsonParser {
  StreamingWhiteboardJsonParser({
    this.maxObjectCharacters = 256 * 1024,
    this.maxObjects = 512,
  }) {
    if (maxObjectCharacters < 1 || maxObjects < 1) {
      throw ArgumentError('Parser limits must be positive.');
    }
  }

  final int maxObjectCharacters;
  final int maxObjects;
  final StringBuffer _object = StringBuffer();
  int _depth = 0;
  int _objectCount = 0;
  bool _started = false;
  bool _inString = false;
  bool _escaped = false;

  List<WhiteboardSyncStep> addChunk(String chunk) {
    final completed = <WhiteboardSyncStep>[];
    for (final unit in chunk.codeUnits) {
      if (!_started) {
        if (unit == 0x7b) {
          _started = true;
          _depth = 1;
          _object.writeCharCode(unit);
        }
        continue;
      }

      _object.writeCharCode(unit);
      if (_object.length > maxObjectCharacters) {
        throw const FormatException('Whiteboard JSON step exceeds the parser limit.');
      }
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (unit == 0x5c) {
          _escaped = true;
        } else if (unit == 0x22) {
          _inString = false;
        }
        continue;
      }

      if (unit == 0x22) {
        _inString = true;
      } else if (unit == 0x7b) {
        _depth++;
      } else if (unit == 0x7d) {
        _depth--;
        if (_depth == 0) {
          completed.add(_decodeCurrentObject());
          _objectCount++;
          if (_objectCount > maxObjects) {
            throw const FormatException('Whiteboard stream contains too many steps.');
          }
          _resetObject();
        }
      }
    }
    return List<WhiteboardSyncStep>.unmodifiable(completed);
  }

  void finish() {
    if (_started || _inString || _depth != 0) {
      throw const FormatException('Whiteboard token stream ended inside a JSON step.');
    }
  }

  WhiteboardSyncStep _decodeCurrentObject() {
    final decoded = jsonDecode(_object.toString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Whiteboard step JSON must be an object.');
    }
    return WhiteboardSyncStep.fromJson(decoded);
  }

  void _resetObject() {
    _object.clear();
    _depth = 0;
    _started = false;
    _inString = false;
    _escaped = false;
  }
}
