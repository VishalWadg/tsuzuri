import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef HttpResponseHandler = FutureOr<void> Function(
  HttpRequest request,
  HttpResponse response,
);

class HttpRequestLog {
  final String method;
  final String path;
  final HttpHeaders headers;

  const HttpRequestLog({
    required this.method,
    required this.path,
    required this.headers,
  });
}

/// Embedded loopback HTTP server for hermetic offline testing of online source fetching.
class MockContentHttpServer {
  HttpServer? _server;
  final Map<String, HttpResponseHandler> _routes = {};
  final List<HttpRequestLog> _requestLog = [];

  int get port => _server?.port ?? 0;
  String get baseUrl => 'http://127.0.0.1:$port';
  List<HttpRequestLog> get requestLog => List.unmodifiable(_requestLog);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _routes.clear();
    _requestLog.clear();
  }

  void onGet(String path, HttpResponseHandler handler) {
    _routes[path] = handler;
  }

  void serveManifest(String path, Map<String, dynamic> manifestJson) {
    onGet(path, (req, res) async {
      res.headers.contentType = ContentType.json;
      res.statusCode = HttpStatus.ok;
      res.write(jsonEncode(manifestJson));
    });
  }

  void serveBytes(String path, List<int> bytes, {String contentType = 'application/octet-stream'}) {
    onGet(path, (req, res) async {
      res.headers.set(HttpHeaders.contentTypeHeader, contentType);
      res.statusCode = HttpStatus.ok;
      res.add(bytes);
    });
  }

  void serveError(String path, int statusCode, {String body = 'Error'}) {
    onGet(path, (req, res) async {
      res.statusCode = statusCode;
      res.write(body);
    });
  }

  void serveDelayed(String path, Duration delay, {int statusCode = 200, String body = 'OK'}) {
    onGet(path, (req, res) async {
      await Future<void>.delayed(delay);
      res.statusCode = statusCode;
      res.write(body);
    });
  }

  void serveCorrupted(String path) {
    onGet(path, (req, res) async {
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.contentLengthHeader, '50000');
      res.add(utf8.encode('{"partial":'));
      await res.flush();
      try {
        await res.close();
      } catch (_) {}
    });
  }

  int requestCount(String path) =>
      _requestLog.where((r) => r.path == path).length;

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    _requestLog.add(HttpRequestLog(
      method: request.method,
      path: path,
      headers: request.headers,
    ));

    final handler = _routes[path];
    if (handler != null) {
      await handler(request, request.response);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found: $path');
    }
    try {
      await request.response.close();
    } catch (_) {}
  }
}
