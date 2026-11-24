import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_kit/media_kit.dart' show Media, Player, PlaylistMode;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/desktop_tray.dart';
import 'package:social_save/features/library/firewall_check.dart';
import 'package:social_save/shared/routing/app_router.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/shared/widgets/app_snack.dart';
import 'package:url_launcher/url_launcher.dart';

/// Peer settings for one call. [servers] come from the API and add a TURN
/// relay when the server has one, so audio reaches phones on other networks.
Map<String, dynamic> chatCallConfig(List<Map<String, dynamic>> servers, {bool relayOnly = false}) => {
  'sdpSemantics': 'unified-plan',
  'iceServers': servers.isEmpty ? chatDefaultIceServers : servers,
  'iceTransportPolicy': relayOnly ? 'relay' : 'all',
  'bundlePolicy': 'max-bundle',
  'rtcpMuxPolicy': 'require',
  'iceCandidatePoolSize': 2,
};

/// Microphone audio for one call. Binary socket frames stay photos.
class ChatCallMedia {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  final List<MediaStream> _remote = [];
  final List<RTCIceCandidate> _waiting = [];
  bool _remoteReady = false;
  bool _played = false;
  int _playGen = 0;
  Future<void> _audioChain = Future<void>.value();

  /// Set before each call from [ChatApi.callIceServers].
  List<Map<String, dynamic>> iceServers = chatDefaultIceServers;

  static const micKey = 'call.windows.mic';
  static const speakerKey = 'call.windows.speaker';

