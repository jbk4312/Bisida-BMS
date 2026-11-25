import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bms_service.dart';

/// 0x41 응답의 원시 payload를 16바이트씩 보여주고,
/// 직전 프레임과 달라진 바이트를 주황색으로 표시합니다.
/// 충전/방전 중 값이 바뀌는 위치를 찾아 전류 필드를 알아내는 용도입니다.
class RawPanel extends StatelessWidget {
  final BmsService service;
  const RawPanel({super.key, required this.service});

  String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

  @override
  Widget build(BuildContext context) {
    final raw = service.rawLive;
    final prev = service.prevRawLive;

    return Card(
      child: ExpansionTile(
        title: const Text('원시 데이터 (전류 위치 찾기용)'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (raw == null)
            const Text('수신 대기 중…')
          else ...[
            const Text(
              '주황색 = 직전 프레임에서 값이 바뀐 바이트.\n'
              '충전/방전 중 전류를 바꿔 가며 어떤 바이트가 움직이는지 확인하세요.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (var row = 0; row * 16 < raw.length; row++)
              Text.rich(
                TextSpan(
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12, height: 1.5),
                  children: [
                    TextSpan(
                        text: '${(row * 16).toString().padLeft(3, '0')}: ',
                        style: const TextStyle(color: Colors.grey)),
                    for (var i = row * 16;
                        i < (row + 1) * 16 && i < raw.length;
                        i++)
                      TextSpan(
                        text: '${_hex(raw[i])} ',
                        style: TextStyle(
                          color: prev != null &&
                                  i < prev.length &&
                                  prev[i] != raw[i]
                              ? Colors.orangeAccent
                              : null,
                          fontWeight: prev != null &&
                                  i < prev.length &&
                                  prev[i] != raw[i]
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('16진수 복사'),
              onPressed: () {
                final s = raw.map(_hex).join(' ');
                Clipboard.setData(ClipboardData(text: s));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('복사했습니다.')),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
