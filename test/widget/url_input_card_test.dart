import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';

void main() {
  testWidgets('sample URL fills the field', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: UrlInputCard(onAnalyze: _noop),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Try a sample public video'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const Key('url-input')));
    expect(field.controller?.text, contains('BigBuckBunny.mp4'));
  });
}

Future<void> _noop() async {}