  static Future<String?> savedDevice(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getString(key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveDevice(String key, String id) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, id);
    } catch (e) { logQuiet('chat_call', e); }
  }

  /// Microphones and speakers Windows reports, for the Devices picker.
  static Future<List<MediaDeviceInfo>> devices() async {
    try {
      return await navigator.mediaDevices.enumerateDevices();
    } catch (e) {
      logQuiet('chat_call.devices', e);
      return const [];
    }
  }

  /// The mic now sending audio, if known.
  String? get micInUse => _micInUse;
  String? _micInUse;

  /// Switch the PC mic in the middle of a call without dropping it.
  Future<void> useMic(String deviceId, {required bool muted}) async {
    await _saveDevice(micKey, deviceId);
    final pc = _pc;
    if (pc == null) return;
    await _runWindowsAudio(() async {
      final next = await navigator.mediaDevices.getUserMedia(windowsCallMic(deviceId));
      final tracks = next.getAudioTracks();
      if (tracks.isEmpty) {
        await next.dispose();
        throw StateError(windowsMicProblem(blocked: false, mics: 1));
      }
      final track = tracks.first;
      track.enabled = !muted;
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind == 'audio') await sender.replaceTrack(track);
      }
      final old = _local;
      _local = next;
      _micInUse = deviceId;
      if (old != null) {
        for (final t in old.getTracks()) {
          try {
            await t.stop();
          } catch (e) { logQuiet('chat_call', e); }
        }
        try {
          await old.dispose();
        } catch (e) { logQuiet('chat_call', e); }
      }
    });
  }

  /// Play the call on this speaker or headset, and remember it.
  Future<void> useSpeaker(String deviceId) async {
    await _saveDevice(speakerKey, deviceId);
    await routePlayback(preferSpeaker: true);
  }

  /// Windows device changes share one audio engine. Overlapping them freezes
  /// the call screen, so Hang up never arrives.
  Future<T> _runWindowsAudio<T>(Future<T> Function() job) {
    if (!Plat.isWindows) return job();
    final run = _audioChain.then((_) => job());
    _audioChain = run.then((_) {}, onError: (_, _) {});
    return run;
  }

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
      } catch (e) { logQuiet('chat_call', e); }
    }
    final pc = await createPeerConnection(chatCallConfig(iceServers));
    _pc = pc;
    pc.onTrack = (event) {
      for (final stream in event.streams) {
        if (!_remote.contains(stream)) _remote.add(stream);
      }
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        unawaited(_startPlayback(event.track));
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        ChatCalls.instance.noteLink(up: true);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        ChatCalls.instance.noteLink(up: false);
      }
    };
    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        ChatCalls.instance.noteLink(up: true);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        ChatCalls.instance.noteLink(up: false);
      }
    };
    if (Plat.isWindows && await windowsMicBlockedNow()) {
      throw StateError(windowsMicProblem(blocked: true, mics: 1));
    }
    final constraints = await _runWindowsAudio(_audioConstraints);
    MediaStream stream;
    try {
      try {
        stream = await _runWindowsAudio(
          () => navigator.mediaDevices.getUserMedia(constraints),
        );
      } catch (_) {
        if (constraints['audio'] == true) rethrow;
        stream = await _runWindowsAudio(
          () => navigator.mediaDevices.getUserMedia(windowsCallMic(null)),
        );
      }
      if (Plat.isWindows && stream.getAudioTracks().isEmpty) {
        await stream.dispose();
        throw StateError('no mic track');
      }
    } catch (error) {
      if (!Plat.isWindows) rethrow;
      logQuiet('chat_call.mic', error);
      final all = await devices();
      final mics = all.where((d) => d.kind == 'audioinput').length;
      throw StateError(windowsMicProblem(blocked: false, mics: mics));
    }
    _local = stream;
    if (Plat.isWindows) {
      final options = constraints['audio'];
      if (options is Map && options['optional'] is List) {
        for (final o in options['optional'] as List) {
          if (o is Map && o['sourceId'] is String) _micInUse = o['sourceId'] as String;
        }
      }
    }
    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  /// Play the remote voice once, after the track exists, then set the level.
  /// Switching the Windows speaker again flushes the buffer down to the last words.
  Future<void> _startPlayback(MediaStreamTrack track) async {
    final gen = _playGen;
    try {
      await _runWindowsAudio(() async {
        if (gen != _playGen) return;
        if (Plat.isWindows && !_played) {
          await playout();
          if (gen != _playGen) return;
          _played = true;
        }
        if (gen != _playGen) return;
        try {
          await Helper.setVolume(1, track);
        } catch (e) { logQuiet('chat_call', e); }
      });
    } catch (e) { logQuiet('chat_call', e); }
    if (gen != _playGen) return;
    ChatCalls.instance.hear();
  }

  /// Windows records device 0 unless a source is named first. Device 0 is
  /// often a virtual cable, so the phone hears silence. Processing stays off.
  Future<Map<String, dynamic>> _audioConstraints() async {
    if (!Plat.isWindows) return {'audio': true, 'video': false};
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final saved = callSavedDevice(
        await savedDevice(micKey),
        devices.where((d) => d.kind == 'audioinput').map((d) => d.deviceId),
      );
      if (saved != null) return windowsCallMic(saved);
      MediaDeviceInfo? fallback;
      MediaDeviceInfo? named;
      MediaDeviceInfo? preferred;
      for (final device in devices) {
        if (device.kind != 'audioinput' || device.deviceId.isEmpty) continue;
        final label = device.label.toLowerCase();
        if (_skippedAudioLabel(label)) continue;
        if (label.contains('speaker') &&
            !label.contains('mic') &&
            !label.contains('microphone')) {
          continue;
        }
        fallback ??= device;
        final mic = label.contains('microphone') ||
            label.contains('headset') ||
            label.contains('mic');
        if (mic) named ??= device;
        if (label.startsWith('default') && mic) {
          preferred = device;
          break;
        }
      }
      final pick = preferred ?? named ?? fallback;
      return windowsCallMic(pick?.deviceId);
    } catch (_) {
      return windowsCallMic(null);
    }
  }

  /// getUserMedia records the mic and leaves playback unset. Pick a real
  /// speaker or headset. Virtual cables are skipped so the voice is not sent
  /// to a device that is not in the room.
  Future<void> playout({bool preferSpeaker = true}) async {
    try {
      final outputs = await Helper.audiooutputs;
      if (Plat.isWindows) {
        final saved = callSavedDevice(
          await savedDevice(speakerKey),
          outputs.map((d) => d.deviceId),
        );
        if (saved != null) {
          await Helper.selectAudioOutput(saved);
          return;
        }
      }
      MediaDeviceInfo? chosen;
      bool usable(MediaDeviceInfo device) {
        final label = device.label.toLowerCase();
        if (device.deviceId.isEmpty) return false;
        return !_skippedAudioLabel(label);
      }

      bool matches(MediaDeviceInfo device) {
        final label = device.label.toLowerCase();
        final ear = label.contains('headphone') ||
            label.contains('headset') ||
            label.contains('earphone');
        final speaker = label.contains('speaker') || label.startsWith('default');
        if (preferSpeaker) return speaker && !ear;
        return ear;
      }

      for (final device in outputs) {
        if (!usable(device)) continue;
        chosen ??= device;
        if (matches(device)) {
          chosen = device;
          break;
        }
      }
      final pick = chosen;
      if (pick == null) return;
      await Helper.selectAudioOutput(pick.deviceId);
    } catch (e) { logQuiet('chat_call', e); }
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
    } catch (e) { logQuiet('chat_call', e); }
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

  /// Returns false when the phone refused the switch.
  Future<bool> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
      return true;
    } catch (e) {
      logQuiet('chat_call.speaker', e);
      return false;
    }
  }

  /// One speaker change, then restore the level a device switch clears.
  Future<void> routePlayback({required bool preferSpeaker}) async {
    await _runWindowsAudio(() async {
      await playout(preferSpeaker: preferSpeaker);
      for (final stream in List<MediaStream>.from(_remote)) {
        for (final track in stream.getAudioTracks()) {
          try {
            await Helper.setVolume(1, track);
          } catch (e) { logQuiet('chat_call', e); }
        }
      }
    });
  }

  Future<void> _flush() async {
    final pc = _pc;
    if (pc == null) return;
    final queued = List<RTCIceCandidate>.from(_waiting);
    _waiting.clear();
    for (final candidate in queued) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) { logQuiet('chat_call', e); }
    }
  }

  Future<void> close() async {
    _micInUse = null;
    _played = false;
    _playGen++;
    _waiting.clear();
    _remote.clear();
    _remoteReady = false;
    final local = _local;
    _local = null;
    final pc = _pc;
    _pc = null;
    await _runWindowsAudio(() async {
      if (local != null) {
        for (final track in local.getTracks()) {
          try {
            await track.stop();
          } catch (e) { logQuiet('chat_call', e); }
        }
        try {
          await local.dispose();
        } catch (e) { logQuiet('chat_call', e); }
      }
      if (pc != null) {
        try {
          await pc.close();
        } catch (e) { logQuiet('chat_call', e); }
        try {
          await pc.dispose();
        } catch (e) { logQuiet('chat_call', e); }
      }
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (e) { logQuiet('chat_call', e); }
    });
  }
}

