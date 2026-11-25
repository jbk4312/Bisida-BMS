import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'bms_protocol.dart';

/// UUID를 고정하지 않는 BMS 서비스.
///
/// 연결 후 GATT 전체를 탐색해서
///  1) 표준 서비스(0x1800, 0x1801, 0x180A, 0x180F)를 제외하고
///  2) NOTIFY/INDICATE 특성 + WRITE 특성 조합을 후보로 만든 뒤
///  3) 후보마다 실시간 데이터(0x41) 요청을 보내 유효한 응답이 오는 조합을 채택합니다.
class BmsService extends ChangeNotifier {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _pollTimer;
  Completer<bool>? _probe;
  final _assembler = BmsFrameAssembler();

  bool connected = false;
  bool connecting = false;
  String? error;
  BmsBaseInfo? baseInfo;
  List<int> cellsMv = const [];
  DateTime? lastUpdate;

  // RawPanel용 원시 데이터 상태
  Uint8List? rawLive;
  Uint8List? prevRawLive;

  /// 자동 탐지된 UUID (화면 표시/로그용)
  String? activeServiceUuid;
  String? activeNotifyUuid;
  String? activeWriteUuid;

  String get deviceName => _device?.platformName.isNotEmpty == true
      ? _device!.platformName
      : (_device?.remoteId.str ?? '');

  static const _stdShort = {'1800', '1801', '180a', '180f'};

  static bool _isStandardService(Guid g) {
    final s = g.str128.toLowerCase();
    if (!s.endsWith('-0000-1000-8000-00805f9b34fb')) return false;
    return _stdShort.contains(s.substring(4, 8));
  }

  static bool _canNotify(BluetoothCharacteristic c) =>
      c.properties.notify || c.properties.indicate;

  static bool _canWrite(BluetoothCharacteristic c) =>
      c.properties.write || c.properties.writeWithoutResponse;

  List<_Candidate> _findCandidates(List<BluetoothService> services) {
    final out = <_Candidate>[];
    for (final svc in services) {
      if (_isStandardService(svc.uuid)) continue;
      final notifies = svc.characteristics.where(_canNotify).toList();
      final writes = svc.characteristics.where(_canWrite).toList();
      for (final n in notifies) {
        // 같은 특성이 notify+write를 모두 지원하면 그것을 우선
        final sorted = [
          ...writes.where((w) => w.uuid == n.uuid),
          ...writes.where((w) => w.uuid != n.uuid),
        ];
        for (final w in sorted) {
          out.add(_Candidate(svc.uuid, n, w));
        }
      }
    }
    return out;
  }

  Future<void> connect(BluetoothDevice device) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      await FlutterBluePlus.stopScan();
      _device = device;
      await device.connect(timeout: const Duration(seconds: 15));

      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _cleanup();
          error = '연결이 끊어졌습니다.';
          notifyListeners();
        }
      });

      final services = await device.discoverServices();
      final candidates = _findCandidates(services);
      if (candidates.isEmpty) {
        throw Exception('NOTIFY + WRITE 가능한 BMS 특성을 찾지 못했습니다.');
      }

      _Candidate? found;
      for (final c in candidates) {
        if (await _probeCandidate(c)) {
          found = c;
          break;
        }
      }
      if (found == null) {
        throw Exception(
            'BMS 응답이 없습니다. (후보 ${candidates.length}개 시도)\n'
            '프로토콜이 다르거나 인증이 필요한 장치일 수 있습니다.');
      }

      activeServiceUuid = found.service.str128;
      activeNotifyUuid = found.notify.uuid.str128;
      activeWriteUuid = found.write.uuid.str128;
      debugPrint('BMS service=$activeServiceUuid '
          'notify=$activeNotifyUuid write=$activeWriteUuid');

      connected = true;
      connecting = false;
      notifyListeners();

      _startPolling();
    } catch (e) {
      error = e.toString();
      connecting = false;
      await disconnect();
    }
  }

  /// 후보 조합으로 실시간 데이터(0x41)를 요청해 유효한 프레임이 오는지 확인.
  Future<bool> _probeCandidate(_Candidate c) async {
    try {
      _assembler.clear();
      _probe = Completer<bool>();
      await c.notify.setNotifyValue(true);
      _notifySub = c.notify.onValueReceived.listen(_onData);
      _writeChar = c.write;
      _notifyChar = c.notify;

      await _write(c.write, BmsProtocol.liveRequest);
      final ok = await _probe!.future
          .timeout(const Duration(milliseconds: 2000), onTimeout: () => false);
      if (ok) return true;
    } catch (e) {
      debugPrint('probe 실패 (${c.notify.uuid.str128}): $e');
    }

    // 실패 → 정리 후 다음 후보
    await _notifySub?.cancel();
    _notifySub = null;
    try {
      await c.notify.setNotifyValue(false);
    } catch (_) {}
    _writeChar = null;
    _notifyChar = null;
    return false;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final c = _writeChar;
    if (c == null || !connected) return;
    try {
      await _write(c, BmsProtocol.liveRequest);
    } catch (e) {
      error = '전송 실패: $e';
      notifyListeners();
    }
  }

  Future<void> _write(BluetoothCharacteristic c, Uint8List data) {
    final withoutResp =
        c.properties.writeWithoutResponse && !c.properties.write;
    return c.write(data, withoutResponse: withoutResp);
  }

  void _onData(List<int> chunk) {
    for (final f in _assembler.add(chunk)) {
      if (f.cmd != BmsProtocol.cmdLive) continue;

      try {
        final live = BmsProtocol.parseLive(f.payload);
        if (live != null) {
          prevRawLive = rawLive;
          rawLive = live.payload;

          baseInfo = BmsBaseInfo(voltage: live.voltage, current: live.current);
          cellsMv = live.cellsMv;
          error = null;
          lastUpdate = DateTime.now();

          final p = _probe;
          if (p != null && !p.isCompleted) p.complete(true);

          notifyListeners();
        }
      } catch (e) {
        error = '파싱 오류: $e';
        notifyListeners();
      }
    }
  }

  void _cleanup() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    final p = _probe;
    if (p != null && !p.isCompleted) p.complete(false);
    _probe = null;
    _assembler.clear();
    _writeChar = null;
    _notifyChar = null;
    connected = false;
    connecting = false;
  }

  Future<void> disconnect() async {
    final d = _device;
    _cleanup();
    _device = null;
    try {
      await d?.disconnect();
    } catch (_) {}
    baseInfo = null;
    cellsMv = const [];
    rawLive = null;
    prevRawLive = null;
    activeServiceUuid = null;
    activeNotifyUuid = null;
    activeWriteUuid = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}

class _Candidate {
  final Guid service;
  final BluetoothCharacteristic notify;
  final BluetoothCharacteristic write;
  _Candidate(this.service, this.notify, this.write);
}
