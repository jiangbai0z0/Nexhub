/// 全局网络设置页 SNI 默认值的「清空」回归测试。
///
/// 缺陷背景：[SniConfig.copyWith] 用 `defaultSni ?? this.defaultSni`，而「清空
/// 输入框」的语义就是 null，传 null 会被当成「保持原值」⇒ 用户清空后旧值仍在，
/// 删除操作静默失效（运行时 [SniPolicy.normalize] 把 null 当作「不覆盖」，正是
/// 用户期望的结果）。本页 `_collect()` 因此改为直接构造 [SniConfig]。
///
/// 与源级覆盖页（`source_network_override_screen.dart`）是同一种缺陷的两个
/// 入口，两处都必须有自己的防线——只修一处，用户从另一处进来照样删不掉。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/network_config_service.dart';
import 'package:nexhub/features/settings/presentation/settings_network_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap() => const MaterialApp(
      locale: Locale('zh'),
      supportedLocales: <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: SettingsNetworkScreen(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // update() 内部会重建 HttpFetcher（读取高级设置），需要 mock prefs。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await NetworkConfigService.instance.resetToDefaults();
  });

  testWidgets('清空 SNI 默认值：删除动作必须落盘，不得被静默丢弃',
      (WidgetTester tester) async {
    await NetworkConfigService.instance.update(
      NetworkConfig.defaults.copyWith(
        sni: const SniConfig(enabled: true, defaultSni: 'old.example.com'),
      ),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // 用户清空 SNI 默认值输入框，这是「删掉这个覆盖」的显式动作。
    await tester.scrollUntilVisible(
      find.widgetWithText(TextField, 'old.example.com'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'old.example.com'),
      '',
    );
    await tester.pumpAndSettle();

    final saveFinder = find.text('保存');
    await tester.scrollUntilVisible(
      saveFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible 只保证「已请求滚动到位」，不等于「已完成布局」；
    // 直接 tap 可能落在渲染前的位置而静默打空（warnIfMissed 默认只警告），
    // 于是 _save 根本没跑、断言看到的还是旧配置。先把元素真正滚进可见区再等
    // 布局稳定，点击才可靠。
    await tester.ensureVisible(saveFinder);
    await tester.pumpAndSettle();
    await tester.tap(saveFinder);
    await tester.pumpAndSettle();

    // 清空必须真的落到配置里；若用 copyWith 传 null，它会被 `??` 吞掉，
    // 保存后旧值仍在 ⇒ 用户删了却还在（本次回归的正是这一条）。
    expect(
      NetworkConfigService.instance.config.sni.defaultSni,
      isNull,
      reason: '清空 SNI 默认值后旧值不得残留（copyWith 会把 null 当成「保持原值」）',
    );
    // 同一卡片里的其他字段不受影响。
    expect(NetworkConfigService.instance.config.sni.enabled, isTrue);
  });
}
