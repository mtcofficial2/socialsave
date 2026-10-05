import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';

Future<void> showVideoSummary(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  String? author,
  String? sourceUrl,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Writing a short summary…')),
        ],
      ),
    ),
  );
  String message;
  try {
    message = await ref.read(mediaRepositoryProvider).summarize(
          title: title,
          author: author,
          sourceUrl: sourceUrl,
        );
  } on AppException catch (error) {
    message = error.message;
  } catch (_) {
    message = 'A summary could not be written. Try again later.';
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Summary'),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}
