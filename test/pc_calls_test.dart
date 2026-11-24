import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_call.dart';

void main() {
  test('the PC app places and receives calls again', () {
    expect(callsOnThisDevice(windows: true), isTrue);
    expect(callsOnThisDevice(windows: false), isTrue);
  });

  test('a Windows mic privacy switch set to Deny is noticed', () {
    const denied = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone
    Value    REG_SZ    Deny
''';
    const allowed = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone
    Value    REG_SZ    Allow
''';
    expect(windowsMicDenied(denied), isTrue);
    expect(windowsMicDenied(allowed), isFalse);
    expect(windowsMicDenied(''), isFalse);
  });

  test('mic problems say what to do', () {
    expect(windowsMicProblem(blocked: true, mics: 1), contains('Privacy'));
    expect(windowsMicProblem(blocked: false, mics: 0), contains('No microphone'));
    expect(windowsMicProblem(blocked: false, mics: 2), contains('Devices'));
  });

  test('a saved device is used only while it is plugged in', () {
    expect(callSavedDevice('abc', ['abc', 'def']), 'abc');
    expect(callSavedDevice('gone', ['abc']), isNull);
    expect(callSavedDevice('', ['abc']), isNull);
    expect(callSavedDevice(null, ['abc']), isNull);
  });

  test('the relay-only setting is used for the self-test', () {
    final servers = [
      {'urls': ['turn:turn.example:3478'], 'username': 'u', 'credential': 'c'},
    ];
    expect(chatCallConfig(servers)['iceTransportPolicy'], 'all');
    expect(chatCallConfig(servers, relayOnly: true)['iceTransportPolicy'], 'relay');
    expect(chatCallConfig(const [])['iceServers'], chatDefaultIceServers);
  });

  test('the Devices picker lists real devices once each', () {
    final all = [
      MediaDeviceInfo(kind: 'audioinput', label: 'Microphone (Realtek)', deviceId: 'm1'),
      MediaDeviceInfo(kind: 'audioinput', label: 'Microphone (Realtek)', deviceId: 'm1'),
      MediaDeviceInfo(kind: 'audioinput', label: 'CABLE Output (VB-Audio Virtual Cable)', deviceId: 'v1'),
      MediaDeviceInfo(kind: 'audioinput', label: 'Headset mic', deviceId: 'm2'),
      MediaDeviceInfo(kind: 'audiooutput', label: 'Speakers (Realtek)', deviceId: 's1'),
      MediaDeviceInfo(kind: 'videoinput', label: 'Webcam', deviceId: 'c1'),
    ];
    expect(callDeviceChoices(all, 'audioinput').map((d) => d.deviceId), ['m1', 'm2']);
    expect(callDeviceChoices(all, 'audiooutput').map((d) => d.deviceId), ['s1']);
  });
}
