import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/shared/routing/app_router.dart';

const _callConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

/// Microphone audio for one call. Binary socket frames stay photos.
class ChatCallMedia {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  final List<MediaStream> _remote = [];
  final List<RTCIceCandidate> _waiting = [];
  bool _remoteReady = false;

  Future<void> _open(void Function(String candidate) onIce) async {
    if (_pc != null) return;
    if (Plat.isAndroid || Plat.isIOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted && !status.isLimited) {
        throw StateError('Allow the microphone to make an audio call.');
      }
    }
    if (Plat.isAndroid) {
      try {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
      } catch (_) {}
    }
    final pc = await createPeerConnection(_callConfig);
    _pc = pc;
    pc.onTrack = (event) {
      for (final stream in event.streams) {
        if (!_remote.contains(stream)) _remote.add(stream);
      }
      if (event.track.kind == 'audio') event.track.enabled = true;
    };
    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line == null || line.isEmpty) return;
      final encoded = jsonEncode({
        'candidate': line,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
      if (encoded.length > 2000) return;
      onIce(encoded);
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
        ChatCalls.instance.noteLink(up: true);
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        ChatCalls.instance.noteLink(up: false);
      }
    };
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    _local = stream;
    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  Future<String> _localSdp(RTCSessionDescription desc) async {
    final current = await _pc?.getLocalDescription();
    final raw = current?.sdp;
    final ready = callSdp(
      raw != null && raw.trim().isNotEmpty ? raw : (desc.sdp ?? ''),
    );
    if (ready.isEmpty) {
      throw StateError('The call could not start. Try again.');
    }
    return ready;
  }

  Future<void> _applyRemote(RTCPeerConnection pc, String sdp, String type) async {
    final ready = callSdp(sdp);
    if (ready.isEmpty) {
      throw StateError('The call offer did not arrive. Ask them to call again.');
    }
    await pc.setRemoteDescription(RTCSessionDescription(ready, type));
    _remoteReady = true;
    await _flush();
  }

  Future<String> offer(void Function(String candidate) onIce) async {
    await _open(onIce);
    final desc = await _pc!.createOffer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(desc);
    return _localSdp(desc);
  }

  Future<String> answer(
    String offer,
    void Function(String candidate) onIce,
  ) async {
    await _open(onIce);
    await _applyRemote(_pc!, offer, 'offer');
    final desc = await _pc!.createAnswer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(desc);
    return _localSdp(desc);
  }

  Future<void> acceptAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null || sdp.isEmpty) return;
    await _applyRemote(pc, sdp, 'answer');
  }

  Future<String> acceptRestart(String sdp) async {
    final pc = _pc;
    if (pc == null || sdp.isEmpty) return '';
    await _applyRemote(pc, sdp, 'offer');
    final desc = await pc.createAnswer({'offerToReceiveAudio': true});
    await pc.setLocalDescription(desc);
    return _localSdp(desc);
  }

  Future<String> restartOffer() async {
    final pc = _pc;
    if (pc == null) return '';
    final desc = await pc.createOffer({
      'iceRestart': true,
      'offerToReceiveAudio': true,
    });
    await pc.setLocalDescription(desc);
    return _localSdp(desc);
  }

  Future<void> addCandidate(String raw) async {
    final pc = _pc;
    Map<String, dynamic>? parsed;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final candidate = RTCIceCandidate(
      parsed == null ? raw : (parsed['candidate'] as String?) ?? raw,
      parsed?['sdpMid'] as String?,
      (parsed?['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (pc == null || !_remoteReady) {
      _waiting.add(candidate);
      return;
    }
    await pc.addCandidate(candidate);
  }

  Future<void> setMuted(bool on) async {
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !on;
    }
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  Future<void> _flush() async {
    final pc = _pc;
    if (pc == null) return;
    final queued = List<RTCIceCandidate>.from(_waiting);
    _waiting.clear();
    for (final candidate in queued) {
      await pc.addCandidate(candidate);
    }
  }

  Future<void> close() async {
    _waiting.clear();
    _remote.clear();
    _remoteReady = false;
    final local = _local;
    _local = null;
    if (local != null) {
      for (final track in local.getTracks()) {
        await track.stop();
      }
      await local.dispose();
    }
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }
}

/// One audio call for this signed-in device.
class ChatCalls {
  ChatCalls._();

  static final instance = ChatCalls._();
  static final revision = ValueNotifier<int>(0);

  final ChatApi _api = ChatApi();
  final ChatCallMedia _media = ChatCallMedia();
  ChatCallRecord? active;
  String peerName = '';
  String status = '';
  String? problem;
  bool outgoing = false;
  bool muted = false;
  bool speaker = false;
  bool recovering = false;
  DateTime? connectedAt;
  bool _shown = false;
  bool _linked = true;
  bool _ringOn = false;
  String _me = '';
  String _lastRemote = '';
  final List<String> _iceBeforeId = [];
  Timer? _recover;
  Timer? _clock;
  Timer? _presentRetry;
  Timer? _toneFallback;

  Duration get elapsed {
    final start = connectedAt;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  void noteLink({required bool up}) {
    _linked = up;
    if (status != 'active') return;
    if (up) {
      _recover?.cancel();
      _recover = null;
      recovering = false;
      revision.value++;
      return;
    }
    recovering = true;
    revision.value++;
    if (!outgoing || _recover != null) return;
    _recover = Timer(const Duration(seconds: 12), () async {
      _recover = null;
      if (status != 'active' || !outgoing || _linked) {
        recovering = false;
        revision.value++;
        return;
      }
      try {
        final sdp = await _media.restartOffer();
        _sendSdp(sdp);
      } catch (_) {}
      recovering = false;
      revision.value++;
    });
  }

  Future<void> start(String threadId, String name) async {
    if (active?.live == true || status == 'ringing' || status == 'active') {
      _present();
      return;
    }
    outgoing = true;
    peerName = name;
    status = 'ringing';
    problem = null;
    muted = false;
    speaker = false;
    connectedAt = null;
    active = null;
    revision.value++;
    _present();
    try {
      final sdp = await _media.offer(_sendIce);
      final call = await _api.startCall(threadId, sdp: sdp);
      active = call;
      if (call.fromName.isNotEmpty) peerName = call.fromName;
      _flushIce();
      _armClock();
    } catch (error) {
      problem = error is StateError ? error.message : chatErrorText(error);
      status = '';
      outgoing = false;
      await _media.close();
    }
    revision.value++;
  }

  Future<void> onLive(ChatLiveEvent event) async {
    if (_me.isEmpty) _me = await ChatSession.username();
    if (event.type == 'call-ice') {
      if (event.candidate.isEmpty) return;
      if (active != null && event.callId.isNotEmpty && event.callId != active!.id) {
        return;
      }
      await _media.addCandidate(event.candidate);
      return;
    }
    if (event.type == 'call-sdp') {
      if (event.callId.isEmpty || event.sdp.isEmpty) return;
      if (active != null && event.callId != active!.id) return;
      if (event.sdp == _lastRemote) return;
      _lastRemote = event.sdp;
      try {
        if (outgoing) {
          await _media.acceptAnswer(event.sdp);
        } else if (status == 'active') {
          final answer = await _media.acceptRestart(event.sdp);
          _sendSdp(answer);
        }
      } catch (_) {}
      return;
    }
    if (event.type != 'call' || event.callId.isEmpty) return;
    final mine = _sameCallUser(event.from, _me);
    if (event.callState == 'ringing' && !mine && !outgoing) {
      active = ChatCallRecord(
        id: event.callId,
        thread: event.threadId,
        state: 'ringing',
        fromName: event.from,
        offer: event.offer,
      );
      peerName = event.from;
      status = 'ringing';
      outgoing = false;
      problem = null;
      revision.value++;
      _present();
      return;
    }
    if (active != null && event.callId != active!.id && event.callState == 'ringing') {
      return;
    }
    if (event.callState == 'active') {
      unawaited(_endRing());
      status = 'active';
      connectedAt ??= DateTime.now();
      if (event.answer.isNotEmpty && outgoing && event.answer != _lastRemote) {
        _lastRemote = event.answer;
        try {
          await _media.acceptAnswer(event.answer);
        } catch (_) {}
      }
      _armClock();
      revision.value++;
      _present();
      return;
    }
    if (event.callState == 'ended' ||
        event.callState == 'missed' ||
        event.callState == 'declined' ||
        event.callState == 'cancelled') {
      if (active != null && event.callId != active!.id) return;
      await _finish();
    }
  }

  Future<void> syncIncoming() async {
    if (outgoing || status == 'active') return;
    try {
      final me = _me.isEmpty ? await ChatSession.username() : _me;
      _me = me;
      final rows = await _api.calls();
      final call = incomingRing(rows, me);
      if (call == null) {
        if (status == 'ringing' && !outgoing) await _finish();
        return;
      }
      if (active?.id == call.id && status == 'ringing') {
        _present();
        return;
      }
      active = call;
      peerName = call.fromName.isEmpty ? 'Audio call' : call.fromName;
      status = 'ringing';
      outgoing = false;
      problem = null;
      revision.value++;
      _present();
    } catch (_) {}
  }

  Future<void> accept() async {
    final call = active;
    if (call == null || status != 'ringing') return;
    await _endRing();
    try {
      var offer = callSdp(call.offer);
      if (offer.isEmpty) {
        final rows = await _api.calls();
        for (final row in rows) {
          if (row.id == call.id) {
            offer = callSdp(row.offer);
            if (offer.isNotEmpty) break;
          }
        }
      }
      if (offer.isEmpty) {
        throw StateError('The call offer did not arrive. Ask them to call again.');
      }
      final sdp = await _media.answer(offer, _sendIce);
      final next = await _api.answerCall(call.id, accept: true, sdp: sdp);
      active = next;
      status = 'active';
      connectedAt = DateTime.now();
      problem = null;
      _flushIce();
      _armClock();
    } catch (error) {
      problem = error is StateError ? error.message : chatErrorText(error);
    }
    revision.value++;
  }

  Future<void> decline() async {
    final id = active?.id ?? '';
    await _finish();
    if (id.isEmpty) return;
    try {
      await _api.answerCall(id, accept: false);
    } catch (_) {}
  }

  Future<void> hangUp() async {
    final id = active?.id ?? '';
    final wasRinging = status == 'ringing';
    await _finish();
    if (id.isEmpty) return;
    try {
      if (wasRinging && !outgoing) {
        await _api.answerCall(id, accept: false);
      } else {
        await _api.endCall(id);
      }
    } catch (_) {}
  }

  Future<void> setMuted(bool on) async {
    muted = on;
    await _media.setMuted(on);
    revision.value++;
  }

  Future<void> setSpeaker(bool on) async {
    speaker = on;
    await _media.setSpeaker(on);
    revision.value++;
  }

  void _sendIce(String candidate) {
    final id = active?.id ?? '';
    if (id.isEmpty) {
      _iceBeforeId.add(candidate);
      return;
    }
    ChatLive.instance.sendText(
      jsonEncode({'type': 'call-ice', 'call': id, 'candidate': candidate}),
    );
  }

  void _sendSdp(String sdp) {
    final id = active?.id ?? '';
    if (id.isEmpty || sdp.isEmpty) return;
    ChatLive.instance.sendText(
      jsonEncode({'type': 'call-sdp', 'call': id, 'sdp': sdp}),
    );
  }

  void _flushIce() {
    final queued = List<String>.from(_iceBeforeId);
    _iceBeforeId.clear();
    for (final candidate in queued) {
      _sendIce(candidate);
    }
  }

  void _armClock() {
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (status == 'active') revision.value++;
    });
  }

  Future<void> _finish() async {
    _recover?.cancel();
    _recover = null;
    _clock?.cancel();
    _clock = null;
    _presentRetry?.cancel();
    _presentRetry = null;
    await _endRing();
    active = null;
    status = '';
    outgoing = false;
    recovering = false;
    connectedAt = null;
    muted = false;
    speaker = false;
    _lastRemote = '';
    _iceBeforeId.clear();
    await _media.close();
    revision.value++;
  }

  void _present() {
    if (status == 'ringing' && !outgoing) _beginRing();
    final quiet = problem == null || problem!.trim().isEmpty;
    if (_shown || (status != 'ringing' && status != 'active' && quiet)) {
      return;
    }
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context == null) {
      _presentRetry ??= Timer(const Duration(milliseconds: 700), () {
        _presentRetry = null;
        _present();
      });
      return;
    }
    _presentRetry?.cancel();
    _presentRetry = null;
    _shown = true;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0xFF0B141A),
      pageBuilder: (context, _, _) => const ChatCallSheet(),
    ).whenComplete(() {
      _shown = false;
      if (status == 'ringing' || status == 'active') _present();
    });
  }

  void _beginRing() {
    if (_ringOn || outgoing) return;
    _ringOn = true;
    unawaited(_playRing());
    unawaited(NotificationService().showIncomingCall(peerName));
  }

  Future<void> _playRing() async {
    try {
      await const MethodChannel('socialsave/media').invokeMethod<void>('playCallRingtone');
    } catch (_) {
      _toneFallback ??= Timer.periodic(const Duration(seconds: 2), (_) {
        SystemSound.play(SystemSoundType.alert);
      });
    }
  }

  Future<void> _endRing() async {
    if (!_ringOn && _toneFallback == null) return;
    _ringOn = false;
    _toneFallback?.cancel();
    _toneFallback = null;
    try {
      await const MethodChannel('socialsave/media').invokeMethod<void>('stopCallRingtone');
    } catch (_) {}
    unawaited(NotificationService().cancelIncomingCall());
  }
}

