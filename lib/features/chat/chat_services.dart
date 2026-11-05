import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_status_screen.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// The recovery code is shown once. It is not stored on this device.
Future<void> showRecoveryCode(BuildContext context, String code) {
  final shown = code.trim();
  if (shown.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return AlertDialog(
        title: const Text('Recovery code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Write this down. It is shown once and replaces the previous code.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              shown,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: shown));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Recovery code copied')),
              );
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I saved it'),
          ),
        ],
      );
    },
  );
}

/// Signs in with a recovery code and returns the new session.
Future<ChatRegistration?> showRecoverAccount(BuildContext context) async {
  final username = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final result = await showDialog<ChatRegistration>(
    context: context,
    builder: (context) {
      String? problem;
      var busy = false;
      var reveal = false;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return AlertDialog(
            title: const Text('Recover account'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: username,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixText: '@',
                  ),
                ),
                TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Recovery code'),
                ),
                TextField(
                  controller: password,
                  obscureText: !reveal,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    suffixIcon: IconButton(
                      tooltip: reveal ? 'Hide password' : 'Show password',
                      onPressed: () => setSheet(() => reveal = !reveal),
                      icon: Icon(
                        reveal
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                    ),
                  ),
                ),
                if (problem != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    problem!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setSheet(() {
                          busy = true;
                          problem = null;
                        });
                        try {
                          final created = await ChatApi().recover(
                            username: username.text.trim(),
                            code: code.text.trim(),
                            password: password.text,
                          );
                          if (!context.mounted) return;
                          Navigator.pop(context, created);
                        } catch (error) {
                          setSheet(() {
                            busy = false;
                            problem = chatErrorText(error);
                          });
                        }
                      },
                child: const Text('Recover'),
              ),
            ],
          );
        },
      );
    },
  );
  username.dispose();
  code.dispose();
  password.dispose();
  return result;
}

