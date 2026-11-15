import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';

/// Supported local curriculum formats.
enum CurriculumDocumentFormat { pdf, markdown, text }

final class PdfTextPage {
  const PdfTextPage({required this.pageIndex, required this.text});

  final int pageIndex;
  final String text;
}

abstract interface class CurriculumPdfTextExtractor {
  List<PdfTextPage> extract(Uint8List pdfBytes);
}

/// Small dependency-free extractor for text-layer PDFs. It reads literal text
/// operators in page content streams (including FlateDecode streams); scanned
/// image-only pages require OCR and return no text.
final class BasicPdfTextExtractor implements CurriculumPdfTextExtractor {
  const BasicPdfTextExtractor();

  @override
  List<PdfTextPage> extract(Uint8List pdfBytes) {
    final source = latin1.decode(pdfBytes, allowInvalid: true);
    final pageStarts = RegExp(r'/Type\s*/Page\b').allMatches(source)
        .map((match) => match.start)
        .toList(growable: false);
    final streamPattern = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
    final byPage = <int, StringBuffer>{};
    for (final match in streamPattern.allMatches(source)) {
      final beforeStream = source.substring(mathMax(0, match.start - 256), match.start);
      var content = match.group(1) ?? '';
      if (beforeStream.contains('/FlateDecode')) {
        try {
          final compressed = Uint8List.fromList(latin1.encode(content));
          content = latin1.decode(ZLibDecoder().convert(compressed), allowInvalid: true);
        } on Object {
          try {
            final compressed = Uint8List.fromList(latin1.encode(content));
            content = latin1.decode(ZLibDecoder(raw: true).convert(compressed), allowInvalid: true);
          } on Object {
            continue;
          }
        }
      }
      final pageIndex = pageStarts.where((start) => start < match.start).length - 1;
      final index = pageIndex < 0 ? 0 : pageIndex;
      final text = _extractTextOperators(content);
      if (text.trim().isNotEmpty) {
        byPage.putIfAbsent(index, StringBuffer.new).write('$text\n');
      }
    }

    // A number of simple/uncompressed PDFs have a text stream without a page
    // object marker in the input fragment; retain that text as page zero.
    if (byPage.isEmpty) {
      final text = _extractTextOperators(source);
      if (text.trim().isNotEmpty) byPage[0] = StringBuffer(text);
    }
    return byPage.entries
        .map((entry) => PdfTextPage(pageIndex: entry.key, text: entry.value.toString().trim()))
        .toList(growable: false)
      ..sort((left, right) => left.pageIndex.compareTo(right.pageIndex));
  }

  static String _extractTextOperators(String source) {
    final output = StringBuffer();
    for (final textObject in RegExp(r'BT([\s\S]*?)ET').allMatches(source)) {
      final content = textObject.group(1) ?? '';
      var index = 0;
      while (index < content.length) {
        if (content[index] == '(') {
          final parsed = _readLiteral(content, index);
          if (parsed != null) {
            output.write(parsed.$1);
            output.write(' ');
            index = parsed.$2;
            continue;
          }
        } else if (content[index] == '<' &&
            (index + 1 >= content.length || content[index + 1] != '<')) {
          final end = content.indexOf('>', index + 1);
          if (end > index) {
            final decoded = _decodeHexText(content.substring(index + 1, end));
            if (decoded.isNotEmpty) output..write(decoded)..write(' ');
            index = end + 1;
            continue;
          }
        }
        index++;
      }
      output.write('\n');
    }
    return output.toString();
  }

