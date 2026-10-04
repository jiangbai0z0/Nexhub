/// 源级网络覆盖页 Widget 测试（导入沿用源 network 块）。
///
/// - 源 JSON 自带 `network` 块（代理 manual + hosts）：打开覆盖页直接沿用
/// 源自带配置（开关开启、字段回填、显示「已自动沿用」提示），无需重新配置。
/// - 源无 `network` 块：各字段为空、显示「继承全局」，不显示沿用提示。
/// - 保存：**只把与源文件真正不同的方面**写入 [SourceNetworkOverrideStore]。
///   没改过的方面留空 = 继续继承源文件，源文件更新后能跟着一起更新。
///   这是真机故障（陈旧用户覆盖里的坏 IP 把新源文件可用 IP 全屏蔽）的回归防线。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/network_config_service.dart';
import 'package:nexhub/core/network/source_network_override_store.dart';
import 'package:nexhub/features/sources/presentation/source_network_override_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

PluginConfig _sourceWithNetwork(Map<String, dynamic> network) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'net_seed_test',
      'name': '自带网络配置源',
      'type': 'mangaSource',
      'site': <String, dynamic>{
        'domain': 'example.com',
        'baseUrl': 'https://example.com',
      },
      if (network.isNotEmpty) 'network': network,
    });

Widget _wrap(PluginConfig source) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: SourceNetworkOverrideScreen(source: source),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // onSourceOverrideChanged 会重建 HttpFetcher（读取高级设置）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    // 清理单例缓存，避免用例间串扰。
    await SourceNetworkOverrideStore.instance.remove('net_seed_test');
    NetworkConfigService.instance.onSourceOverrideChanged();
  });

  testWidgets('源自带 network 块：覆盖页直接沿用，无需重新配置',
      (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
      'hosts': <Map<String, dynamic>>[
        <String, dynamic>{'ip': '1.2.3.4', 'host': 'cdn.example.com'},
      ],
    });

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();

    // 沿用提示可见。
    expect(find.textContaining('已自动沿用'), findsOneWidget);
    // 代理方面随源配置开启，字段回填源值。
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('7890'), findsOneWidget);
    // Hosts 方面同样开启并展示源自带条目（需滚动到视口内）。
    await tester.scrollUntilVisible(
      find.textContaining('1.2.3.4'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('1.2.3.4'), findsOneWidget);
  });

  testWidgets('源无 network 块：字段为空并继承全局', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(_sourceWithNetwork(const <String, dynamic>{})));
    await tester.pumpAndSettle();

    expect(find.textContaining('已自动沿用'), findsNothing);
    expect(find.text('继承全局'), findsWidgets);
    expect(find.text('127.0.0.1'), findsNothing);
  });

  testWidgets('未改动任何方面时保存：不落盘覆盖（全继承源文件）',
      (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
      'hosts': <Map<String, dynamic>>[
        <String, dynamic>{'ip': '1.2.3.4', 'host': 'cdn.example.com'},
      ],
    });
    expect(SourceNetworkOverrideStore.instance.get('net_seed_test'), isNull);

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();
    // 保存按钮在长列表底部，先滚进视口再点击。
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 点保存但没改过任何东西 ⇒ 不产生用户覆盖：源文件更新后仍能生效。
    expect(
      SourceNetworkOverrideStore.instance.get('net_seed_test'),
      isNull,
      reason: '未改动的方面不应被固化成用户覆盖，否则源文件更新会被永久挡住',
    );
  });

  testWidgets('保存只落盘真正改动的方面，且源文件更新后未改动方面跟随更新',
      (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
      'hosts': <Map<String, dynamic>>[
        <String, dynamic>{'ip': '1.2.3.4', 'host': 'cdn.example.com'},
      ],
    });

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();

    // 只改代理主机（其余方面保持沿用源文件）。
    await tester.enterText(
      find.widgetWithText(TextField, '127.0.0.1'),
      '10.0.0.1',
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = SourceNetworkOverrideStore.instance.get('net_seed_test');
    expect(saved, isNotNull);
    // 改过的方面落盘。
    expect(saved!.proxy?.host, '10.0.0.1');
    expect(saved.proxy?.port, 7890);
    // 没改过的方面保持 null = 继续继承源文件，源文件更新后能跟着走。
    expect(saved.hosts, isNull, reason: 'hosts 未改动，不得被钉进用户覆盖');
    expect(saved.dns, isNull);
    expect(saved.sni, isNull);
    expect(saved.ech, isNull);

    // 端到端：源文件更新 hosts 后，未改动的 hosts 方面必须跟随源文件更新，
    // 而用户改过的 proxy 仍以用户覆盖为准。
    final updated = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
      'hosts': <Map<String, dynamic>>[
        <String, dynamic>{'ip': '9.9.9.9', 'host': 'cdn.example.com'},
      ],
    });
    final profile = NetworkConfigService.instance.effectiveFor(updated);
    expect(
      profile.hosts.map((h) => h.ip),
      contains('9.9.9.9'),
      reason: '源文件新 hosts 必须生效（真机故障：陈旧覆盖的坏 IP 屏蔽新源文件 IP）',
    );
    expect(profile.hosts.map((h) => h.ip), isNot(contains('1.2.3.4')));
    expect(profile.proxy.host, '10.0.0.1');
  });

  testWidgets('清空 SNI 默认值：删除动作必须落盘，不得被静默丢弃',
      (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'sni': <String, dynamic>{
        'enabled': true,
        'defaultSni': 'old.example.com',
      },
    });

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();

    // 用户清空 SNI 默认值输入框，这是「删掉这个覆盖」的显式动作。
    await tester.enterText(
      find.widgetWithText(TextField, 'old.example.com'),
      '',
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 清空是一次真实改动 ⇒ 必须以用户覆盖落盘。若用 copyWith 传 null，它会被
    // `x ?? this.x` 当成「保持原值」，改动被判成「与源文件相同」而整份不落盘
    // ⇒ 用户删了却还在。所以这里断言覆盖存在且 sni 方面被显式写入。
    final saved = SourceNetworkOverrideStore.instance.get('net_seed_test');
    expect(
      saved,
      isNotNull,
      reason: '清空 SNI 默认值是用户的显式改动，必须落盘而非被丢弃',
    );
    expect(saved!.sni, isNotNull);
    expect(saved.sni!.defaultSni, isNull);

    // 端到端：运行时确实不再带上被删掉的 SNI 值。
    final profile = NetworkConfigService.instance.effectiveFor(source);
    expect(
      profile.sni.defaultSni,
      isNull,
      reason: '用户清空后运行时不得再沿用源自带的 defaultSni',
    );
  });
}