bool _sameCallUser(String a, String b) {
  String clean(String value) =>
      value.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  final left = clean(a);
  return left.isNotEmpty && left == clean(b);
}

class ChatCallSheet extends StatelessWidget {
  const ChatCallSheet({super.key});

  String _clock(Duration elapsed) {
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = elapsed.inHours;
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ChatCalls.revision,
      builder: (context, _, _) {
        final call = ChatCalls.instance;
        final live = call.status == 'ringing' || call.status == 'active';
        if (!live && (call.problem == null || call.problem!.isEmpty)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
        }
        final name = call.peerName.trim().isEmpty ? 'Audio call' : call.peerName.trim();
        final line = call.problem?.trim().isNotEmpty == true
            ? call.problem!.trim()
            : call.recovering
            ? 'Reconnecting…'
            : call.status == 'active'
            ? _clock(call.elapsed)
            : call.outgoing
            ? 'Calling…'
            : 'Incoming audio call';
        return PopScope(
          canPop: false,
          child: Material(
            color: const Color(0xFF0B141A),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 48, 28, 36),
                child: Column(
                  children: [
                    const Spacer(),
                    CircleAvatar(
                      radius: 52,
                      backgroundColor: const Color(0xFF1F2C34),
                      child: Text(
                        name.substring(0, 1).toUpperCase(),
                        style: const TextStyle(fontSize: 40, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(line, style: const TextStyle(fontSize: 16, color: Color(0xFFAEBAC1))),
                    const Spacer(),
                    if (call.status == 'ringing' && !call.outgoing)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CallAction(
                            color: const Color(0xFFE53935),
                            icon: Icons.call_end_rounded,
                            label: 'Decline',
                            onPressed: () => unawaited(call.decline()),
                          ),
                          _CallAction(
                            color: ChatUiTokens.brand,
                            icon: Icons.call_rounded,
                            label: 'Accept',
                            onPressed: () => unawaited(call.accept()),
                          ),
                        ],
                      )
                    else if (live)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CallAction(
                            color: const Color(0xFF1F2C34),
                            icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                            label: call.muted ? 'Unmute' : 'Mute',
                            onPressed: () => unawaited(call.setMuted(!call.muted)),
                          ),
                          _CallAction(
                            color: const Color(0xFFE53935),
                            icon: Icons.call_end_rounded,
                            label: 'End',
                            onPressed: () => unawaited(call.hangUp()),
                          ),
                          _CallAction(
                            color: const Color(0xFF1F2C34),
                            icon: call.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                            label: call.speaker ? 'Speaker' : 'Earpiece',
                            onPressed: () => unawaited(call.setSpeaker(!call.speaker)),
                          ),
                        ],
                      )
                    else
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          style: IconButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            fixedSize: const Size(72, 72),
            iconSize: 32,
          ),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}