/// One audio call for this signed-in device.
class ChatCalls {
  ChatCalls._() {
    ChatLive.instance.connected.addListener(_onSocket);
  }

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
  bool pcAudioBlocked = false;
  bool allowingPcAudio = false;
  String exitKind = '';
  String moment = '';
  DateTime? connectedAt;
  bool _shown = false;
  bool _linked = false;
  bool _hadAudio = false;
  bool _ringOn = false;
  bool _outTone = false;
  bool _finishing = false;
  bool _answering = false;
  bool _routeChosen = false;
  int _routeGen = 0;
  int _ringGen = 0;
  int _callEpoch = 0;
  String _me = '';
  String? _lanIp;
  String _lastRemote = '';
  final List<String> _iceBeforeId = [];
  String _sdpPending = '';
  final List<String> _closed = [];
  Timer? _recover;
  Timer? _speakerRetry;
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
    if (up) _hadAudio = true;
    _linked = up;
    _syncLink();
  }

  /// A dropped path during pickup used to be ignored, so the call stayed up
  /// with no voice and never tried again. Checking is not a working path.
  void _syncLink() {
    if (status != 'active' || _finishing) return;
    if (_linked) {
      _recover?.cancel();
      _recover = null;
      if (!recovering) return;
      recovering = false;
      revision.value++;
      return;
    }
    if (_hadAudio && !recovering) {
      recovering = true;
      revision.value++;
    }
    if (!outgoing || _recover != null) return;
    _recover = Timer(const Duration(seconds: 12), () async {
      _recover = null;
      if (status != 'active' || !outgoing || _linked || _finishing) return;
      if (!recovering) {
        recovering = true;
        revision.value++;
      }
      try {
        final sdp = await _media.restartOffer();
        _sendSdp(sdp);
      } catch (e) { logQuiet('chat_call', e); }
      if (status == 'active' && outgoing && !_linked && !_finishing) _syncLink();
    });
  }

  void _onSocket() {
    if (!ChatLive.instance.connected.value) return;
    _flushIce();
    // Warm the relay list once a day so pressing Call does not wait on it.
    unawaited(_api.callIceServers());
  }

  /// True once audio has a working path in this call.
  bool get audioUp => _linked;

  Future<void> _loadIce() async {
    try {
      _media.iceServers = await _api.callIceServers().timeout(const Duration(seconds: 5));
    } catch (e) {
      logQuiet('chat_call.ice', e);
      _media.iceServers = chatDefaultIceServers;
    }
  }

  Future<void> start(String threadId, String name) async {
    if (!callsOnThisDevice(windows: Plat.isWindows)) return;
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
    pcAudioBlocked = false;
    allowingPcAudio = false;
    connectedAt = null;
    _routeChosen = false;
    _linked = false;
    _hadAudio = false;
    _sdpPending = '';
    active = null;
    revision.value++;
    _present();
    _armWatch();
    _beginOutgoingTone();
    try {
      await _rememberLan();
      unawaited(_notePcAudio());
      if (_finishing || epoch != _callEpoch) return;
      await _loadIce();
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
        } catch (e) { logQuiet('chat_call', e); }
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
      unawaited(_stopOutgoingTone());
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
    if (!callsOnThisDevice(windows: Plat.isWindows)) return;
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
          if (answer.isEmpty) return;
          _lastRemote = event.sdp;
          _sendSdp(answer);
        } catch (e) { logQuiet('chat_call', e); }
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
      _linked = false;
      _hadAudio = false;
      _sdpPending = '';
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
    if (!callsOnThisDevice(windows: Plat.isWindows)) return;
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
      _linked = false;
      _hadAudio = false;
      _sdpPending = '';
      revision.value++;
      _present();
      _armWatch();
    } catch (e) { logQuiet('chat_call', e); }
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
    } catch (e) { logQuiet('chat_call', e); }
  }

  /// Answer tapped on the call notice. The call screen opens on that call.
  Future<void> acceptNotice(String id) async {
    if (!callsOnThisDevice(windows: Plat.isWindows)) return;
    final wanted = id.trim();
    if (wanted.isEmpty) return;
    for (var i = 0; i < 4; i++) {
      if (_finishing) return;
      if (active?.id != wanted || status != 'ringing') {
        await syncIncoming();
      }
      if (active?.id == wanted && status == 'ringing' && !_finishing) {
        await accept();
        return;
      }
      await Future<void>.delayed(AppDurations.slow);
    }
  }

  /// Hang up on the call notice already told the server. Close this phone's screen.
  Future<void> noticeDeclined(String id) async {
    if (active?.id != id || status != 'ringing') return;
    _remember(id);
    await _finish(kind: 'declined');
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
      unawaited(_notePcAudio());
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
      await _loadIce();
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
      _syncLink();
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
      } catch (e) { logQuiet('chat_call', e); }
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
      } catch (e) { logQuiet('chat_call', e); }
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

  /// Returns false when the speaker could not be switched (the call page
  /// tells the user).
  Future<bool> setSpeaker(bool on) async {
    _routeGen++;
    _routeChosen = true;
    _speakerRetry?.cancel();
    speaker = on;
    var ok = true;
    if (Plat.isWindows) {
      await _media.routePlayback(preferSpeaker: on);
    } else {
      ok = await _media.setSpeaker(on);
    }
    revision.value++;
    return ok;
  }

  /// The PC mic now in use, for the Devices picker.
  String? get micInUse => _media.micInUse;

  /// Pick the PC microphone. Works before and during a call.
  Future<String?> chooseMic(String deviceId) async {
    try {
      await _media.useMic(deviceId, muted: muted || held);
      revision.value++;
      return null;
    } catch (error) {
      return error is StateError ? error.message : chatErrorText(error);
    }
  }

  /// Pick the PC speaker or headset. Works before and during a call.
  Future<void> chooseSpeaker(String deviceId) async {
    _routeChosen = true;
    speaker = true;
    await _media.useSpeaker(deviceId);
    revision.value++;
  }

  /// Decline tapped on the Windows call toast.
  Future<void> declineNotice(String id) async {
    if (id.isEmpty) return;
    if (active?.id == id && status == 'ringing' && !outgoing) {
      await decline();
      return;
    }
    _remember(id);
    try {
      await _api.answerCall(id, accept: false);
    } catch (e) { logQuiet('chat_call', e); }
  }

  void _rememberIce(String ready) {
    if (_iceBeforeId.length >= 40) _iceBeforeId.removeAt(0);
    _iceBeforeId.add(ready);
  }

  void _sendIce(String candidate) {
    final ready = callCandidateForPeer(candidate, _lanIp);
    if (ready.isEmpty) return;
    final id = active?.id ?? '';
    if (id.isEmpty) {
      _rememberIce(ready);
      return;
    }
    final body = jsonEncode({'type': 'call-ice', 'call': id, 'candidate': ready});
    if (!ChatLive.instance.sendText(body)) _rememberIce(ready);
  }

  void _sendSdp(String sdp) {
    final ready = callSdpToSend(sdp, _lanIp);
    if (ready.isEmpty) return;
    final id = active?.id ?? '';
    if (id.isEmpty) {
      _sdpPending = ready;
      return;
    }
    final body = jsonEncode({'type': 'call-sdp', 'call': id, 'sdp': ready});
    if (!ChatLive.instance.sendText(body)) {
      _sdpPending = ready;
      return;
    }
    _sdpPending = '';
  }

  void _flushIce() {
    final pending = _sdpPending;
    if (pending.isNotEmpty) {
      _sdpPending = '';
      _sendSdp(pending);
    }
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
    } catch (e) { logQuiet('chat_call', e); }
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
    _syncLink();
  }

  /// Play the other person out loud. The earpiece stays silent on a lot of
  /// phones until the speaker route is set. Windows already chose its speaker
  /// once, when the voice track arrived.
  void hear() {
    if (status != 'active' || _finishing || _routeChosen) return;
    final first = !speaker;
    speaker = true;
    if (Plat.isWindows) {
      if (first) revision.value++;
      return;
    }
    final gen = _routeGen;
    _speakerRetry?.cancel();
    unawaited(_pushSpeaker(gen));
    _speakerRetry = Timer(const Duration(milliseconds: 400), () {
      if (!_speakerStill(gen)) return;
      unawaited(_pushSpeaker(gen));
      _speakerRetry = Timer(const Duration(milliseconds: 800), () {
        if (!_speakerStill(gen)) return;
        unawaited(_pushSpeaker(gen));
      });
    });
    if (first) revision.value++;
  }

  bool _speakerStill(int gen) {
    return gen == _routeGen &&
        status == 'active' &&
        !_finishing &&
        !_routeChosen &&
        speaker;
  }

  /// The first speaker request is often ignored until the voice track exists.
  Future<void> _pushSpeaker(int gen) async {
    await _media.setSpeaker(true);
    if (!_speakerStill(gen)) return;
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
    _routeGen++;
    _callEpoch++;
    _remember(active?.id ?? '');
    _recover?.cancel();
    _recover = null;
    _speakerRetry?.cancel();
    _speakerRetry = null;
    _clock?.cancel();
    _clock = null;
    _presentRetry?.cancel();
    _presentRetry = null;
    _watch?.cancel();
    _watch = null;
    exitKind = kind.isEmpty ? 'ended' : kind;
    revision.value++;
    try {
      await _endRing().timeout(const Duration(seconds: 2));
    } catch (e) { logQuiet('chat_call', e); }
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
    pcAudioBlocked = false;
    allowingPcAudio = false;
    _lastRemote = '';
    _linked = false;
    _hadAudio = false;
    _sdpPending = '';
    _iceBeforeId.clear();
    revision.value++;
    try {
      await _media.close().timeout(const Duration(seconds: 4));
    } catch (e) { logQuiet('chat_call', e); }
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
      barrierColor: ChatUiTokens.canvasDark,
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

  /// A second dialog used to cover End. The call sheet shows Allow itself.
  Future<void> _notePcAudio() async {
    if (!Plat.isWindows) return;
    try {
      final open = await FirewallCheck.callAudioOpen();
      if (_finishing || (status != 'ringing' && status != 'active')) return;
      final blocked = !open;
      if (pcAudioBlocked == blocked) return;
      pcAudioBlocked = blocked;
      revision.value++;
    } catch (e) { logQuiet('chat_call', e); }
  }

  Future<void> allowPcAudio() async {
    if (!Plat.isWindows || allowingPcAudio) return;
    allowingPcAudio = true;
    revision.value++;
    try {
      final err = await FirewallCheck.allowCallAudio();
      if (_finishing) return;
      if (err == null) {
        pcAudioBlocked = false;
      } else {
        problem = err;
      }
    } catch (error) {
      if (!_finishing) problem = chatErrorText(error);
    } finally {
      allowingPcAudio = false;
      if (!_finishing) revision.value++;
    }
  }

  Future<void> _showIncoming(int gen) async {
    if (Plat.isWindows) unawaited(_playRing(gen));
    try {
      await NotificationService().showIncomingCall(peerName, callId: active?.id ?? '');
    } catch (_) {
      if (!Plat.isWindows) await _playRing(gen);
      return;
    }
    if (gen != _ringGen || !_ringOn) {
      await NotificationService().cancelIncomingCall();
    }
  }

  void _beginOutgoingTone() {
    if (_outTone || !outgoing) return;
    if (Plat.isWindows) {
      _outTone = true;
      unawaited(_pcTone.play('assets/sounds/ss_callout.wav'));
      return;
    }
    if (!Plat.isAndroid) return;
    _outTone = true;
    unawaited(_ringback(true));
  }

  Future<void> _stopOutgoingTone() async {
    if (!_outTone) return;
    _outTone = false;
    if (Plat.isWindows) {
      await _pcTone.stop();
      return;
    }
    await _ringback(false);
  }

  final _pcTone = _PcTone();

  Future<void> _ringback(bool on) async {
    try {
      await const MethodChannel('socialsave/media').invokeMethod<void>(
        on ? 'playCallRingback' : 'stopCallRingback',
      );
    } catch (e) { logQuiet('chat_call', e); }
  }

  Future<void> _playRing(int gen) async {
    if (Plat.isWindows) {
      if (gen != _ringGen || !_ringOn) return;
      await _pcTone.play('assets/sounds/ss_ring.wav');
      if (gen != _ringGen || !_ringOn) await _pcTone.stop();
      return;
    }
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
      } catch (e) { logQuiet('chat_call', e); }
    }
  }

  Future<void> _endRing() async {
    _ringGen++;
    _ringOn = false;
    _toneFallback?.cancel();
    _toneFallback = null;
    if (Plat.isWindows) await _pcTone.stop();
    try {
      await const MethodChannel('socialsave/media').invokeMethod<void>('stopCallRingtone');
    } catch (e) { logQuiet('chat_call', e); }
    await _stopOutgoingTone();
    unawaited(NotificationService().cancelIncomingCall());
  }
}

