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
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(assetPath),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return SelectableText(
            snapshot.data!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
          ).wrap();
        },
      ),
    );
  }
}

extension on Widget {
  Widget wrap() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: SingleChildScrollView(child: this),
    );
  }
}
