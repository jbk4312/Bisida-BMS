import 'dart:typed_data';

/// BSD_BMS 계열 프로토콜 (Wireshark 캡처로 역분석).
///
/// 요청:  [3A 9D 21 01][cmd][len][payload...][체크섬]
/// 응답:  [3B 9D 21 01][cmd][len][payload...][체크섬]
///
/// 체크섬 계산식은 아직 모릅니다. 그래서 앱이 실제로 보내는 요청을
/// 그대로 재사용하고, 응답 체크섬은 검증하지 않습니다.
class BmsProtocol {
  /// 실시간 데이터 요청 (앱이 1초마다 전송). 캡처한 실제 바이트.
  static final Uint8List liveRequest =
      Uint8List.fromList(const [0x3A, 0x9D, 0x21, 0x01, 0x41, 0x00, 0x5A]);

  static const int cmdLive = 0x41;
  static const List<int> respHeader = [0x3B, 0x9D, 0x21, 0x01];

  // ── 0x41 응답 payload 안의 위치 (payload = 프레임의 6번째 바이트부터) ──
  static const int offPackVoltage = 12; // u16 LE, 0.01V
  static const int offCurrent = 14; // i16 LE, 0.01A (+충전 추정)
  static const int offMaxCell = 40; // u16 LE, mV
  static const int offMinCell = 42; // u16 LE, mV
  static const int offCellCount = 23; // u8
  static const int offCells = 48; // u16 LE × N, mV

  static int _u16(Uint8List d, int i) => d[i] | (d[i + 1] << 8);

  static int _i16(Uint8List d, int i) {
      final v = _u16(d, i);
      return v >= 0x8000 ? v - 0x10000 : v;
  }

  /// 0x41 payload → 실시간 값. 형식이 맞지 않으면 null.
  static BmsLive? parseLive(Uint8List p) {
    if (p.length < offCells + 2) return null;

    final voltage = _u16(p, offPackVoltage) * 0.01;
    final current = _i16(p, offCurrent) * 0.01;

    // 셀 개수: payload에 들어 있는 값을 우선 사용, 이상하면 값 범위로 추정
    final cells = <int>[];
    final n = p[offCellCount];
    if (n >= 1 && n <= 32 && offCells + 2 * n <= p.length) {
      for (var i = 0; i < n; i++) {
        cells.add(_u16(p, offCells + 2 * i));
      }
    } else {
      for (var i = offCells; i + 1 < p.length && cells.length < 32; i += 2) {
        final v = _u16(p, i);
        if (v < 2000 || v > 4600) break;
        cells.add(v);
      }
    }
    if (cells.isEmpty) return null;

    return BmsLive(
      voltage: voltage,
      current: current,
      cellsMv: cells,
      maxMv: _u16(p, offMaxCell),
      minMv: _u16(p, offMinCell),
      payload: p,
    );
  }
}

class BmsLive {
  final double voltage; // V
  final double current; // A
  final List<int> cellsMv;
  final int maxMv;
  final int minMv;
  final Uint8List payload;
  const BmsLive({
    required this.voltage,
    required this.current,
    required this.cellsMv,
    required this.maxMv,
    required this.minMv,
    required this.payload,
  });
}

/// UI용 요약. 전류는 payload 위치를 아직 못 찾아서 null.
class BmsBaseInfo {
  final double voltage;
  final double current;
  const BmsBaseInfo({required this.voltage, required this.current});
}

class BmsFrame {
  final int cmd;
  final Uint8List payload;
  const BmsFrame(this.cmd, this.payload);
}

/// notify가 MTU 단위로 쪼개져 와도 프레임을 재조립합니다.
class BmsFrameAssembler {
  final List<int> _buf = [];

  int _findHeader() {
    final h = BmsProtocol.respHeader;
    for (var i = 0; i + 4 <= _buf.length; i++) {
      if (_buf[i] == h[0] &&
          _buf[i + 1] == h[1] &&
          _buf[i + 2] == h[2] &&
          _buf[i + 3] == h[3]) {
        return i;
      }
    }
    return -1;
  }

  List<BmsFrame> add(List<int> chunk) {
    _buf.addAll(chunk);
    final frames = <BmsFrame>[];
    while (true) {
      final s = _findHeader();
      if (s < 0) {
        // 헤더가 두 조각에 걸쳐 올 수 있으니 끝 3바이트는 남겨 둠
        if (_buf.length > 3) _buf.removeRange(0, _buf.length - 3);
        break;
      }
      if (s > 0) _buf.removeRange(0, s);
      if (_buf.length < 6) break;

      final len = _buf[5];
      final total = 7 + len; // 헤더4 + cmd + len + payload + 체크섬
      if (_buf.length < total) break;

      frames.add(BmsFrame(
          _buf[4], Uint8List.fromList(_buf.sublist(6, 6 + len))));
      _buf.removeRange(0, total);
    }
    return frames;
  }

  void clear() => _buf.clear();
}
