/// Schema 8 stores cents; the shared wire format stays readable by schema 7.
/// Neither conversion changes the edit timestamp or other expense fields.
library;

const _maxSafeCents = 9007199254740991;

int _legacyCents(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('Invalid expense amount');
  }
  final scaled = value * 100;
  if (!scaled.isFinite || scaled.abs() > _maxSafeCents) {
    throw const FormatException('Expense amount exceeds exact numeric range');
  }
  return scaled.round();
}

Map<String, dynamic> expensePayloadForLocal(Map<String, dynamic> source) {
  final result = Map<String, dynamic>.from(source);
  // Thin tombstones and partial updates need no invented amount.
  if (!result.containsKey('amount') && !result.containsKey('amount_cents')) {
    return result;
  }
  final int cents;
  if (result.containsKey('amount_cents')) {
    final value = result['amount_cents'];
    if (value is! int || value.abs() > _maxSafeCents) {
      throw const FormatException('Invalid expense cents');
    }
    cents = value;
    if (result.containsKey('amount') &&
        _legacyCents(result['amount']) != cents) {
      throw const FormatException('Conflicting expense amounts');
    }
  } else {
    cents = _legacyCents(result['amount']);
  }
  if (_legacyCents(cents / 100) != cents) {
    throw const FormatException('Expense amount cannot round-trip exactly');
  }
  result.remove('amount');
  result['amount_cents'] = cents;
  return result;
}

Map<String, dynamic> expensePayloadForSync(Map<String, dynamic> source) {
  final result = expensePayloadForLocal(source);
  if (result.containsKey('amount_cents')) {
    result['amount'] = (result.remove('amount_cents') as int) / 100;
  }
  return result;
}
