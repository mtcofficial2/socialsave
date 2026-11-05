import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/desktop_tray.dart';
import 'package:social_save/features/library/firewall_check.dart';
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
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        unawaited(Helper.setVolume(1, event.track));
        ChatCalls.instance.hear();
      }
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
    if (Plat.isWindows) await playout();
  }

  /// getUserMedia records the mic and leaves playback unset. Pick a speaker
  /// or headset so the other person can be heard.
  Future<void> playout() async {
    try {
      final outputs = await Helper.audiooutputs;
      if (outputs.isEmpty) return;
      var chosen = outputs.first;
      for (final device in outputs) {
        final label = device.label.toLowerCase();
        if (label.contains('speaker') ||
            label.contains('headphone') ||
            label.contains('headset') ||
            label.startsWith('default')) {
          chosen = device;
          break;
        }
      }
      if (chosen.deviceId.isEmpty) return;
      await Helper.selectAudioOutput(chosen.deviceId);
    } catch (_) {}
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

  Future<bool> acceptAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null || sdp.isEmpty) return false;
    await _applyRemote(pc, sdp, 'answer');
    return true;
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
  bool held = false;
  bool remoteHeld = false;
  bool recovering = false;
  String exitKind = '';
  String moment = '';
  DateTime? connectedAt;
  bool _shown = false;
  bool _linked = true;
  bool _ringOn = false;
  bool _finishing = false;
  bool _answering = false;
  bool _routeChosen = false;
  int _ringGen = 0;
  int _callEpoch = 0;
  String _me = '';
  String? _lanIp;
  String _lastRemote = '';
  final List<String> _iceBeforeId = [];
  final List<String> _closed = [];
  Timer? _recover;
  Timer? _clock;
  Timer? _presentRetry;
  Timer? _toneFallback;
  Timer? _watch;

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
    if (_finishing) return;
    if (active?.live == true || status == 'ringing' || status == 'active') {
      _present();
      return;
    }
    final epoch = ++_callEpoch;
    outgoing = true;
    peerName = name;
    status = 'ringing';
    problem = null;
    muted = false;
    speaker = false;
    held = false;
    remoteHeld = false;
    exitKind = '';
    moment = '';
    connectedAt = null;
    _routeChosen = false;
    active = null;
    revision.value++;
    _present();
    _armWatch();
    try {
      await _rememberLan();
      unawaited(_allowPcAudio());
      if (_finishing || epoch != _callEpoch) return;
      final sdp = callSdpToSend(await _media.offer(_sendIce), _lanIp);
      if (sdp.isEmpty) {
        throw StateError('The call could not start. Try again.');
      }
      if (_finishing || epoch != _callEpoch) return;
      final call = await _api.startCall(threadId, sdp: sdp);
      if (_finishing || epoch != _callEpoch) {
        try {
          await _api.endCall(call.id);
        } catch (_) {}
        return;
      }
      active = call;
      if (peerName.trim().isEmpty && call.fromName.isNotEmpty) {
        peerName = call.fromName;
      }
      _flushIce();
      _armClock();
    } catch (error) {
      if (_finishing || epoch != _callEpoch) return;
      problem = error is StateError ? error.message : chatErrorText(error);
      status = '';
      outgoing = false;
      _watch?.cancel();
      _watch = null;
      await _media.close();
      final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
          SnackBar(content: Text(problem!)),
        );
      }
    }
    revision.value++;
  }

  Future<void> onLive(ChatLiveEvent event) async {
    if (_finishing && event.type != 'call') return;
    if (_me.isEmpty) _me = await ChatSession.username();
    if (_finishing && event.type != 'call') return;
    if (event.type == 'call-hold') {
      if (event.callId.isEmpty || active == null || event.callId != active!.id) return;
      if (status != 'active') return;
      remoteHeld = event.on;
      revision.value++;
      return;
    }
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
      if (outgoing) {
        _markAnswered();
        await _useAnswer(event.sdp);
      } else if (status == 'active') {
        try {
          final answer = await _media.acceptRestart(event.sdp);
          _lastRemote = event.sdp;
          _sendSdp(answer);
        } catch (_) {}
      }
      return;
    }
    if (event.type != 'call' || event.callId.isEmpty) return;
    final mine = _sameCallUser(event.from, _me);
    if (event.callState == 'ringing' && !mine && !outgoing) {
      if (_closed.contains(event.callId) || _finishing) return;
      if (!callRingShouldReset(
        currentId: active?.id ?? '',
        eventId: event.callId,
        status: status,
        answering: _answering,
      )) {
        return;
      }
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
      held = false;
      remoteHeld = false;
      exitKind = '';
      revision.value++;
      _present();
      _armWatch();
      return;
    }
    if (active != null && event.callId != active!.id && event.callState == 'ringing') {
      return;
    }
    if (event.callState == 'active') {
      if (_finishing) return;
      if (active != null && event.callId != active!.id) return;
      if (callPickedUpElsewhere(outgoing: outgoing, answering: _answering, status: status)) {
        await _finish(kind: 'ended');
        return;
      }
      if (outgoing) await _useAnswer(event.answer);
      _markAnswered();
      _armWatch();
      return;
    }
    if (callIsOver(event.callState)) {
      if (active != null && event.callId != active!.id) return;
      if (active == null && status != 'ringing' && status != 'active') return;
      await _finish(kind: event.callState);
    }
  }

  Future<void> syncIncoming() async {
    if (_finishing) return;
    if (outgoing || status == 'active') {
      await _watchLive();
      return;
    }
    try {
      final me = _me.isEmpty ? await ChatSession.username() : _me;
      if (_finishing || outgoing || status == 'active') return;
      _me = me;
      final rows = await _api.calls();
      if (_finishing || outgoing || status == 'active') return;
      final call = incomingRing(rows, me);
      if (call == null) {
        if (status == 'ringing' && !outgoing) {
          final id = active?.id ?? '';
          var kind = 'missed';
          var elsewhere = false;
          for (final row in rows) {
            if (row.id != id) continue;
            if (row.state == 'active') {
              if (_answering) {
                _markAnswered();
                return;
              }
              elsewhere = true;
              break;
            }
            if (callIsOver(row.state)) kind = row.state;
          }
          await _finish(kind: elsewhere ? 'ended' : kind);
        }
        return;
      }
      if (_closed.contains(call.id)) return;
      if (active?.id == call.id && status == 'ringing') {
        _present();
        return;
      }
      active = call;
      peerName = call.fromName.isEmpty ? 'Audio call' : call.fromName;
      status = 'ringing';
      outgoing = false;
      problem = null;
      held = false;
      remoteHeld = false;
      exitKind = '';
      revision.value++;
      _present();
      _armWatch();
    } catch (_) {}
  }

  Future<void> _watchLive() async {
    final id = active?.id ?? '';
    if (id.isEmpty || _finishing) return;
    try {
      final rows = await _api.calls();
      if (_finishing || active?.id != id) return;
      for (final row in rows) {
        if (row.id != id || row.state != 'active') continue;
        if (outgoing) await _useAnswer(row.answer);
        _markAnswered();
        break;
      }
      if (!watchedCallFinished(rows, id)) return;
      var kind = 'ended';
      for (final row in rows) {
        if (row.id == id && row.state.isNotEmpty) kind = row.state;
      }
      if (!callIsOver(kind)) kind = 'ended';
      await _finish(kind: kind);
    } catch (_) {}
  }

  Future<void> accept() async {
    final call = active;
    if (call == null || status != 'ringing' || _finishing || _answering) return;
    _answering = true;
    moment = 'accept';
    revision.value++;
    unawaited(_endRing());
    if (_finishing || active?.id != call.id) {
      _dropAccept();
      return;
    }
    try {
      await _rememberLan();
      unawaited(_allowPcAudio());
      if (_finishing || active?.id != call.id) {
        _dropAccept();
        return;
      }
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
      if (_finishing || active?.id != call.id) {
        _dropAccept();
        return;
      }
      if (offer.isEmpty) {
        throw StateError('The call offer did not arrive. Ask them to call again.');
      }
      final sdp = callSdpToSend(await _media.answer(offer, _sendIce), _lanIp);
      if (sdp.isEmpty) {
        throw StateError('The call could not start. Try again.');
      }
      final next = await _api.answerCall(call.id, accept: true, sdp: sdp);
      if (_finishing) return;
      active = next;
      status = 'active';
      connectedAt = DateTime.now();
      problem = null;
      moment = '';
      hear();
      _flushIce();
      _armClock();
      _armWatch();
      _present();
    } catch (error) {
      if (_finishing) return;
      _answering = false;
      moment = '';
      problem = error is StateError ? error.message : chatErrorText(error);
    }
    revision.value++;
  }

  Future<void> decline() async {
    final id = active?.id ?? '';
    _remember(id);
    final done = _finish(kind: 'declined');
    if (id.isNotEmpty) {
      try {
        await _api.answerCall(id, accept: false);
      } catch (_) {}
    }
    await done;
  }

  Future<void> hangUp() async {
    final id = active?.id ?? '';
    final wasRinging = status == 'ringing';
    final placedHere = outgoing;
    final kind = !wasRinging ? 'ended' : (placedHere ? 'cancelled' : 'declined');
    _remember(id);
    final done = _finish(kind: kind);
    if (id.isNotEmpty) {
      try {
        if (wasRinging && !placedHere) {
          await _api.answerCall(id, accept: false);
        } else {
          await _api.endCall(id);
        }
      } catch (_) {}
    }
    await done;
  }

  Future<void> setMuted(bool on) async {
    if (_finishing) return;
    muted = on;
    await _media.setMuted(on || held);
    revision.value++;
  }

  Future<void> setHeld(bool on) async {
    if (_finishing || status != 'active') return;
    held = on;
    revision.value++;
    await _media.setMuted(on || muted);
    final id = active?.id ?? '';
    if (id.isEmpty || _finishing) return;
    ChatLive.instance.sendText(
      jsonEncode({'type': 'call-hold', 'call': id, 'on': on}),
    );
  }

  Future<void> setSpeaker(bool on) async {
    _routeChosen = true;
    speaker = on;
    await _media.setSpeaker(on);
    revision.value++;
  }

  void _sendIce(String candidate) {
    final ready = callCandidateForPeer(candidate, _lanIp);
    if (ready.isEmpty) return;
    final id = active?.id ?? '';
    if (id.isEmpty) {
      _iceBeforeId.add(ready);
      return;
    }
    ChatLive.instance.sendText(
      jsonEncode({'type': 'call-ice', 'call': id, 'candidate': ready}),
    );
  }

  void _sendSdp(String sdp) {
    final ready = callSdpToSend(sdp, _lanIp);
    final id = active?.id ?? '';
    if (id.isEmpty || ready.isEmpty) return;
    sdp = ready;
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

  /// A failed answer must be tried again from the next live frame or the poll.
  Future<void> _useAnswer(String sdp) async {
    if (!outgoing || sdp.isEmpty || sdp == _lastRemote || _finishing) return;
    try {
      if (await _media.acceptAnswer(sdp)) _lastRemote = sdp;
    } catch (_) {}
  }

  void _dropAccept() {
    if (_finishing) return;
    _answering = false;
    if (moment == 'accept') moment = '';
    revision.value++;
  }

  /// The other person picked up. Show the call screen even if the live frame was missed.
  void _markAnswered() {
    if (_finishing) return;
    if (status != 'ringing' && status != 'active') return;
    if (status != 'active') {
      status = 'active';
      connectedAt ??= DateTime.now();
      unawaited(_endRing());
      _armClock();
      revision.value++;
    }
    hear();
    _present();
  }

  /// Play the other person out loud. The earpiece stays silent on a lot of
  /// phones until the speaker route is set, and Windows needs a named output.
  void hear() {
    if (status != 'active' || _finishing || _routeChosen) return;
    final first = !speaker;
    speaker = true;
    unawaited(_media.setSpeaker(true));
    if (Plat.isWindows) unawaited(_media.playout());
    if (first) revision.value++;
  }

  void _armClock() {
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (status == 'active') revision.value++;
    });
  }

  void _remember(String id) {
    if (id.isEmpty) return;
    _closed.remove(id);
    _closed.add(id);
    if (_closed.length > 40) _closed.removeAt(0);
  }

  void _armWatch() {
    if (_finishing) return;
    _watch ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(syncIncoming());
    });
  }

  Future<void> _finish({String kind = 'ended'}) async {
    if (_finishing) return;
    _finishing = true;
    _answering = false;
    _routeChosen = false;
    _callEpoch++;
    _remember(active?.id ?? '');
    _recover?.cancel();
    _recover = null;
    _clock?.cancel();
    _clock = null;
    _presentRetry?.cancel();
    _presentRetry = null;
    _watch?.cancel();
    _watch = null;
    exitKind = kind.isEmpty ? 'ended' : kind;
    revision.value++;
    await _endRing();
    if (_shown) {
      await Future<void>.delayed(const Duration(milliseconds: 680));
    }
    active = null;
    status = '';
    outgoing = false;
    recovering = false;
    connectedAt = null;
    muted = false;
    speaker = false;
    held = false;
    remoteHeld = false;
    moment = '';
    problem = null;
    _lastRemote = '';
    _iceBeforeId.clear();
    await _media.close();
    revision.value++;
    _finishing = false;
  }

  void _present() {
    if (_finishing) return;
    if (status == 'ringing' && !outgoing) _beginRing();
    if (!callUsesFullScreen(outgoing: outgoing, status: status)) return;
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
    _showWindow();
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0xFF0B141A),
      pageBuilder: (context, _, _) => const ChatCallSheet(),
    ).whenComplete(() {
      _shown = false;
      if (status != 'ringing' && status != 'active') exitKind = '';
      if (!_finishing && exitKind.isEmpty && (status == 'ringing' || status == 'active')) {
        _present();
      }
    });
  }

  void _beginRing() {
    if (_ringOn || outgoing || _finishing || exitKind.isNotEmpty || _answering) return;
    _ringOn = true;
    final gen = ++_ringGen;
    _showWindow();
    unawaited(_playRing(gen));
    unawaited(_showIncoming(gen));
  }

  void _showWindow() {
    if (!Plat.isWindows) return;
    unawaited(DesktopTray.show());
  }

  Future<void> _rememberLan() async {
    if (!Plat.isWindows || _lanIp != null) return;
    _lanIp = await _windowsLanIp();
  }

  Future<void> _allowPcAudio() {
    if (!Plat.isWindows) return Future<void>.value();
    return FirewallCheck.ensureCallAudio(_askCallFirewall);
  }

  Future<bool?> _askCallFirewall() async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Allow call audio on this PC?'),
        content: const Text(
          'Windows Firewall is blocking audio between this PC and a phone. '
          'SocialSave will allow inbound UDP for SocialSave.exe only. '
          'Windows will ask for administrator permission next.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
        ],
      ),
    );
  }

  Future<void> _showIncoming(int gen) async {
    await NotificationService().showIncomingCall(peerName);
    if (gen != _ringGen || !_ringOn) {
      await NotificationService().cancelIncomingCall();
    }
  }

  Future<void> _playRing(int gen) async {
    try {
      await const MethodChannel('socialsave/media').invokeMethod<void>('playCallRingtone');
    } catch (_) {
      if (gen != _ringGen || !_ringOn) return;
      _toneFallback ??= Timer.periodic(const Duration(seconds: 2), (_) {
        SystemSound.play(SystemSoundType.alert);
      });
      return;
    }
    if (gen != _ringGen || !_ringOn) {
      try {
        await const MethodChannel('socialsave/media').invokeMethod<void>('stopCallRingtone');
      } catch (_) {}
    }
  }

  Future<void> _endRing() async {
    _ringGen++;
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

/// A private Wi-Fi address for this PC. Virtual adapters are skipped so a
/// call is not pointed at a Hyper-V or WSL address the phone cannot reach.
Future<String?> _windowsLanIp() async {
  try {
    final faces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    String? pick;
    for (final face in faces) {
      final name = face.name.toLowerCase();
      if (name.contains('virtual') ||
          name.contains('vethernet') ||
          name.contains('wsl') ||
          name.contains('hyper-v') ||
          name.contains('vmware') ||
          name.contains('vbox') ||
          name.contains('bluetooth')) {
        continue;
      }
      for (final addr in face.addresses) {
        final ip = addr.address;
        if (!callLanIpUsable(ip)) continue;
        pick ??= ip;
        if (name.contains('wi-fi') ||
            name.contains('wifi') ||
            name.contains('wlan') ||
            name.contains('ethernet')) {
          return ip;
        }
      }
    }
    return pick;
  } catch (_) {
    return null;
  }
}

class ChatCallSheet extends StatefulWidget {
  const ChatCallSheet({super.key});

  @override
  State<ChatCallSheet> createState() => _ChatCallSheetState();
}

class _ChatCallSheetState extends State<ChatCallSheet> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _bloom;
  late final AnimationController _exit;
  late final AnimationController _hold;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    _bloom = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
    _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 640));
    _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    _exit.addStatusListener((state) {
      if (state == AnimationStatus.completed && mounted) {
        _closeIfDone(ChatCalls.instance);
      }
    });
    ChatCalls.revision.addListener(_onRev);
    _onRev();
  }

  void _onRev() {
    final call = ChatCalls.instance;
    final moving = ((call.status == 'ringing' && call.moment != 'accept') || call.recovering) &&
        call.exitKind.isEmpty;
    if (moving) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
    final holding = (call.held || call.remoteHeld) && call.exitKind.isEmpty;
    if (holding) {
      if (!_hold.isAnimating) _hold.repeat(reverse: true);
    } else if (_hold.isAnimating) {
      _hold.stop();
      _hold.value = 0;
    }
    if (call.moment == 'accept' && _bloom.value == 0 && !_bloom.isAnimating) {
      _bloom.forward(from: 0);
    }
    if (call.exitKind.isNotEmpty && _exit.value == 0 && !_exit.isAnimating) {
      _exit.forward();
    }
  }

  @override
  void dispose() {
    ChatCalls.revision.removeListener(_onRev);
    _pulse.dispose();
    _bloom.dispose();
    _exit.dispose();
    _hold.dispose();
    super.dispose();
  }

  String _clock(Duration elapsed) {
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = elapsed.inHours;
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  String _line(ChatCalls call) {
    if (call.exitKind.isNotEmpty) return callExitLabel(call.exitKind);
    final problem = call.problem?.trim() ?? '';
    if (problem.isNotEmpty) return problem;
    if (call.held) return 'On hold';
    if (call.remoteHeld) return 'They held the call';
    if (call.recovering) return 'Reconnecting…';
    if (call.status == 'active') return _clock(call.elapsed);
    if (call.moment == 'accept') return 'Connecting…';
    if (call.outgoing) return 'Calling…';
    return 'Incoming audio call';
  }

  Color _wash(String kind) {
    switch (kind) {
      case 'declined':
        return const Color(0xFF4A1518);
      case 'missed':
      case 'cancelled':
        return const Color(0xFF1C2833);
      default:
        return const Color(0xFF0B141A);
    }
  }

  double _bloomScale(double t) {
    if (t <= 0) return 1;
    final up = t < 0.45 ? t / 0.45 : (1 - t) / 0.55;
    return 1 + 0.14 * up.clamp(0.0, 1.0);
  }

  void _closeIfDone(ChatCalls call) {
    final quiet = call.problem == null || call.problem!.trim().isEmpty;
    final over = call.status != 'ringing' && call.status != 'active';
    if (!over || !quiet || _closing) return;
    if (call.exitKind.isNotEmpty && _exit.isAnimating) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    });
  }

  Widget _face(String name, double scale, double pulse, bool holdOn, Color ringColor) {
    final letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (pulse > 0) ...[
            _ripple(pulse, ringColor),
            _ripple((pulse + 0.5) % 1, ringColor),
          ],
          Transform.scale(
            scale: scale,
            child: Container(
              width: 112,
              height: 112,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1F2C34),
                boxShadow: [
                  if (_bloom.value > 0)
                    BoxShadow(
                      color: ChatUiTokens.brand.withValues(
                        alpha: (0.45 * (1 - (_bloom.value - 0.5).abs() * 2)).clamp(0.0, 1.0).toDouble(),
                      ),
                      blurRadius: 28,
                      spreadRadius: 4,
                    ),
                ],
              ),
              child: Text(
                letter,
                style: const TextStyle(fontSize: 40, color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (holdOn)
            Positioned(
              right: 58,
              bottom: 58,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: Color(0xFFF9A825), shape: BoxShape.circle),
                child: const Icon(Icons.pause_rounded, color: Colors.white, size: 22),
              ),
            ),
        ],
      ),
    );
  }

  Widget _ripple(double t, Color color) {
    final size = 112 + 92 * t;
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: (1 - t) * 0.5), width: 2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ChatCalls.revision,
      builder: (context, _, _) {
        final call = ChatCalls.instance;
        _closeIfDone(call);
        final leaving = call.exitKind.isNotEmpty;
        final live = call.status == 'ringing' || call.status == 'active';
        final name = call.peerName.trim().isEmpty ? 'Audio call' : call.peerName.trim();
        final holdOn = (call.held || call.remoteHeld) && !leaving;
        return PopScope(
          canPop: false,
          child: AnimatedBuilder(
            animation: Listenable.merge([_pulse, _bloom, _exit, _hold]),
            builder: (context, _) {
              final fade = (1 - Curves.easeIn.transform(_exit.value)).clamp(0.0, 1.0);
              final drop = 42.0 * Curves.easeIn.transform(_exit.value);
              final pulse = ((call.status == 'ringing' && call.moment != 'accept') || call.recovering) &&
                      !leaving
                  ? _pulse.value
                  : 0.0;
              final scale = leaving
                  ? 1 - 0.1 * _exit.value
                  : holdOn
                  ? 1 - 0.045 * _hold.value
                  : _bloomScale(_bloom.value);
              final bg = Color.lerp(const Color(0xFF0B141A), _wash(call.exitKind), _exit.value) ??
                  const Color(0xFF0B141A);
              final beat = pulse <= 0.5 ? pulse * 2 : (1 - pulse) * 2;
              final textOpacity = call.recovering && !leaving ? 0.45 + 0.55 * beat : 1.0;
              final ringColor = call.outgoing ? const Color(0xFF53BDEB) : ChatUiTokens.brand;
              return Material(
                color: bg,
                child: Opacity(
                  opacity: fade,
                  child: Transform.translate(
                    offset: Offset(0, drop),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
                        child: Column(
                          children: [
                            const Spacer(),
                            _face(name, scale, pulse, holdOn, ringColor),
                            Text(
                              name,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Opacity(
                              opacity: textOpacity,
                              child: Text(
                                _line(call),
                                style: TextStyle(
                                  fontSize: 16,
                                  color: leaving ? Colors.white : const Color(0xFFAEBAC1),
                                  fontWeight: leaving ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (!leaving &&
                                call.status == 'ringing' &&
                                !call.outgoing &&
                                call.moment != 'accept')
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
                                    scale: 1 + 0.06 * beat,
                                    onPressed: () => unawaited(call.accept()),
                                  ),
                                ],
                              )
                            else if (!leaving && live) ...[
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  _CallAction(
                                    color: const Color(0xFF1F2C34),
                                    icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                    label: call.muted ? 'Unmute' : 'Mute',
                                    onPressed: () => unawaited(call.setMuted(!call.muted)),
                                  ),
                                  if (call.status == 'active')
                                    _CallAction(
                                      color: call.held ? const Color(0xFFF9A825) : const Color(0xFF1F2C34),
                                      icon: call.held ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                      label: call.held ? 'Resume' : 'Hold',
                                      onPressed: () => unawaited(call.setHeld(!call.held)),
                                    ),
                                  _CallAction(
                                    color: const Color(0xFF1F2C34),
                                    icon: call.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                                    label: call.speaker ? 'Speaker' : 'Earpiece',
                                    onPressed: () => unawaited(call.setSpeaker(!call.speaker)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 22),
                              _CallAction(
                                color: const Color(0xFFE53935),
                                icon: Icons.call_end_rounded,
                                label: 'End',
                                onPressed: () => unawaited(call.hangUp()),
                              ),
                            ] else if (!leaving)
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Close'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
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
    this.scale = 1,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.scale(
          scale: scale,
          child: IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              fixedSize: const Size(68, 68),
              iconSize: 30,
            ),
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}