Future<void> showChatPrivacy(BuildContext context) async {
  ChatUser? user;
  try {
    user = await ChatApi().me();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
    return;
  }
  if (!context.mounted) return;
  var online = user.onlinePrivacy;
  var seen = user.seenPrivacy;
  var photo = user.photoPrivacy;
  var receipts = user.receipts;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheet) {
          Future<void> save() async {
            try {
              await ChatApi().setPrivacy(
                online: online,
                lastSeen: seen,
                photo: photo,
                receipts: receipts,
              );
            } catch (error) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(chatErrorText(error))),
              );
            }
          }

          Widget choice(String title, String value, ValueChanged<String> onChanged) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final item in const ['everyone', 'contacts', 'nobody'])
                      ChoiceChip(
                        label: Text(_audienceLabel(item)),
                        selected: value == item,
                        onSelected: (_) {
                          setSheet(() => onChanged(item));
                          unawaited(save());
                        },
                      ),
                  ],
                ),
              ],
            );
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                const Text(
                  'Privacy',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text('People you already chat with count as contacts.'),
                choice('Online', online, (value) => online = value),
                choice('Last seen', seen, (value) => seen = value),
                choice('Profile photo', photo, (value) => photo = value),
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text('Read receipts', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('On'),
                      selected: receipts != 'nobody',
                      onSelected: (_) {
                        setSheet(() => receipts = 'everyone');
                        unawaited(save());
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Off'),
                      selected: receipts == 'nobody',
                      onSelected: (_) {
                        setSheet(() => receipts = 'nobody');
                        unawaited(save());
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Turning receipts off still clears your unread count. The other person sees delivered.',
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

String _audienceLabel(String value) {
  switch (value) {
    case 'contacts':
      return 'Contacts';
    case 'nobody':
      return 'Nobody';
    default:
      return 'Everyone';
  }
}

Future<void> showQuietHours(BuildContext context) async {
  await ChatPrefs.ensure();
  var on = ChatPrefs.quietStart >= 0 && ChatPrefs.quietEnd >= 0 && ChatPrefs.quietStart != ChatPrefs.quietEnd;
  var start = TimeOfDay(hour: ChatPrefs.quietStart < 0 ? 22 : ChatPrefs.quietStart ~/ 60, minute: ChatPrefs.quietStart < 0 ? 0 : ChatPrefs.quietStart % 60);
  var end = TimeOfDay(hour: ChatPrefs.quietEnd < 0 ? 7 : ChatPrefs.quietEnd ~/ 60, minute: ChatPrefs.quietEnd < 0 ? 0 : ChatPrefs.quietEnd % 60);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheet) {
          Future<void> save() {
            return ChatPrefs.setQuiet(
              start: on ? start.hour * 60 + start.minute : -1,
              end: on ? end.hour * 60 + end.minute : -1,
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Quiet hours', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('The tone stays off. The notice still shows, including a muted chat\'s unread count.'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('On'),
                    value: on,
                    onChanged: (value) {
                      setSheet(() => on = value);
                      unawaited(save());
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Starts'),
                    trailing: Text(start.format(context)),
                    onTap: () async {
                      final picked = await showTimePicker(context: context, initialTime: start);
                      if (picked == null) return;
                      setSheet(() => start = picked);
                      unawaited(save());
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Ends'),
                    trailing: Text(end.format(context)),
                    onTap: () async {
                      final picked = await showTimePicker(context: context, initialTime: end);
                      if (picked == null) return;
                      setSheet(() => end = picked);
                      unawaited(save());
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Future<void> showStarredMessages(BuildContext context) async {
  List<ChatStarred> rows = const [];
  try {
    rows = await ChatApi().stars();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Starred', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            ),
            if (rows.isEmpty)
              const ListTile(title: Text('No starred messages yet.'))
            else
              for (final item in rows)
                ListTile(
                  leading: const Icon(Icons.star_rounded, color: Color(0xFFF4B400)),
                  title: Text(item.text.isEmpty ? 'Message' : item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.pop(context);
                    appRouter.push(
                      '/chat/${item.thread}',
                      extra: ChatThreadTarget(
                        username: '',
                        group: item.thread.startsWith('g'),
                      ),
                    );
                  },
                ),
          ],
        ),
      );
    },
  );
}

class FolderChoice {
  const FolderChoice({this.folder, this.all = false});

  final ChatFolder? folder;
  final bool all;
}

Future<FolderChoice?> showChatFolders(
  BuildContext context, {
  List<ChatThreadSummary> chats = const [],
}) async {
  final api = ChatApi();
  List<ChatFolder> rows = const [];
  try {
    rows = await api.labels();
  } catch (error) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
    return null;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<FolderChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      var items = rows;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('Folders', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                ),
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: const Text('All chats'),
                  onTap: () => Navigator.pop(context, const FolderChoice(all: true)),
                ),
                for (final item in items)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(item.name),
                    subtitle: Text(
                      item.threads.isEmpty
                          ? 'Hold to choose chats'
                          : '${item.threads.length} chats',
                    ),
                    onLongPress: () async {
                      final selected = await _pickFolderThreads(
                        context,
                        chats,
                        item.threads,
                      );
                      if (selected == null) return;
                      try {
                        await api.saveLabel(
                          id: item.id,
                          name: item.name,
                          threads: selected,
                        );
                        final next = await api.labels();
                        setSheet(() => items = next);
                      } catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(chatErrorText(error))),
                        );
                      }
                    },
                    trailing: IconButton(
                      tooltip: 'Delete folder',
                      onPressed: () async {
                        try {
                          await api.saveLabel(id: item.id, name: item.name, delete: true);
                          setSheet(() {
                            items = [
                              for (final row in items)
                                if (row.id != item.id) row,
                            ];
                          });
                        } catch (error) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(chatErrorText(error))),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                    onTap: () => Navigator.pop(context, FolderChoice(folder: item)),
                  ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('New folder'),
                  onTap: () async {
                    final name = await _askLine(context, 'Folder name', 'Name');
                    if (name == null || name.trim().isEmpty) return;
                    try {
                      await api.saveLabel(name: name.trim());
                      final next = await api.labels();
                      setSheet(() => items = next);
                    } catch (error) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(chatErrorText(error))),
                      );
                    }
                  },
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<void> showChatDevices(BuildContext context) async {
  final api = ChatApi();
  List<ChatDeviceSession> rows = const [];
  try {
    rows = await api.deviceSessions();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      var items = rows;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('Devices', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  subtitle: Text('These are the devices signed in to this chat account.'),
                ),
                for (final item in items)
                  ListTile(
                    leading: const Icon(Icons.devices_rounded),
                    title: Text(item.name.isEmpty ? 'This device' : item.name),
                    subtitle: Text(
                      [
                        if (item.platform.isNotEmpty) item.platform,
                        if (item.current) 'This device',
                      ].join(' · '),
                    ),
                    trailing: item.current
                        ? null
                        : IconButton(
                            tooltip: 'Sign out',
                            onPressed: () async {
                              try {
                                await api.endDevice(item.id);
                                setSheet(() {
                                  items = [
                                    for (final row in items)
                                      if (row.id != item.id) row,
                                  ];
                                });
                              } catch (error) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(chatErrorText(error))),
                                );
                              }
                            },
                            icon: const Icon(Icons.logout_rounded),
                          ),
                  ),
                ListTile(
                  leading: const Icon(Icons.phonelink_erase_rounded),
                  title: const Text('Sign out of the others'),
                  onTap: () async {
                    try {
                      await api.endOtherDevices();
                      final next = await api.deviceSessions();
                      setSheet(() => items = next);
                    } catch (error) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(chatErrorText(error))),
                      );
                    }
                  },
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<void> showRotateRecovery(BuildContext context) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('New recovery code'),
        content: const Text(
          'This replaces the code you have now. The new one is shown once.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
        ],
      );
    },
  );
  if (yes != true || !context.mounted) return;
  try {
    final code = await ChatApi().rotateRecovery();
    if (!context.mounted) return;
    await showRecoveryCode(context, code);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
  }
}