/// `SocialSave.exe --call-selftest <file>`: checks this PC can make calls
/// without placing one. Lists mics and speakers, opens the call mic for a
/// moment, then connects two local call ends through the relay only, and
/// writes what happened to [outPath]. Relay passwords are never written.
Future<bool> runCallSelfTest(String outPath) async {
  final lines = <String>['SocialSave call self-test ${DateTime.now().toIso8601String()}'];
  var ok = true;
  void note(String line) => lines.add(line);
  final media = ChatCallMedia();
  final opened = <MediaStream>[];
  final pcs = <RTCPeerConnection>[];
  try {
    final all = await ChatCallMedia.devices();
    final mics = callDeviceChoices(all, 'audioinput');
    final outs = callDeviceChoices(all, 'audiooutput');
    note('mics=${mics.length} ${mics.map((d) => d.label).join(' | ')}');
    note('speakers=${outs.length} ${outs.map((d) => d.label).join(' | ')}');
    final blocked = await windowsMicBlockedNow();
    note('mic privacy blocked=$blocked');
    final constraints = await media._audioConstraints();
    note('mic constraints=${jsonEncode(constraints)}');
    final mic = await navigator.mediaDevices.getUserMedia(constraints);
    opened.add(mic);
    final tracks = mic.getAudioTracks();
    note('mic open tracks=${tracks.length} label=${tracks.isEmpty ? '' : tracks.first.label}');
    if (tracks.isEmpty) ok = false;

    var servers = chatDefaultIceServers;
    try {
      servers = await ChatApi().callIceServers().timeout(const Duration(seconds: 8));
    } catch (e) {
      note('ice fetch failed: $e');
    }
    final urls = <String>[
      for (final s in servers)
        ...switch (s['urls']) {
          final String u => [u],
          final List<dynamic> l => l.map((e) => '$e'),
          _ => const <String>[],
        },
    ];
    final turn = urls.any((u) => u.startsWith('turn'));
    note('ice servers=${servers.length} turn=$turn urls=${urls.join(' ')}');

    final a = await createPeerConnection(chatCallConfig(servers, relayOnly: turn));
    final b = await createPeerConnection(chatCallConfig(servers, relayOnly: turn));
    pcs..add(a)..add(b);
    final kinds = <String>{};
    final heard = Completer<void>();
    final linked = Completer<void>();
    a.onIceCandidate = (c) {
      final line = c.candidate ?? '';
      final m = RegExp(r' typ (\w+)').firstMatch(line);
      if (m != null) kinds.add(m.group(1)!);
      if (line.isNotEmpty) unawaited(b.addCandidate(c));
    };
    b.onIceCandidate = (c) {
      if ((c.candidate ?? '').isNotEmpty) unawaited(a.addCandidate(c));
    };
    b.onTrack = (e) {
      if (e.track.kind == 'audio' && !heard.isCompleted) heard.complete();
    };
    a.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && !linked.isCompleted) {
        linked.complete();
      }
    };
    for (final t in tracks) {
      await a.addTrack(t, mic);
    }
    final offer = await a.createOffer({'offerToReceiveAudio': true});
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer({'offerToReceiveAudio': true});
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    try {
      await linked.future.timeout(const Duration(seconds: 20));
      note('link=connected via ${turn ? 'relay only' : 'any path'}');
    } catch (_) {
      ok = false;
      note('link=FAILED (state ${a.connectionState})');
    }
    try {
      await heard.future.timeout(const Duration(seconds: 3));
      note('remote audio track=yes');
    } catch (_) {
      ok = false;
      note('remote audio track=no');
    }
    note('candidate types=${kinds.join(',')}');
    if (turn && !kinds.contains('relay')) ok = false;
  } catch (e) {
    ok = false;
    note('error: $e');
  } finally {
    for (final pc in pcs) {
      try {
        await pc.close();
      } catch (_) {}
    }
    for (final s in opened) {
      for (final t in s.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await s.dispose();
      } catch (_) {}
    }
    note('mic released');
    note(ok ? 'RESULT ok' : 'RESULT problem');
    try {
      await File(outPath).writeAsString('${lines.join('\n')}\n');
    } catch (_) {}
  }
  return ok;
}

