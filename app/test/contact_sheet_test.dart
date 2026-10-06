import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/ui/contact_sheet.dart';

void main() {
  for (final region in ['local', 'cn']) {
    testWidgets('$region 用户的手机号/邮箱编辑符合账号验证约束', (tester) async {
      final user = LocalUser(
        id: region == 'local' ? 'local-user' : 'account',
        nickname: 'User',
        region: region,
        phone: '+8613800138000',
        email: 'user@example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showContactSheet(context, user: user),
                      child: const Text('Open'),
                    ))),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields[0].readOnly, region != 'local');
      expect(fields[2].readOnly, region != 'local');
      expect(fields[1].readOnly, isFalse);
      expect(fields[3].readOnly, isFalse);
      if (region != 'local') {
        expect(find.text(L.t('contact.loginLocked')), findsOneWidget);
      }
    });
  }
}
