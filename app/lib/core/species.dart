/// 宠物种类。领域与数据层共用，放在 core 避免 data↔domain 反向依赖。
library;

enum Species { dog, cat, other }

extension SpeciesX on Species {
  /// 存库用的稳定字符串。
  String get wireName => switch (this) {
        Species.dog => 'dog',
        Species.cat => 'cat',
        Species.other => 'other',
      };

  /// 是否适用犬猫专用的免疫规程。
  bool get hasImmunizationSchedule => this != Species.other;
}

Species speciesFromWire(String? value) => switch (value) {
      'dog' => Species.dog,
      'cat' => Species.cat,
      _ => Species.other,
    };

/// 宽松解析：兼容中文、大小写、以及「犬/狗/猫」等口语写法。
/// 用在用户输入入口（表单、导入），严格解析仍用 [speciesFromWire]。
Species speciesFromWireLoose(String? value) {
  final v = (value ?? '').trim().toLowerCase();
  return switch (v) {
    'dog' || 'dogs' || '犬' || '狗' || '狗狗' || 'puppy' => Species.dog,
    'cat' || 'cats' || '猫' || '猫咪' || 'kitten' => Species.cat,
    _ => Species.other,
  };
}
