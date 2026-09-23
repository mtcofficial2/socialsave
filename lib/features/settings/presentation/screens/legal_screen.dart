import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LegalScreen extends StatelessWidget {
  const LegalScreen({
    super.key,
    required this.title,
    required this.assetPath,
  });

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(assetPath),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final blocks = _parse(snapshot.data!);
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            itemCount: blocks.length,
            itemBuilder: (context, index) {
              final block = blocks[index];
              switch (block.kind) {
                case _BlockKind.title:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      block.text,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        letterSpacing: -0.4,
                      ),
                    ),
                  );
                case _BlockKind.meta:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Text(
                      block.text,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                case _BlockKind.heading:
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
                    child: Text(
                      block.text,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                        height: 1.3,
                      ),
                    ),
                  );
                case _BlockKind.paragraph:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      block.text,
                      textAlign: TextAlign.justify,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.55,
                        color: scheme.onSurface,
                      ),
                    ),
                  );
                case _BlockKind.bullets:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: block.items
                          .map(
                            (item) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8, right: 10),
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      item,
                                      style: TextStyle(
                                        fontSize: 15,
                                        height: 1.55,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  );
              }
            },
          );
        },
      ),
    );
  }

  static List<_Block> _parse(String raw) {
    final lines = raw.replaceAll('\r\n', '\n').split('\n');
    final blocks = <_Block>[];
    final paragraph = StringBuffer();
    final bullets = <String>[];

    void flushParagraph() {
      final text = paragraph.toString().trim();
      paragraph.clear();
      if (text.isEmpty) return;
      blocks.add(_Block.paragraph(text.replaceAll(RegExp(r'\s+'), ' ')));
    }

    void flushBullets() {
      if (bullets.isEmpty) return;
      blocks.add(_Block.bullets(List.of(bullets)));
      bullets.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        flushParagraph();
        flushBullets();
        continue;
      }
      if (line.startsWith('# ')) {
        flushParagraph();
        flushBullets();
        blocks.add(_Block.title(line.substring(2).trim()));
        continue;
      }
      if (line.startsWith('## ')) {
        flushParagraph();
        flushBullets();
        blocks.add(_Block.heading(line.substring(3).trim()));
        continue;
      }
      if (line.toLowerCase().startsWith('last updated')) {
        flushParagraph();
        flushBullets();
        blocks.add(_Block.meta(line.trim()));
        continue;
      }
      if (line.trimLeft().startsWith('- ')) {
        flushParagraph();
        bullets.add(line.trimLeft().substring(2).trim());
        continue;
      }
      flushBullets();
      if (paragraph.isNotEmpty) paragraph.write(' ');
      paragraph.write(line.trim());
    }
    flushParagraph();
    flushBullets();
    return blocks;
  }
}

enum _BlockKind { title, meta, heading, paragraph, bullets }

class _Block {
  const _Block._(this.kind, this.text, this.items);

  factory _Block.title(String text) => _Block._(_BlockKind.title, text, const []);
  factory _Block.meta(String text) => _Block._(_BlockKind.meta, text, const []);
  factory _Block.heading(String text) =>
      _Block._(_BlockKind.heading, text, const []);
  factory _Block.paragraph(String text) =>
      _Block._(_BlockKind.paragraph, text, const []);
  factory _Block.bullets(List<String> items) =>
      _Block._(_BlockKind.bullets, '', items);

  final _BlockKind kind;
  final String text;
  final List<String> items;
}
