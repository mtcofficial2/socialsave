import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as im;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/media_store_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';

/// Saves this person's profile photo. The sentence is what to show afterwards.
Future<String> downloadChatProfilePhoto(
  String username, {
  int photoRev = 0,
}) async {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim();
  if (name.isEmpty) return 'No profile photo to download.';
  Uint8List? bytes;
  if (photoRev > 0) bytes = await ChatPhotos.fetch(name, photoRev);
  bytes ??= ChatPhotos.anyCached(name);
  if (bytes == null || bytes.isEmpty) {
    try {
      bytes = await ChatApi().photo(name);
    } catch (_) {
      bytes = null;
    }
  }
  if (bytes == null || bytes.isEmpty) {
    return 'No profile photo to download.';
  }
  ChatPhotos.remember(name, photoRev > 0 ? photoRev : 1, bytes);
  final png = bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final ext = png ? 'png' : 'jpg';
  final mime = png ? 'image/png' : 'image/jpeg';
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
  final fileName = '${safe.isEmpty ? 'profile' : safe}-profile.$ext';
  try {
    if (Plat.isAndroid) {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'chat-profile-$fileName'));
      await file.writeAsBytes(bytes, flush: true);
      final saved = await MediaStoreService().publishToDownloads(
        sourcePath: file.path,
        fileName: fileName,
        mimeType: mime,
      );
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      if (saved == null || saved.isEmpty) {
        return 'That photo could not be saved.';
      }
      return 'Profile photo saved to Downloads.';
    }
    final folder = await DownloadPathService().resolveDirectory(
      DownloadLocation.publicDownloads,
    );
    await File(p.join(folder.path, fileName)).writeAsBytes(bytes, flush: true);
    if (Plat.isWindows) return 'Profile photo saved to Documents.';
    return 'Profile photo saved.';
  } catch (_) {
    return 'That photo could not be saved.';
  }
}