Future<void> showStatuses(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (context) => const ChatStatusScreen()),
  );
}

Future<ChatPoll?> askChatPoll(BuildContext context) async {
  final question = TextEditingController();
  final choices = [TextEditingController(), TextEditingController()];
  final result = await showDialog<ChatPoll>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheet) {
          return AlertDialog(
            title: const Text('Poll'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: question, decoration: const InputDecoration(labelText: 'Question')),
                  for (var i = 0; i < choices.length; i++)
                    TextField(
                      controller: choices[i],
                      decoration: InputDecoration(labelText: 'Choice ${i + 1}'),
                    ),
                  if (choices.length < 6)
                    TextButton(
                      onPressed: () => setSheet(() => choices.add(TextEditingController())),
                      child: const Text('Add a choice'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final picked = [
                    for (final field in choices)
                      if (field.text.trim().isNotEmpty) field.text.trim(),
                  ];
                  if (question.text.trim().isEmpty || picked.length < 2) return;
                  Navigator.pop(
                    context,
                    ChatPoll(
                      question: question.text.trim(),
                      choices: picked,
                      closes: DateTime.now().add(const Duration(days: 1)),
                    ),
                  );
                },
                child: const Text('Send'),
              ),
            ],
          );
        },
      );
    },
  );
  question.dispose();
  for (final field in choices) {
    field.dispose();
  }
  return result;
}

Future<ChatCard?> askChatCard(BuildContext context) async {
  final name = TextEditingController();
  final phone = TextEditingController();
  final username = TextEditingController();
  final result = await showDialog<ChatCard>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
            TextField(
              controller: username,
              decoration: const InputDecoration(labelText: 'Username', prefixText: '@'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              if (phone.text.trim().isEmpty && username.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                ChatCard(
                  name: name.text.trim(),
                  phone: phone.text.trim(),
                  username: username.text.trim().replaceFirst(RegExp(r'^@'), ''),
                ),
              );
            },
            child: const Text('Send'),
          ),
        ],
      );
    },
  );
  name.dispose();
  phone.dispose();
  username.dispose();
  return result;
}