  static (String, int)? _readLiteral(String source, int start) {
    var index = start + 1;
    var depth = 1;
    final bytes = <int>[];
    while (index < source.length && depth > 0) {
      final unit = source.codeUnitAt(index++);
      if (unit == 0x5c && index < source.length) {
        final escaped = source.codeUnitAt(index++);
        switch (escaped) {
          case 0x6e:
            bytes.add(0x0a);
            break;
          case 0x72:
            bytes.add(0x0d);
            break;
          case 0x74:
            bytes.add(0x09);
            break;
          case 0x62:
            bytes.add(0x08);
            break;
          case 0x66:
            bytes.add(0x0c);
            break;
          case 0x0a:
            break;
          case 0x0d:
            if (index < source.length && source.codeUnitAt(index) == 0x0a) index++;
            break;
          default:
            if (escaped >= 0x30 && escaped <= 0x37) {
              var octal = escaped - 0x30;
              var digits = 1;
              while (digits < 3 && index < source.length) {
                final next = source.codeUnitAt(index);
                if (next < 0x30 || next > 0x37) break;
                octal = octal * 8 + (next - 0x30);
                index++;
                digits++;
              }
              bytes.add(octal & 0xff);
            } else {
              bytes.add(escaped & 0xff);
            }
        }
      } else if (unit == 0x28) {
        depth++;
        bytes.add(unit);
      } else if (unit == 0x29) {
        depth--;
        if (depth > 0) bytes.add(unit);
      } else {
        bytes.add(unit & 0xff);
      }
    }
    if (depth != 0) return null;
    return (latin1.decode(bytes, allowInvalid: true), index);
  }