/// The person behind a username. Another person's phone or email is never shown.
Future<void> showChatProfile(
  BuildContext context, {
  required String username,
  String contact = '',
  String seenName = '',
  int photoRev = 0,
  DateTime? lastSeen,
  bool online = false,
  void Function(int photoRev)? onPhoto,
  void Function()? onLogOut,
  Future<String> Function(String name)? onSeenName,
  bool blocked = false,
  Future<bool> Function(bool on)? onBlock,
}) {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim();
  final mine = contact.trim().isNotEmpty;
  var shown = seenName.trim();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      var rev = photoRev;
      var busy = false;
      var blockedNow = blocked;
      var looked = false;
      String? problem;
      final presence = chatPresenceLabel(
        lastSeen,
        online,
        DateTime.now(),
        lastSeen == null
            ? ''
            : TimeOfDay.fromDateTime(lastSeen.toLocal()).format(context),
      );
      return StatefulBuilder(
        builder: (context, setSheet) {
          if (!mine && rev <= 0 && !looked && name.isNotEmpty) {
            looked = true;
            ChatApi().photo(name).then((bytes) {
              if (bytes == null || bytes.isEmpty || !context.mounted) return;
              ChatPhotos.remember(name, 1, bytes);
              setSheet(() => rev = 1);
            }).catchError((_) {});
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChatFace(
                    name: name.isEmpty ? '?' : name,
                    size: 96,
                    photoRev: rev,
                    online: !mine && online,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    shown.isNotEmpty
                        ? shown
                        : (name.isEmpty ? 'Chat' : name),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  if (!mine && shown.isNotEmpty && shown != name) ...[
                    const SizedBox(height: 4),
                    Text(
                      '@$name',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (!mine && presence.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      presence,
                      style: TextStyle(
                        color: online
                            ? const Color(0xFF25D366)
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    mine
                        ? 'This is your Social Save profile'
                        : 'Social Save profile',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  if (mine) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Registered with ${contact.trim()}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (mine)
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                final next = await _pickChatPhoto(name);
                                if (!context.mounted) return;
                                if (next != null) {
                                  rev = next;
                                  onPhoto?.call(next);
                                }
                                setSheet(() => busy = false);
                              } catch (error) {
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  problem = error is StateError
                                      ? 'Choose a JPEG or PNG photo.'
                                      : chatErrorText(error);
                                });
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.photo_camera_rounded),
                      label: const Text('Change photo'),
                    ),
                  if (!mine && onSeenName != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              final next = await _askProfileName(
                                context,
                                username: name,
                                current: shown,
                              );
                              if (next == null || !context.mounted) return;
                              final typed = next.trim();
                              final send = typed == name ? '' : typed;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                final saved = await onSeenName(send);
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  shown = saved.trim();
                                });
                              } catch (error) {
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: const Icon(Icons.edit_rounded),
                      label: const Text('Edit name'),
                    ),
                  ],
                  if (!mine && onBlock != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              final block = onBlock;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                final next = await block(!blockedNow);
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  blockedNow = next;
                                });
                              } catch (error) {
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: Icon(
                        blockedNow
                            ? Icons.lock_open_rounded
                            : Icons.block_rounded,
                      ),
                      label: Text(blockedNow ? 'Unblock' : 'Block'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                await ChatApi().reportUser(username);
                                if (!context.mounted) return;
                                setSheet(() => busy = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Report sent')),
                                );
                              } catch (error) {
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Report'),
                    ),
                  ],
                  if (mine) const SizedBox(height: 8),
                  if (mine && onLogOut != null) ...[
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onLogOut();
                      },
                      icon: Icon(Icons.logout_rounded, color: scheme.error),
                      label: Text(
                        'Log out',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: busy || name.isEmpty
                        ? null
                        : () async {
                            setSheet(() {
                              busy = true;
                              problem = null;
                            });
                            final text = await downloadChatProfilePhoto(
                              name,
                              photoRev: rev,
                            );
                            if (!context.mounted) return;
                            setSheet(() => busy = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(text)),
                            );
                          },
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Download photo'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: '@$name'));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Username copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy username'),
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      problem!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Future<String?> _askProfileName(
  BuildContext context, {
  required String username,
  required String current,
}) {
  final controller = TextEditingController(
    text: current.trim().isEmpty ? username : current.trim(),
  );
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Name you see'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: InputDecoration(
            labelText: 'Name you see',
            helperText: 'Leave blank to show @$username',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

Future<int?> _pickChatPhoto(String username) async {
  final picked = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
    ],
  );
  if (picked == null) return null;
  final raw = await picked.readAsBytes();
  final fitted = await fitChatPhoto(raw);
  final rev = await ChatApi().setPhoto(fitted);
  ChatPhotos.remember(username, rev, fitted);
  return rev;
}