Future<ChatPlace?> askChatPlace(BuildContext context) async {
  final lat = TextEditingController();
  final lng = TextEditingController();
  final label = TextEditingController();
  final result = await showDialog<ChatPlace>(
    context: context,
    builder: (context) {
      String? problem;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return AlertDialog(
            title: const Text('Place'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('A map link for this spot. It does not follow anyone.'),
                TextField(controller: label, decoration: const InputDecoration(labelText: 'Label')),
                TextField(controller: lat, decoration: const InputDecoration(labelText: 'Latitude')),
                TextField(controller: lng, decoration: const InputDecoration(labelText: 'Longitude')),
                if (problem != null) Text(problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final la = double.tryParse(lat.text.trim());
                  final ln = double.tryParse(lng.text.trim());
                  if (la == null || ln == null || la < -90 || la > 90 || ln < -180 || ln > 180) {
                    setSheet(() => problem = 'Enter a latitude and longitude.');
                    return;
                  }
                  Navigator.pop(
                    context,
                    ChatPlace(lat: la, lng: ln, label: label.text.trim()),
                  );
                },
                child: const Text('Send'),
              ),
            ],
          );
        },
      );
    },
  );
  lat.dispose();
  lng.dispose();
  label.dispose();
  return result;
}

Future<DateTime?> askSendTime(BuildContext context) async {
  final now = DateTime.now().add(const Duration(minutes: 5));
  final day = await showDatePicker(
    context: context,
    firstDate: DateTime.now(),
    lastDate: DateTime.now().add(const Duration(days: 365)),
    initialDate: now,
  );
  if (day == null || !context.mounted) return null;
  final clock = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now),
  );
  if (clock == null) return null;
  return DateTime(day.year, day.month, day.day, clock.hour, clock.minute);
}

Future<void> showScheduledMessages(BuildContext context, String threadId) async {
  final api = ChatApi();
  List<ChatScheduleNote> rows = const [];
  try {
    rows = await api.schedules();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(chatErrorText(error))),
    );
    return;
  }
  if (!context.mounted) return;
  final mine = [
    for (final item in rows)
      if (threadId.isEmpty || item.thread == threadId) item,
  ];
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      var items = mine;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(title: Text('Scheduled')),
                if (items.isEmpty)
                  const ListTile(title: Text('Nothing is waiting to send.'))
                else
                  for (final item in items)
                    ListTile(
                      title: Text(item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(TimeOfDay.fromDateTime(item.sendAt.toLocal()).format(context)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Edit',
                            onPressed: () async {
                              final text = await _askLine(context, 'Edit message', 'Message', initial: item.text);
                              if (text == null || !context.mounted) return;
                              final when = await askSendTime(context);
                              if (when == null) return;
                              try {
                                await api.editSchedule(item.id, text: text, sendAt: when);
                                setSheet(() {
                                  items = [
                                    for (final row in items)
                                      if (row.id == item.id)
                                        ChatScheduleNote(
                                          id: row.id,
                                          thread: row.thread,
                                          text: text.trim(),
                                          sendAt: when,
                                        )
                                      else
                                        row,
                                  ];
                                });
                              } catch (error) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(chatErrorText(error))),
                                );
                              }
                            },
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Cancel',
                            onPressed: () async {
                              try {
                                await api.cancelSchedule(item.id);
                                setSheet(() {
                                  items = [
                                    for (final row in items)
                                      if (row.id != item.id) row,
                                  ];
                                });
                              } catch (error) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(chatErrorText(error))),
                                );
                              }
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<String?> askNotifyMode(BuildContext context, {required bool group, required String current}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text('Notifications'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'all'), child: const Text('All messages')),
          if (group)
            SimpleDialogOption(onPressed: () => Navigator.pop(context, 'mentions'), child: const Text('Mentions only')),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'silent'),
            child: const Text('Silent, still show the notice'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Mute on the chat list hides the notice for that conversation.'),
          ),
        ],
      );
    },
  );
}

Future<int?> askVanish(BuildContext context) {
  return showDialog<int>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text('Disappearing messages'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 0), child: const Text('Off')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 86400), child: const Text('24 hours')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 604800), child: const Text('7 days')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 7776000), child: const Text('90 days')),
        ],
      );
    },
  );
}