  static String _decodeHexText(String hex) {
    final compact = hex.replaceAll(RegExp(r'\s'), '');
    if (compact.isEmpty || compact.length.isOdd) return '';
    final bytes = <int>[];
    for (var index = 0; index < compact.length; index += 2) {
      final byte = int.tryParse(compact.substring(index, index + 2), radix: 16);
      if (byte == null) return '';
      bytes.add(byte);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      final codeUnits = <int>[];
      for (var index = 2; index + 1 < bytes.length; index += 2) {
        codeUnits.add((bytes[index] << 8) | bytes[index + 1]);
      }
      return String.fromCharCodes(codeUnits);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// Parses and indexes text-layer PDF, Markdown and plain-text study notes.
/// The embedding lifecycle is delegated to [DynamicModelOrchestrator], which
/// loads the multilingual embedding model only for this call and unloads it in
/// a `finally` block before vectors are persisted.
final class DocumentIngestionService {
  DocumentIngestionService({
    required this.modelOrchestrator,
    required this.vectorStore,
    this.pdfTextExtractor = const BasicPdfTextExtractor(),
    this.maxChunkCharacters = 1400,
    this.overlapWords = 40,
  }) {
    if (maxChunkCharacters < 100 || overlapWords < 0) {
      throw ArgumentError('Chunking limits are invalid.');
    }
  }

  final DynamicModelOrchestrator modelOrchestrator;
  final SqliteVecStore vectorStore;
  final CurriculumPdfTextExtractor pdfTextExtractor;
  final int maxChunkCharacters;
  final int overlapWords;

  Future<List<DocumentChunk>> ingest({
    required String sourceId,
    required String documentTitle,
    required String filename,
    required Uint8List bytes,
  }) async {
    if (sourceId.trim().isEmpty || documentTitle.trim().isEmpty || bytes.isEmpty) {
      throw ArgumentError('Source id, title and document bytes are required.');
    }
    final format = _formatFromFilename(filename);
    final sections = _parseSections(format, bytes, documentTitle);
    final chunks = _chunkSections(sourceId, documentTitle, sections);
    if (chunks.isEmpty) throw const FormatException('Document contains no extractable text.');

    // Embeddings are materialized only for this indexing call. The orchestrator
    // unloads its lazy model even if any document embedding throws.
    final embeddings = await modelOrchestrator.indexDocuments(
      chunks.map((chunk) => chunk.text).toList(growable: false),
    );
    if (embeddings.length != chunks.length) {
      throw StateError('Embedding model returned a different number of vectors than chunks.');
    }
    vectorStore.upsertChunks(<EmbeddedDocumentChunk>[
      for (var index = 0; index < chunks.length; index++)
        EmbeddedDocumentChunk(chunk: chunks[index], embedding: embeddings[index]),
    ]);
    return List<DocumentChunk>.unmodifiable(chunks);
  }

  static CurriculumDocumentFormat _formatFromFilename(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    return switch (extension) {
      'pdf' => CurriculumDocumentFormat.pdf,
      'md' || 'markdown' => CurriculumDocumentFormat.markdown,
      'txt' || 'text' => CurriculumDocumentFormat.text,
      _ => throw FormatException('Unsupported curriculum document format: .$extension'),
    };
  }

  List<_TextSection> _parseSections(
    CurriculumDocumentFormat format,
    Uint8List bytes,
    String title,
  ) {
    if (format == CurriculumDocumentFormat.pdf) {
      return pdfTextExtractor.extract(bytes)
          .map((page) => _TextSection(
                pageIndex: page.pageIndex,
                sectionIndex: 0,
                title: title,
                text: page.text,
              ))
          .toList(growable: false);
    }
    final source = utf8.decode(bytes, allowMalformed: true).replaceAll('\r\n', '\n');
    if (format == CurriculumDocumentFormat.text) {
      final pages = source.split('\f');
      return <_TextSection>[
        for (var page = 0; page < pages.length; page++)
          if (pages[page].trim().isNotEmpty)
            _TextSection(pageIndex: page, sectionIndex: 0, title: title, text: pages[page]),
      ];
    }

    final sections = <_TextSection>[];
    final current = StringBuffer();
    var sectionTitle = title;
    var sectionIndex = 0;
    for (final line in source.split('\n')) {
      final heading = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
      if (heading != null) {
        if (current.toString().trim().isNotEmpty) {
          sections.add(_TextSection(
            pageIndex: 0,
            sectionIndex: sectionIndex,
            title: sectionTitle,
            text: current.toString(),
          ));
        }
        sectionIndex++;
        sectionTitle = heading.group(1)!.trim();
        current.clear();
      } else {
        current.writeln(line);
      }
    }
    if (current.toString().trim().isNotEmpty) {
      sections.add(_TextSection(
        pageIndex: 0,
        sectionIndex: sectionIndex,
        title: sectionTitle,
        text: current.toString(),
      ));
    }
    if (sections.isEmpty && source.trim().isNotEmpty) {
      sections.add(_TextSection(pageIndex: 0, sectionIndex: 0, title: title, text: source));
    }
    return sections;
  }

  List<DocumentChunk> _chunkSections(
    String sourceId,
    String documentTitle,
    List<_TextSection> sections,
  ) {
    final result = <DocumentChunk>[];
    for (final section in sections) {
      final words = section.text.trim().split(RegExp(r'\s+'))
        ..removeWhere((word) => word.isEmpty);
      var offset = 0;
      var chunkIndex = 0;
      while (offset < words.length) {
        var end = offset;
        var characters = 0;
        while (end < words.length) {
          final nextLength = words[end].length + (end == offset ? 0 : 1);
          if (end > offset && characters + nextLength > maxChunkCharacters) break;
          characters += nextLength;
          end++;
        }
        final text = words.sublist(offset, end).join(' ');
        if (text.trim().isNotEmpty) {
          result.add(DocumentChunk(
            sourceId: sourceId,
            documentTitle: documentTitle,
            sectionTitle: section.title,
            pageIndex: section.pageIndex,
            sectionIndex: section.sectionIndex,
            chunkIndex: chunkIndex++,
            text: text,
          ));
        }
        if (end >= words.length) break;
        offset = mathMax(offset + 1, end - overlapWords);
      }
    }
    return result;
  }
}

final class _TextSection {
  const _TextSection({
    required this.pageIndex,
    required this.sectionIndex,
    required this.title,
    required this.text,
  });

  final int pageIndex;
  final int sectionIndex;
  final String title;
  final String text;
}

int mathMax(int left, int right) => left > right ? left : right;
