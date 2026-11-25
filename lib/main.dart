import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'bms_service.dart';
import 'raw_panel.dart';

void main() => runApp(const BmsApp());

class BmsApp extends StatelessWidget {
  const BmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMS Monitor',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ScanPage(),
    );
  }
}

// ───────────────────────── 스캔 화면 ─────────────────────────

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _service = BmsService();
  String? _msg;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<bool> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final res = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse, // Android 11 이하 스캔용
      ].request();
      return res[Permission.bluetoothScan]!.isGranted ||
          res[Permission.locationWhenInUse]!.isGranted;
    }
    return true;
  }

  Future<void> _startScan() async {
    setState(() => _msg = null);
    if (!await _ensurePermissions()) {
      setState(() => _msg = '블루투스 권한이 필요합니다.');
      return;
    }
    if (await FlutterBluePlus.adapterState.first !=
        BluetoothAdapterState.on) {
      if (Platform.isAndroid) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
      }
      setState(() => _msg = '블루투스를 켜 주세요.');
    }
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      // 일부 BMS는 서비스 UUID를 광고하지 않으므로 필터를 걸지 않고 이름으로 보여줍니다.
    );
  }

  Future<void> _open(BluetoothDevice d, String displayName) async {
    await _service.connect(d);
    if (!mounted) return;
    if (_service.connected) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DashboardPage(
            service: _service,
            deviceName: displayName, // 커스텀 이름 전달
            )),
      );
      await _service.disconnect();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_service.error ?? '연결 실패')),
      );
    }
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    _service.dispose();
    super.dispose();
  }
// 알고 있는 MAC 주소와 커스텀 이름 매핑
  final Map<String, String> knownDevices = {
    'xx:xx:xx:xx:xx:xx': '????', // Enter your mac address & the preferred name 

  };
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BMS 검색')),
      floatingActionButton: StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (_, snap) => FloatingActionButton.extended(
          onPressed: snap.data! ? FlutterBluePlus.stopScan : _startScan,
          icon: Icon(snap.data! ? Icons.stop : Icons.search),
          label: Text(snap.data! ? '중지' : '다시 검색'),
        ),
      ),
      body: Column(
        children: [
          if (_msg != null)
            MaterialBanner(
                content: Text(_msg!), actions: const [SizedBox.shrink()]),
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              initialData: const [],
              builder: (_, snap) {
                final list = [...snap.data!]
                  ..sort((a, b) {
                    final an = a.device.platformName.isEmpty ? 1 : 0;
                    final bn = b.device.platformName.isEmpty ? 1 : 0;
                    if (an != bn) return an - bn;
                    return b.rssi.compareTo(a.rssi);
                  });
                if (list.isEmpty) {
                  return const Center(child: Text('주변 BLE 장치를 검색 중…'));
                }
                // 1. customName이 등록된 기기만 필터링
                final filteredList = list.where((r) {
                final mac = r.device.remoteId.str.toUpperCase();
                return knownDevices[mac] != null;
                }).toList();
                
                // 필터링된 기기가 하나도 없을 때 처리 (선택 사항)
                if (filteredList.isEmpty) {
                return const Center(child: Text('등록된 BMS 장치를 검색 중…'));
                }
                
                return ListView.separated(
                  //itemCount: list.length,
                  itemCount: filteredList.length, // <-- 여기를 list.length에서 filteredList.length
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    //final r = list[i];
                    //final mac = r.device.remoteId.str.toUpperCase();
        
                    // 1순위: 매핑된 이름, 2순위: 기기 기본 이름, 3순위: '(이름 없음)'
                    //final customName = knownDevices[mac];
                    //final defaultName = r.device.platformName.isEmpty ? '(이름 없음)' : r.device.platformName;
                    //final displayName = customName ?? defaultName;
                      
                      final r = filteredList[i];
                      final mac = r.device.remoteId.str.toUpperCase();
                      final displayName = knownDevices[mac]!; // 이미 필터링했으므로 안전하게 '!' 사용 
                      
                      return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(displayName),
                      subtitle: Text(mac),
                      trailing: Text('${r.rssi} dBm'),
                      onTap: () => _open(r.device, displayName),
                   
                   
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 대시보드 ─────────────────────────

class DashboardPage extends StatelessWidget {
  final BmsService service;
  final String deviceName; // 1. 변수 추가
  const DashboardPage({
    super.key, 
    required this.service,
    required this.deviceName, // 2. 생성자 추가
    });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        // 연결이 끊기면 자동으로 스캔 화면으로 복귀
        if (!service.connected && !service.connecting) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
        }
        final info = service.baseInfo;
        final cells = service.cellsMv;

        return Scaffold(
          appBar: AppBar(
            //title: Text(service.deviceName),
            title: Text(deviceName),
            actions: [
              IconButton(
                icon: const Icon(Icons.link_off),
                tooltip: '연결 해제',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          body: info == null && cells.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: '전체 전압',
                            value: info == null
                                ? '--'
                                : info.voltage.toStringAsFixed(2),
                            unit: 'V',
                            icon: Icons.bolt,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _StatCard(
                            label: '전체 전류',
                            value: info?.current == null
                                ? '--'
                               : info?.current.toStringAsFixed(2) ?? '0.00',
                               
                            unit: 'A',
                            icon: Icons.electric_meter,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _CellSection(cellsMv: cells),
                    const SizedBox(height: 16),
                    //RawPanel(service: service),
                    if (service.error != null) ...[
                      const SizedBox(height: 16),
                      Text(service.error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label, value, unit;
  final IconData icon;
  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Flexible(
                  child: Text(label,
                      style: Theme.of(context).textTheme.labelMedium)),
            ]),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                Text(unit),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CellSection extends StatelessWidget {
  final List<int> cellsMv;
  const _CellSection({required this.cellsMv});

  @override
  Widget build(BuildContext context) {
    if (cellsMv.isEmpty) {
      return const Text('셀 전압 수신 대기 중…');
    }
    final minV = cellsMv.reduce((a, b) => a < b ? a : b);
    final maxV = cellsMv.reduce((a, b) => a > b ? a : b);
    final diff = maxV - minV;
    final cs = Theme.of(context).colorScheme;

    // 막대 길이용 범위 (Li-ion 2.5~4.2V 가정, 벗어나면 실제 min/max로 확장)
    final lo = minV < 2500 ? minV : 2500;
    final hi = maxV > 4200 ? maxV : 4200;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('셀 전압 (${cellsMv.length}S)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '최소 ${(minV / 1000).toStringAsFixed(3)} V · '
          '최대 ${(maxV / 1000).toStringAsFixed(3)} V · '
          '편차 $diff mV',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < cellsMv.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text('#${i + 1}',
                      style: const TextStyle(fontFeatures: [])),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 14,
                      value: ((cellsMv[i] - lo) / (hi - lo)).clamp(0.0, 1.0),
                      color: cellsMv[i] == maxV && diff > 0
                          ? Colors.orangeAccent
                          : cellsMv[i] == minV && diff > 0
                              ? Colors.lightBlueAccent
                              : cs.primary,
                    ),
                  ),
                ),
                SizedBox(
                  width: 78,
                  child: Text(
                    '${(cellsMv[i] / 1000).toStringAsFixed(3)} V',
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
