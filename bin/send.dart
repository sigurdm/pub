import 'package:http/http.dart';

Future<void> main(List<String> args) async {
  final client = Client();
  final request = StreamedRequest(
      'GET', Uri.parse('http://example.com/api/packages/test_pkg'));
  request.headers['Accept'] = 'application/vnd.pub.v2+json';
  request.headers['user-agent'] = 'Dart pub 0.1.2+3';
  request.sink.close();

  final response = await client.send(request);
  print(response.statusCode);
  final request2 =
      Request('GET', Uri.parse('http://example.com/api/packages/test_pkg'));
  request2.headers['Accept'] = 'application/vnd.pub.v2+json';
  request2.headers['user-agent'] = 'Dart pub 0.1.2+3';
  final response2 = await client.send(request2);
  print(response2.statusCode);
  client.close();
}
