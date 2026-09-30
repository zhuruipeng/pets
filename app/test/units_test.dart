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
    test('中国一律公制，与 locale 无关', () {
      expect(Units.defaultWeightUnit(Region.cn, 'en_US'), WeightUnit.kg);
      expect(Units.defaultWeightUnit(Region.cn, 'zh_CN'), WeightUnit.kg);
      expect(Units.defaultDistanceUnit(Region.cn, 'en_US'), DistanceUnit.km);
    });

    test('海外按 locale：美制用磅/英里', () {
      expect(Units.defaultWeightUnit(Region.intl, 'en_US'), WeightUnit.lb);
      expect(Units.defaultDistanceUnit(Region.intl, 'en_US'), DistanceUnit.mile);
    });

    test('海外非美制走公制', () {
      expect(Units.defaultWeightUnit(Region.intl, 'de_DE'), WeightUnit.kg);
      expect(Units.defaultDistanceUnit(Region.intl, 'en_GB'), DistanceUnit.km);
    });
  });

  group('格式权重边界', () {
    test('小数位可调', () {
      expect(Units.formatWeight(4.25, WeightUnit.kg, decimals: 2), '4.25 kg');
      expect(Units.formatWeight(4.25, WeightUnit.kg, decimals: 0), '4 kg');
    });
  });
}
