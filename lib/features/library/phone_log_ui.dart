import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/features/library/usb_link.dart';

/// Opens the plain-English log of every Social Save phone on the USB cable.
Future<void> showPhoneLog(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const FractionallySizedBox(
      heightFactor: 0.72,
      child: PhoneLogSheet(),
    ),
  );
}

class PhoneLogSheet extends StatefulWidget {
  const PhoneLogSheet({super.key});

  @override
  State<PhoneLogSheet> createState() => _PhoneLogSheetState();
}

class _PhoneLogSheetState extends State<PhoneLogSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(UsbLink.refreshDeviceLogs());
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(UsbLink.refreshDeviceLogs());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<PluggedPhoneLog>>(
      valueListenable: UsbLink.deviceLogs,
      builder: (context, phones, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Phone log', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'The apps this phone used, and what it did in Social Save.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: phones.isEmpty
                    ? const Align(
                        alignment: Alignment.topLeft,
                        child: Text('Plug in a phone with Social Save open and USB debugging allowed.'),
                      )
                    : ListView(
                        children: [
                          for (final phone in phones) ...[
                            Text(phone.name, style: theme.textTheme.titleMedium),
                            if (phone.problem.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(phone.problem),
                            ],
                            if (phone.lines.isEmpty && phone.problem.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 4, bottom: 12),
                                child: Text('This phone has not written a log yet.'),
                              ),
                            for (final line in phone.lines.reversed)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text('${_when(line.at)}  ${line.text}'),
                              ),
                            const SizedBox(height: 16),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _when(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final half = time.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $half';
}
