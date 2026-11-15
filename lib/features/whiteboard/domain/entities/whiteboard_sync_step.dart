import 'package:meta/meta.dart';

/// Operations a tutor may ask the canonical whiteboard to render.
enum WhiteboardOperation {
  drawNode('draw_node'),
  drawArrow('draw_arrow'),
  writeMath('write_math'),
  highlight('highlight'),
  clear('clear');

  const WhiteboardOperation(this.wireName);

  final String wireName;

  static WhiteboardOperation parse(Object? value) {
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    throw FormatException('Unknown whiteboard operation: $value');
  }
}

/// Visual treatment of a whiteboard action.
enum WhiteboardStyle {
  primary('primary'),
  accent('accent'),
  warning('warning'),
  dashed('dashed');

  const WhiteboardStyle(this.wireName);

  final String wireName;

  static WhiteboardStyle parse(Object? value) {
    for (final style in values) {
      if (style.wireName == value) return style;
    }
    throw FormatException('Unknown whiteboard style: $value');
  }
}

/// One validated drawing/edit operation in normalized board coordinates.
///
/// Coordinates are fractions of the board's canonical width and height.
/// Geometry and operation-specific requirements are checked at construction
/// and again when decoding untrusted JSON.
@immutable
final class WhiteboardAction {
  factory WhiteboardAction({
    required WhiteboardOperation operation,
    String? targetId,
    double? x,
    double? y,
    double? endX,
    double? endY,
    String? content,
    WhiteboardStyle? style = WhiteboardStyle.primary,
  }) {
    final action = WhiteboardAction._(
      operation: operation,
      targetId: targetId,
      x: x,
      y: y,
      endX: endX,
      endY: endY,
      content: content,
      style: style,
    );
    action._validate();
    return action;
  }

  factory WhiteboardAction.clear({String? targetId}) {
    final action = WhiteboardAction._(
      operation: WhiteboardOperation.clear,
      targetId: targetId,
      x: null,
      y: null,
      endX: null,
      endY: null,
      content: null,
      style: null,
    );
    action._validate();
    return action;
  }

  const WhiteboardAction._({
    required this.operation,
    required this.targetId,
    required this.x,
    required this.y,
    required this.endX,
    required this.endY,
    required this.content,
    required this.style,
  });

  static const int maxTargetIdLength = 128;
  static const int maxContentLength = 4096;

  final WhiteboardOperation operation;
  final String? targetId;
  final double? x;
  final double? y;
  final double? endX;
  final double? endY;
  final String? content;
  final WhiteboardStyle? style;

  void _validate() {
    if (targetId != null &&
        (targetId!.trim().isEmpty || targetId!.length > maxTargetIdLength)) {
      throw ArgumentError.value(targetId, 'targetId', 'Invalid target identifier.');
    }
    if (content != null && content!.length > maxContentLength) {
      throw ArgumentError.value(content, 'content', 'Content is too long.');
    }

    _validateCoordinatePair(x, y, 'x/y');
    _validateCoordinatePair(endX, endY, 'endX/endY');
    for (final coordinate in <double?>[x, y, endX, endY]) {
      if (coordinate != null &&
          (!coordinate.isFinite || coordinate < 0 || coordinate > 1)) {
        throw ArgumentError.value(
          coordinate,
          'coordinate',
          'Coordinates must be finite normalized values from 0.0 to 1.0.',
        );
      }
    }

    final hasStart = x != null;
    final hasEnd = endX != null;
    switch (operation) {
      case WhiteboardOperation.drawNode:
        _requireTarget();
        _requireStart();
        _requireContent();
        if (hasEnd) throw ArgumentError('draw_node does not accept end coordinates.');
        _requireStyle();
        break;
      case WhiteboardOperation.drawArrow:
        _requireTarget();
        _requireStart();
        _requireEnd();
        _requireStyle();
        break;
      case WhiteboardOperation.writeMath:
        _requireTarget();
        _requireStart();
        _requireContent();
        if (hasEnd) throw ArgumentError('write_math does not accept end coordinates.');
        _requireStyle();
        break;
      case WhiteboardOperation.highlight:
        _requireTarget();
        _requireStart();
        _requireEnd();
        _requireStyle();
        break;
      case WhiteboardOperation.clear:
        if (hasStart || hasEnd || content != null || style != null) {
          throw ArgumentError('clear accepts only an optional targetId.');
        }
        break;
    }
  }

  void _requireTarget() {
    if (targetId == null) throw ArgumentError('$operation requires targetId.');
  }

  void _requireStart() {
    if (x == null) throw ArgumentError('$operation requires x and y.');
  }

  void _requireEnd() {
    if (endX == null) throw ArgumentError('$operation requires endX and endY.');
  }

