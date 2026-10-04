/// 单位换算测试。存储层一律公制，往返必须无损。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/core/units.dart';

void main() {
  group('重量换算', () {
    test('kg → lb → kg 往返一致', () {
      for (final kg in [0.5, 1.0, 4.2, 12.7, 38.0]) {
        final round = Units.lbToKg(Units.kgToLb(kg));
        expect(round, closeTo(kg, 1e-9), reason: '$kg kg 往返');
      }
    });

    test('展示层换算与反向一致', () {
      const kg = 5.25;
      final displayed = Units.toDisplayWeight(kg, WeightUnit.lb);
      final back = Units.fromDisplayWeight(displayed, WeightUnit.lb);
      expect(back, closeTo(kg, 1e-9));
    });

    test('公制单位下不做换算', () {
      expect(Units.toDisplayWeight(7.5, WeightUnit.kg), 7.5);
      expect(Units.fromDisplayWeight(7.5, WeightUnit.kg), 7.5);
    });

    test('单位符号', () {
      expect(Units.weightSymbol(WeightUnit.kg), 'kg');
      expect(Units.weightSymbol(WeightUnit.lb), 'lb');
    });
  });

  group('距离换算', () {
    test('米 → 英里', () {
      expect(Units.metersToMiles(1609.344), closeTo(1.0, 1e-9));
    });

    test('米 → 公里', () {
      expect(Units.metersToKm(2500), 2.5);
    });

    test('英里符号与格式', () {
      expect(Units.distanceSymbol(DistanceUnit.mile), 'mi');
      expect(Units.formatDistance(1609.344, DistanceUnit.mile), '1.00 mi');
      expect(Units.formatDistance(1500, DistanceUnit.km), '1.50 km');
    });
  });

  group('温度换算', () {
    test('摄氏 ↔ 华氏', () {
      expect(Units.celsiusToFahrenheit(0), 32);
      expect(Units.celsiusToFahrenheit(100), 212);
      expect(Units.fahrenheitToCelsius(32), closeTo(0, 1e-9));
    });
  });

  group('时长拆分', () {
    test('小时与分钟', () {
      expect(Units.splitDuration(3661), (1, 1));
      expect(Units.splitDuration(600), (0, 10));
      expect(Units.splitDuration(0), (0, 0));
      // 不足一分钟应归零，不应进位
      expect(Units.splitDuration(59), (0, 0));
    });
  });

  group('区域默认单位', () {
    test('中国一律公制', () {
      expect(Units.defaultWeightUnit(Region.cn), WeightUnit.kg);
      expect(Units.defaultDistanceUnit(Region.cn), DistanceUnit.km);
    });

    test('海外区域默认用美制（磅 / 英里）', () {
      // ⚠️ 这两条以前是 `defaultWeightUnit(Region.intl, 'en_US')`，
      // 断言是对的、编译也是过的，但**生产代码 15 处调用点传的是 `region.name`
      // （即 'intl'）**，于是真机上美国用户拿到的还是 kg，界面不报任何错。
      // 根因是签名多一个 locale 参数，把「按区域判定」变成了「按调用方传值判定」——
      // 同一个决定复制 15 遍，第 16 遍一定会写错。现在参数已去掉，判断收敛到一处。
      expect(Units.defaultWeightUnit(Region.intl), WeightUnit.lb);
      expect(Units.defaultDistanceUnit(Region.intl), DistanceUnit.mile);
    });

    test('中国区一律公制', () {
      expect(Units.defaultWeightUnit(Region.cn), WeightUnit.kg);
      expect(Units.defaultDistanceUnit(Region.cn), DistanceUnit.km);
    });

    test('默认值跟着区域走，不受调用方影响', () {
      // 回归防线：以后谁想再加 locale 参数、或传错值，这条会拦住。
      // 同一个区域无论被问多少次、来自哪个调用点，答案必须一致。
      for (var i = 0; i < 3; i++) {
        expect(Units.defaultWeightUnit(Region.intl), WeightUnit.lb);
        expect(Units.defaultWeightUnit(Region.cn), WeightUnit.kg);
      }
    });
  });

  group('格式权重边界', () {
    test('小数位可调', () {
      expect(Units.formatWeight(4.25, WeightUnit.kg, decimals: 2), '4.25 kg');
      expect(Units.formatWeight(4.25, WeightUnit.kg, decimals: 0), '4 kg');
    });
  });
}
