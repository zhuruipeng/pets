import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_app/data/sync/sync_api.dart';

void main() {
  const change =
      SyncChange(table: 'records', rowId: 'r1', op: 'upsert', updatedAt: 100);
  for (final reason in ['stale', 'forbidden']) {
    test('canonical conflict response is parsed only for stale ($reason)',
        () async {
      final api = SyncApi(
          baseUrl: 'https://example.com',
          client: MockClient((request) async {
            expect(jsonDecode(request.body)['changes'][0]['row_id'], 'r1');
            return http.Response(
                jsonEncode({
                  'applied': [],
                  'rejected': [
                    {
                      'table': 'records',
                      'row_id': 'r1',
                      'result': reason,
                      'canonical': {
                        'table': 'records',
                        'row_id': 'r1',
                        'op': 'upsert',
                        'seq': 9,
                        'changed_at': 100,
                        'payload': {'id': 'r1', 'note': 'winner'},
                      },
                    }
                  ]
                }),
                200);
          }));
      final result =
          await api.push(token: 'token', deviceId: 'device', changes: [change]);
      expect(result.rejected.single.change, change);
      expect(result.rejected.single.reason, reason);
      if (reason == 'stale') {
        expect(result.canonical.single.payload['note'], 'winner');
        expect(result.canonical.single.updatedAt, 100);
        expect(result.canonical.single.seq, 9);
      } else {
        expect(result.canonical, isEmpty);
      }
    });
  }
}
