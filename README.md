(![GitHub Downloads](https://shields.io))

# BMS Monitor (Flutter)

BSD_BMS 계열(서비스 `00002748-08c2-11e1-9073-0e8ac72e1001`) BLE BMS에서 **전체 전압 / 셀 전압**을 1초마다 읽어 보여 주는 앱입니다.
프로토콜은 Wireshark(HCI snoop) 캡처로 역분석했습니다.

## 실행

```bash
flutter create --org com.example --project-name bms_monitor .   # android/ios 폴더 생성 (lib, pubspec은 덮어쓰지 않도록 주의)
flutter pub get
flutter run
```

`flutter create .` 후 Android/iOS 블루투스 권한을 추가하세요.

### Android — `android/app/src/main/AndroidManifest.xml` (`<application>` 위)

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
```

`android/app/build.gradle`의 `minSdkVersion`은 21 이상.

### iOS — `ios/Runner/Info.plist`

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>BMS 장치에 연결하기 위해 블루투스가 필요합니다.</string>
```

## 프로토콜 요약

| 항목 | 값 |
| --- | --- |
| Write (WRITE NO RESPONSE) | `00002748-08c2-11e1-9073-0e8ac72e0001` |
| Notify | `00002748-08c2-11e1-9073-0e8ac72e0002` |
| 프레임 | `[3A/3B 9D 21 01][cmd][len][payload][체크섬]` (요청 3A, 응답 3B) |
| 실시간 요청 | `3A 9D 21 01 41 00 5A` (1초마다) |
| 응답 `0x41` (payload 84B) | 전체 전압 = payload[12..13] LE ×0.01V, 셀 개수 = payload[23], 셀 전압 = payload[48..] LE mV |

- 체크섬 계산식은 미확인이라 캡처한 요청을 그대로 사용하고, 응답 체크섬은 검증하지 않습니다.
- **전류 위치는 아직 미확인**입니다. 앱의 "원시 데이터" 패널에서 충전/방전 중 값이 바뀌는 바이트(주황색)를 보고 찾을 수 있습니다.
- `0x62`는 이력 기록 조회로 보이며 앱에서는 사용하지 않습니다.

## 구조

| 파일 | 역할 |
| --- | --- |
| `lib/bms_protocol.dart` | 요청 바이트, 프레임 재조립, 0x41 파싱 |
| `lib/bms_service.dart` | 연결, 특성 자동 탐지, MTU 요청, 1초 폴링 |
| `lib/raw_panel.dart` | 원시 payload와 변경 바이트 표시 (전류 위치 찾기용) |
| `lib/main.dart` | 스캔 화면 + 대시보드 |