Future<List<String>?> _pickFolderThreads(
  BuildContext context,
  List<ChatThreadSummary> chats,
  List<String> current,
) {
  final picked = current.toSet();
  final direct = [
    for (final item in chats)
      if (!item.group && !item.id.startsWith('g')) item,
  ];
  return showDialog<List<String>>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheet) {
          return AlertDialog(
            title: const Text('Chats in this folder'),
            content: SizedBox(
              width: 360,
              child: direct.isEmpty
                  ? const Text('Start a chat first.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final item in direct)
                          CheckboxListTile(
                            value: picked.contains(item.id),
                            title: Text(item.label),
                            onChanged: (on) {
                              setSheet(() {
                                if (on == true) {
                                  picked.add(item.id);
                                } else {
                                  picked.remove(item.id);
                                }
                              });
                            },
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, picked.toList()),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<String?> _askLine(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

class ChatPollView extends StatelessWidget {
  const ChatPollView({
    super.key,
    required this.message,
    required this.me,
    required this.onVote,
  });

  final ChatMessage message;
  final String me;
  final void Function(int? choice, bool close) onVote;

  @override
  Widget build(BuildContext context) {
    final poll = message.poll;
    if (poll == null) return const SizedBox.shrink();
    final mine = me.isNotEmpty && message.name == me;
    final closed = poll.closed || (poll.closes != null && poll.closes!.isBefore(DateTime.now()));
    final mineVote = poll.votes[me];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(poll.question, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (var i = 0; i < poll.choices.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: InkWell(
              onTap: closed ? null : () => onVote(i, false),
              child: Row(
                children: [
                  Icon(
                    mineVote == i ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 18,
                    color: ChatUiTokens.brand,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(poll.choices[i])),
                  Text('${poll.votes.values.where((vote) => vote == i).length}'),
                ],
              ),
            ),
          ),
        if (closed) const Text('Closed', style: TextStyle(fontSize: 12)),
        if (mine && !closed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => onVote(null, true),
              child: const Text('Close poll'),
            ),
          ),
      ],
    );
  }
}

class ChatCardView extends StatelessWidget {
  const ChatCardView({super.key, required this.card});

  final ChatCard card;

  @override
  Widget build(BuildContext context) {
    final lines = [
      card.name,
      if (card.phone.isNotEmpty) card.phone,
      if (card.username.isNotEmpty) '@${card.username}',
    ];
    return Row(
      children: [
        const Icon(Icons.contact_page_outlined),
        const SizedBox(width: 8),
        Expanded(child: Text(lines.join('\n'))),
      ],
    );
  }
}

class ChatPlaceView extends StatelessWidget {
  const ChatPlaceView({super.key, required this.place, required this.onOpen});

  final ChatPlace place;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final title = place.label.isEmpty ? 'Place' : place.label;
    return InkWell(
      onTap: () => onOpen(place.link),
      child: Row(
        children: [
          const Icon(Icons.place_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$title\n${place.link}'),
          ),
        ],
      ),
    );
  }
}

class ChatCallHistory extends StatefulWidget {
  const ChatCallHistory({super.key, required this.onOpen});

  final void Function(ChatCallRecord call) onOpen;

  @override
  State<ChatCallHistory> createState() => _ChatCallHistoryState();
}

class _ChatCallHistoryState extends State<ChatCallHistory> {
  final ChatApi _api = ChatApi();
  List<ChatCallRecord> _rows = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await _api.calls();
      if (!mounted) return;
      setState(() {
        _rows = rows.reversed.toList();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = chatErrorText(error);
      });
    }
  }

  String _label(ChatCallRecord call) {
    final who = call.fromName.isEmpty ? 'Audio call' : call.fromName;
    switch (call.state) {
      case 'missed':
        return 'Missed audio call · $who';
      case 'declined':
        return 'Declined · $who';
      case 'cancelled':
        return 'Cancelled · $who';
      case 'ringing':
      case 'active':
        return 'In progress · $who';
      default:
        if (call.dur > 0) {
          final minutes = call.dur ~/ 60;
          final seconds = (call.dur % 60).toString().padLeft(2, '0');
          return 'Audio call · $minutes:$seconds';
        }
        return 'Audio call · $who';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    if (_rows.isEmpty) {
      return const Center(child: Text('No audio calls yet.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _rows.length,
        itemBuilder: (context, index) {
          final call = _rows[index];
          final missed = call.state == 'missed';
          return ListTile(
            leading: Icon(
              missed ? Icons.call_missed_rounded : Icons.call_rounded,
              color: missed ? Theme.of(context).colorScheme.error : ChatUiTokens.brand,
            ),
            title: Text(_label(call)),
            onTap: () => widget.onOpen(call),
          );
        },
      ),
    );
  }
}