/// Ring and calling tones on a PC, from the app's own sounds.
class _PcTone {
  Player? _player;

  Future<void> play(String asset) async {
    await stop();
    try {
      final player = Player();
      _player = player;
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.open(Media('asset:///$asset'));
    } catch (e) {
      logQuiet('chat_call.tone', e);
    }
  }

  Future<void> stop() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.dispose();
    } catch (e) { logQuiet('chat_call.tone', e); }
  }
}

/// True when Windows privacy settings stop desktop apps using the mic.
Future<bool> windowsMicBlockedNow() async {
  if (!Plat.isWindows) return false;
  const base = r'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone';
  for (final key in [
    'HKLM\\$base',
    'HKCU\\$base',
    'HKCU\\$base\\NonPackaged',
  ]) {
    try {
      final res = await Process.run('reg', ['query', key, '/v', 'Value'])
          .timeout(const Duration(seconds: 3));
      if (res.exitCode == 0 && windowsMicDenied('${res.stdout}')) return true;
    } catch (e) { logQuiet('chat_call.privacy', e); }
  }
  return false;
}

/// Opens the Windows microphone privacy page.
Future<void> openWindowsMicSettings() async {
  try {
    await launchUrl(Uri.parse('ms-settings:privacy-microphone'));
  } catch (e) { logQuiet('chat_call', e); }
}

