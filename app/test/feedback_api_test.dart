import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_app/data/sync/sync_api.dart';

void main() {
  for (final reply in [
    {'received': true, 'delivered': true},
    {'received': true, 'deduped': true},
  ]) {
    test('feedback delivery acknowledgement $reply', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/feedback');
        expect(jsonDecode(request.body)['message'], 'crash');
        return http.Response(jsonEncode(reply), 200);
      });
      addTearDown(client.close);
      await SyncApi(client: client, baseUrl: 'https://example.com')
          .submitFeedback(message: 'crash');
    });
  }

  for (final reply in [
    {'received': true, 'delivered': false},
    {'received': true},
    {'delivered': true},
    <String, bool>{},
  ]) {
    test('unacknowledged feedback remains retryable $reply', () async {
      final client =
          MockClient((_) async => http.Response(jsonEncode(reply), 200));
      addTearDown(client.close);
      await expectLater(
        SyncApi(client: client, baseUrl: 'https://example.com')
            .submitFeedback(message: 'crash'),
        throwsA(isA<SyncApiException>()),
      );
    });
  }
}