/// Members, the join code, and leave. Add, rename, and the admin tools are
/// for an admin. The server rejects them for anyone else.
Future<void> showChatGroup(
  BuildContext context, {
  required String name,
  required String code,
  required List<String> members,
  required Future<String> Function(String name) onRename,
  required Future<List<String>> Function(String username) onAdd,
  required Future<void> Function() onLeave,
  String about = '',
  String rules = '',
  bool announce = false,
  bool canManage = true,
  String owner = '',
  List<String> admins = const [],
  Future<void> Function(String username, {required bool on})? onAdmin,
  Future<void> Function(String username)? onRemove,
  Future<void> Function(String username)? onTransfer,
  Future<String> Function(int hours)? onInvite,
  Future<void> Function({String? about, String? rules, bool? announce})? onInfo,
}) {
  var shown = name.trim();
  var people = List<String>.from(members);
  var aboutText = about.trim();
  var rulesText = rules.trim();
  var announceOn = announce;
  var adminNames = List<String>.from(admins);
  var ownerName = owner.trim();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      var busy = false;
      String? problem;
      return StatefulBuilder(
        builder: (context, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChatFace(name: shown.isEmpty ? 'Group' : shown, size: 96),
                  const SizedBox(height: 16),
                  Text(
                    shown.isEmpty ? 'Group' : shown,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    people.length == 1 ? '1 person' : '${people.length} people',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (aboutText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(aboutText, textAlign: TextAlign.center),
                  ],
                  if (rulesText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      rulesText,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (announceOn)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Only admins can post'),
                    ),
                  if (code.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Code $code',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (people.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final member in people)
                            ListTile(
                              dense: true,
                              minTileHeight: 40,
                              leading: ChatFace(name: member, size: 32),
                              title: Text('@$member'),
                              subtitle: member == ownerName || adminNames.contains(member)
                                  ? const Text('Admin')
                                  : null,
                              trailing: !canManage ||
                                      member == ownerName ||
                                      (onAdmin == null &&
                                          onRemove == null &&
                                          onTransfer == null)
                                  ? const Icon(Icons.chevron_right_rounded)
                                  : PopupMenuButton<String>(
                                      onSelected: (value) async {
                                        setSheet(() {
                                          busy = true;
                                          problem = null;
                                        });
                                        try {
                                          if (value == 'admin' && onAdmin != null) {
                                            final on = !adminNames.contains(member);
                                            await onAdmin(member, on: on);
                                            setSheet(() {
                                              busy = false;
                                              adminNames = [
                                                for (final name in adminNames)
                                                  if (name != member) name,
                                                if (on) member,
                                              ];
                                            });
                                            return;
                                          }
                                          if (value == 'remove' && onRemove != null) {
                                            await onRemove(member);
                                            setSheet(() {
                                              busy = false;
                                              people = [
                                                for (final name in people)
                                                  if (name != member) name,
                                              ];
                                            });
                                            return;
                                          }
                                          if (value == 'transfer' && onTransfer != null) {
                                            await onTransfer(member);
                                            setSheet(() {
                                              busy = false;
                                              ownerName = member;
                                              if (!adminNames.contains(owner)) {
                                                adminNames = [...adminNames, owner];
                                              }
                                            });
                                            return;
                                          }
                                          setSheet(() => busy = false);
                                        } catch (error) {
                                          setSheet(() {
                                            busy = false;
                                            problem = chatErrorText(error);
                                          });
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        if (onAdmin != null && member != ownerName)
                                          PopupMenuItem(
                                            value: 'admin',
                                            child: Text(
                                              adminNames.contains(member)
                                                  ? 'Dismiss admin'
                                                  : 'Make admin',
                                            ),
                                          ),
                                        if (onTransfer != null && member != ownerName)
                                          const PopupMenuItem(
                                            value: 'transfer',
                                            child: Text('Make owner'),
                                          ),
                                        if (onRemove != null && member != ownerName)
                                          const PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Remove'),
                                          ),
                                      ],
                                    ),
                              onTap: () => showChatProfile(
                                context,
                                username: member,
                                onBlock: (on) =>
                                    ChatApi().block(member, on: on),
                                onSeenName: (value) =>
                                    ChatApi().setSeenName(member, value),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (canManage && onInfo != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              final next = await _askGroupName(context, aboutText);
                              if (next == null || !context.mounted) return;
                              final savedInfo = onInfo;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                await savedInfo(about: next.trim());
                                setSheet(() {
                                  busy = false;
                                  aboutText = next.trim();
                                });
                              } catch (error) {
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: const Icon(Icons.info_outline_rounded),
                      label: const Text('Description'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              final next = await _askGroupName(context, rulesText);
                              if (next == null || !context.mounted) return;
                              final savedInfo = onInfo;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                await savedInfo(rules: next.trim());
                                setSheet(() {
                                  busy = false;
                                  rulesText = next.trim();
                                });
                              } catch (error) {
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: const Icon(Icons.rule_rounded),
                      label: const Text('Rules'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Announcement mode'),
                      subtitle: const Text('Only admins can post'),
                      value: announceOn,
                      onChanged: busy
                          ? null
                          : (value) async {
                              final savedInfo = onInfo;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                await savedInfo(announce: value);
                                setSheet(() {
                                  busy = false;
                                  announceOn = value;
                                });
                              } catch (error) {
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                    ),
                  ],
                  if (canManage && onInvite != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              final savedInvite = onInvite;
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                final next = await savedInvite(168);
                                if (!context.mounted) return;
                                setSheet(() => busy = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      next.isEmpty
                                          ? 'Invite link replaced'
                                          : 'New code $next, expires in 7 days',
                                    ),
                                  ),
                                );
                              } catch (error) {
                                setSheet(() {
                                  busy = false;
                                  problem = chatErrorText(error);
                                });
                              }
                            },
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('New invite, 7 days'),
                    ),
                  ],
                  if (canManage) ...[
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: busy
                        ? null
                        : () async {
                            final username = await _askUsername(context);
                            if (username == null || !context.mounted) return;
                            setSheet(() {
                              busy = true;
                              problem = null;
                            });
                            try {
                              final next = await onAdd(username);
                              if (!context.mounted) return;
                              setSheet(() {
                                busy = false;
                                people = next;
                              });
                            } catch (error) {
                              if (!context.mounted) return;
                              setSheet(() {
                                busy = false;
                                problem = chatErrorText(error);
                              });
                            }
                          },
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Add person'),
                  ),
                  const SizedBox(height: 8),
                  if (code.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Group code copied')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy code'),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: busy
                        ? null
                        : () async {
                            final next = await _askGroupName(context, shown);
                            if (next == null || !context.mounted) return;
                            setSheet(() {
                              busy = true;
                              problem = null;
                            });
                            try {
                              final saved = await onRename(next.trim());
                              if (!context.mounted) return;
                              setSheet(() {
                                busy = false;
                                if (saved.trim().isNotEmpty) shown = saved.trim();
                              });
                            } catch (error) {
                              if (!context.mounted) return;
                              setSheet(() {
                                busy = false;
                                problem = chatErrorText(error);
                              });
                            }
                          },
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Rename group'),
                  ),
                  ],
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  title: const Text('Leave group'),
                                  content: const Text(
                                    'You will stop seeing messages in this group.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Leave'),
                                    ),
                                  ],
                                );
                              },
                            );
                            if (yes != true || !context.mounted) return;
                            setSheet(() {
                              busy = true;
                              problem = null;
                            });
                            try {
                              await onLeave();
                              if (!context.mounted) return;
                              Navigator.pop(context);
                            } catch (error) {
                              if (!context.mounted) return;
                              setSheet(() {
                                busy = false;
                                problem = chatErrorText(error);
                              });
                            }
                          },
                    icon: Icon(Icons.logout_rounded, color: scheme.error),
                    label: Text(
                      'Leave group',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      problem!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
            ),
          );
        },
      );
    },
  );
}