bool _skippedAudioLabel(String label) {
  final name = label.toLowerCase();
  if (name.contains('virtual') ||
      name.contains('cable') ||
      name.contains('steam') ||
      name.contains('voicemeeter') ||
      name.contains('blackhole') ||
      name.contains('stereo mix')) {
    return true;
  }
  return name.contains('nvidia') && name.contains('broadcast');
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
    if (call.status == 'active' && !call.audioUp) {
      return callAudioWaitLine(call.elapsed);
    }
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
        return ChatUiTokens.canvasDark;
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
                color: ChatUiTokens.fieldDark,
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
              final bg = Color.lerp(ChatUiTokens.canvasDark, _wash(call.exitKind), _exit.value) ??
                  ChatUiTokens.canvasDark;
              final beat = pulse <= 0.5 ? pulse * 2 : (1 - pulse) * 2;
              final textOpacity = call.recovering && !leaving ? 0.45 + 0.55 * beat : 1.0;
              final ringColor = call.outgoing ? ChatUiTokens.linkDark : ChatUiTokens.brand;
              return Material(
                color: bg,
                child: Opacity(
                  opacity: fade,
                  child: Transform.translate(
                    offset: Offset(0, drop),
                    child: SafeArea(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final short = box.maxHeight < 560;
                          final end = _CallAction(
                            color: ChatUiTokens.danger,
                            icon: Icons.call_end_rounded,
                            label: 'End',
                            onPressed: () => unawaited(call.hangUp()),
                          );
                          final controls = <Widget>[
                            _CallAction(
                              color: ChatUiTokens.fieldDark,
                              icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                              label: call.muted ? 'Unmute' : 'Mute',
                              onPressed: () => unawaited(call.setMuted(!call.muted)),
                            ),
                            if (call.status == 'active')
                              _CallAction(
                                color: call.held ? const Color(0xFFF9A825) : ChatUiTokens.fieldDark,
                                icon: call.held ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                label: call.held ? 'Resume' : 'Hold',
                                onPressed: () => unawaited(call.setHeld(!call.held)),
                              ),
                            if (Plat.isWindows)
                              _CallAction(
                                color: ChatUiTokens.fieldDark,
                                icon: Icons.headset_mic_rounded,
                                label: 'Devices',
                                onPressed: () => unawaited(showCallDevices(context)),
                              )
                            else
                            _CallAction(
                              color: ChatUiTokens.fieldDark,
                              icon: call.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                              label: call.speaker ? 'Speaker' : 'Earpiece',
                              onPressed: () async {
                                final ok = await call.setSpeaker(!call.speaker);
                                if (!ok && context.mounted) {
                                  AppSnack.error(context, "Couldn't switch the speaker. Please try again.");
                                }
                              },
                            ),
                            if (short) end,
                          ];
                          return Padding(
                            padding: EdgeInsets.fromLTRB(28, short ? 12 : 36, 28, short ? 12 : 28),
                            child: Column(
                              children: [
                                Expanded(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: SizedBox(
                                      width: box.maxWidth > 80 ? box.maxWidth - 56 : box.maxWidth,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
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
                                          const SizedBox(height: AppSpacing.sm),
                                          Opacity(
                                            opacity: textOpacity,
                                            child: Text(
                                              _line(call),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 16,
                                                color: leaving ? Colors.white : ChatUiTokens.timeDark,
                                                fontWeight: leaving ? FontWeight.w700 : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (!leaving && Plat.isWindows && (call.problem ?? '').contains('Privacy'))
                                  TextButton(
                                    onPressed: () => unawaited(openWindowsMicSettings()),
                                    child: const Text(
                                      'Open microphone settings',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                if (!leaving && Plat.isWindows && (call.problem ?? '').contains('Devices'))
                                  TextButton(
                                    onPressed: () => unawaited(showCallDevices(context)),
                                    child: const Text(
                                      'Choose a microphone',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                if (!leaving &&
                                    call.status == 'ringing' &&
                                    !call.outgoing &&
                                    call.moment != 'accept')
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: [
                                      _CallAction(
                                        color: ChatUiTokens.danger,
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
                                  if (call.pcAudioBlocked && !call.audioUp)
                                    TextButton(
                                      onPressed: call.allowingPcAudio
                                          ? null
                                          : () => unawaited(call.allowPcAudio()),
                                      child: Text(
                                        call.allowingPcAudio ? 'Asking Windows…' : 'Allow call audio',
                                        style: const TextStyle(color: Colors.white),
                                      ),
                                    ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: controls,
                                  ),
                                  if (!short) ...[
                                    const SizedBox(height: 22),
                                    end,
                                  ],
                                ] else if (!leaving) ...[
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    child: const Text('Close'),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
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

/// A PC picks its call microphone and speaker here. The choice is kept for
/// the next call.
Future<void> showCallDevices(BuildContext context) async {
  final all = await ChatCallMedia.devices();
  final mic = ChatCalls.instance.micInUse ?? await ChatCallMedia.savedDevice(ChatCallMedia.micKey);
  final out = await ChatCallMedia.savedDevice(ChatCallMedia.speakerKey);
  if (!context.mounted) return;
  final mics = callDeviceChoices(all, 'audioinput');
  final speakers = callDeviceChoices(all, 'audiooutput');
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      Widget section(String title, List<MediaDeviceInfo> items, String? current, Future<void> Function(MediaDeviceInfo) pick) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(title, style: Theme.of(sheet).textTheme.titleSmall),
            ),
            if (items.isEmpty)
              const ListTile(title: Text('None found')),
            for (final d in items)
              ListTile(
                leading: Icon(
                  d.deviceId == current ? Icons.radio_button_checked : Icons.radio_button_off,
                ),
                title: Text(d.label.isEmpty ? 'Device' : d.label),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  await pick(d);
                },
              ),
          ],
        );
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              section('Microphone', mics, mic, (d) async {
                final err = await ChatCalls.instance.chooseMic(d.deviceId);
                if (err != null && context.mounted) AppSnack.error(context, err);
              }),
              section('Speaker or headset', speakers, out, (d) => ChatCalls.instance.chooseSpeaker(d.deviceId)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}

/// Real devices of one kind, without duplicates or virtual cables.
List<MediaDeviceInfo> callDeviceChoices(List<MediaDeviceInfo> all, String kind) {
  final seen = <String>{};
  return [
    for (final d in all)
      if (d.kind == kind &&
          d.deviceId.isNotEmpty &&
          !_skippedAudioLabel(d.label.toLowerCase()) &&
          seen.add(d.deviceId))
        d,
  ];
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
            tooltip: label,
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
        const SizedBox(height: AppSpacing.sm),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}