  void _requireContent() {
    if (content == null || content!.trim().isEmpty) {
      throw ArgumentError('$operation requires non-empty content.');
    }
  }

  void _requireStyle() {
    if (style == null) throw ArgumentError('$operation requires a style.');
  }

  static void _validateCoordinatePair(double? first, double? second, String name) {
    if ((first == null) != (second == null)) {
      throw ArgumentError('$name must be provided together.');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'op': operation.wireName,
        'target_id': targetId,
        'x': x,
        'y': y,
        'end_x': endX,
        'end_y': endY,
        'content': content,
        'style': style?.wireName,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WhiteboardAction &&
          operation == other.operation &&
          targetId == other.targetId &&
          x == other.x &&
          y == other.y &&
          endX == other.endX &&
          endY == other.endY &&
          content == other.content &&
          style == other.style;

  @override
  int get hashCode => Object.hash(
        operation,
        targetId,
        x,
        y,
        endX,
        endY,
        content,
        style,
      );

  factory WhiteboardAction.fromJson(Map<String, dynamic> json) {
    try {
      return WhiteboardAction(
        operation: WhiteboardOperation.parse(json['op']),
        targetId: _optionalString(json['target_id'], 'target_id'),
        x: _optionalNumber(json['x'], 'x'),
        y: _optionalNumber(json['y'], 'y'),
        endX: _optionalNumber(json['end_x'], 'end_x'),
        endY: _optionalNumber(json['end_y'], 'end_y'),
        content: _optionalString(json['content'], 'content'),
        style: json['style'] == null ? null : WhiteboardStyle.parse(json['style']),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid whiteboard action: ${error.message}');
    }
  }
}

/// Immutable tutor command for one speech/whiteboard step.
///
/// The step id is limited to uint32 because the companion audio-frame protocol
/// carries it in a four-byte header. Actions use a fixed JSON representation
/// with explicit `null` values for fields not applicable to an operation.
@immutable
final class WhiteboardSyncStep {
  WhiteboardSyncStep({
    required this.stepId,
    required this.speechText,
    required List<WhiteboardAction> actions,
  }) : actions = List<WhiteboardAction>.unmodifiable(actions) {
    _validate();
  }

  static const int maxStepId = 0xffffffff;
  static const int maxSpeechTextLength = 16000;
  static const int maxActions = 512;

  final int stepId;
  final String speechText;
  final List<WhiteboardAction> actions;

  void _validate() {
    if (stepId < 0 || stepId > maxStepId) {
      throw RangeError.range(stepId, 0, maxStepId, 'stepId');
    }
    if (speechText.length > maxSpeechTextLength) {
      throw ArgumentError.value(
        speechText.length,
        'speechText.length',
        'Speech text exceeds the protocol limit.',
      );
    }
    if (actions.length > maxActions) {
      throw ArgumentError.value(
        actions.length,
        'actions.length',
        'A step cannot contain more than $maxActions actions.',
      );
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'step_id': stepId,
        'speech_text': speechText,
        'actions': actions.map((action) => action.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WhiteboardSyncStep &&
          stepId == other.stepId &&
          speechText == other.speechText &&
          _listEquals(actions, other.actions);

  @override
  int get hashCode => Object.hash(stepId, speechText, Object.hashAll(actions));

  factory WhiteboardSyncStep.fromJson(Map<String, dynamic> json) {
    final rawStepId = json['step_id'];
    final rawSpeechText = json['speech_text'];
    final rawActions = json['actions'];

    if (rawStepId is! int ||
        rawSpeechText is! String ||
        rawActions is! List<dynamic>) {
      throw const FormatException(
        'WhiteboardSyncStep requires integer step_id, string speech_text, and actions array.',
      );
    }
    if (rawActions.length > maxActions) {
      throw const FormatException('WhiteboardSyncStep contains too many actions.');
    }

    final actions = <WhiteboardAction>[];
    for (final rawAction in rawActions) {
      if (rawAction is! Map<String, dynamic>) {
        throw const FormatException('Each whiteboard action must be a JSON object.');
      }
      actions.add(WhiteboardAction.fromJson(rawAction));
    }

    try {
      return WhiteboardSyncStep(
        stepId: rawStepId,
        speechText: rawSpeechText,
        actions: actions,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid WhiteboardSyncStep: ${error.message}');
    }
  }
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String? _optionalString(Object? value, String fieldName) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$fieldName must be a string or null.');
  return value;
}

double? _optionalNumber(Object? value, String fieldName) {
  if (value == null) return null;
  if (value is! num) throw FormatException('$fieldName must be a number or null.');
  return value.toDouble();
}