Future<String?> _askUsername(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Add person'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          autocorrect: false,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixText: '@',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose).then((value) {
    final handle = value?.trim().replaceFirst(RegExp(r'^@'), '') ?? '';
    if (handle.isEmpty) return null;
    return handle;
  });
}

Future<String?> _askGroupName(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Group name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

bool _jpegOrPng(Uint8List raw) {
  if (raw.length >= 3 && raw[0] == 0xFF && raw[1] == 0xD8 && raw[2] == 0xFF) {
    return true;
  }
  return raw.length >= 8 &&
      raw[0] == 0x89 &&
      raw[1] == 0x50 &&
      raw[2] == 0x4E &&
      raw[3] == 0x47;
}

Uint8List _fitChatJpeg(Uint8List raw) {
  final decoded = im.decodeImage(raw);
  if (decoded == null) throw StateError('Choose a JPEG or PNG photo.');
  var current = decoded;
  for (final width in [1280, 960, 640, 480]) {
    if (current.width > width) current = im.copyResize(current, width: width);
    final jpg = Uint8List.fromList(im.encodeJpg(current, quality: 74));
    if (jpg.length <= 512 * 1024) return jpg;
  }
  throw StateError('Choose a JPEG or PNG photo.');
}

/// A conversation photo, small enough to hand to the other phone.
Future<Uint8List> fitChatImage(Uint8List raw) async {
  if (raw.length <= 512 * 1024 && _jpegOrPng(raw)) return raw;
  try {
    return await compute(_fitChatJpeg, raw);
  } catch (error) {
    if (error is StateError) rethrow;
  }
  Object? last;
  for (final width in [1280, 960, 640, 256]) {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: width);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) continue;
      final bytes = data.buffer.asUint8List();
      if (bytes.length <= 512 * 1024) return bytes;
    } catch (error) {
      last = error;
    }
  }
  throw last ?? StateError('Choose a JPEG or PNG photo.');
}

/// A small PNG the chat server will accept.
Future<Uint8List> fitChatPhoto(Uint8List raw) async {
  Object? last;
  for (final width in [256, 160, 96]) {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: width);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) continue;
      final bytes = data.buffer.asUint8List();
      if (bytes.length <= 512 * 1024) return bytes;
    } catch (error) {
      last = error;
    }
  }
  throw last ?? StateError('Choose a JPEG or PNG photo.');
}
