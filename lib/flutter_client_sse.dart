library flutter_client_sse;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/utils.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

part 'sse_event_model.dart';

/// A client for subscribing to Server-Sent Events (SSE).
class SSEClient {
  static http.Client _client = new http.Client();
  static final _log = Logger('SSEClient');

  /// Retry the SSE connection after a delay.
  ///
  /// [method] is the request method (GET or POST).
  /// [url] is the URL of the SSE endpoint.
  /// [header] is a map of request headers.
  /// [body] is an optional request body for POST requests.
  /// [streamController] is required to persist the stream from the old connection
  /// [maxRetryTime] is the maximum time to retry
  /// [minRetryTime] is the minimum time to retry
  /// [maxRetry] is the maximum number of retries before giving up. if set to 0,
  /// it will retry indefinitely.
  /// [currentRetry] is the current retry count.
  /// [limitReachedCallback] is a callback function that will be called when the
  /// maximum number of retries is reached.
  ///
  static void _retryConnection(
      {required SSERequestType method,
      required String url,
      required Map<String, String> header,
      required StreamController<SSEModel> streamController,
      Map<String, dynamic>? body,
      required int maxRetryTime,
      required int minRetryTime,
      required int maxRetry,
      required int currentRetry,
      Future Function()? limitReachedCallback}) {
    _log.finest('$currentRetry retry of  $maxRetry retries');

    if (maxRetry != 0 && currentRetry >= maxRetry) {
      _log.info('---MAX RETRY REACHED---');
      limitReachedCallback?.call();
      streamController.close();
      return;
    }
    _log.info('---RETRY CONNECTION---');
    int delay = _delay(currentRetry, minRetryTime, maxRetryTime);
    _log.finest('waiting for $delay ms');

    Future.delayed(Duration(milliseconds: delay), () {
      subscribeToSSE(
          method: method,
          url: url,
          header: header,
          body: body,
          oldStreamController: streamController,
          maxRetryTime: maxRetryTime,
          minRetryTime: minRetryTime,
          maxRetry: maxRetry,
          retryCount: currentRetry + 1,
          limitReachedCallback: limitReachedCallback);
    });
  }

  static int _delay(int currentRetry, int minRetryTime, int retryTime) {
    return Utils.expBackoff(
        minRetryTime, retryTime, currentRetry, _defaultJitterFn);
  }

  static int _defaultJitterFn(int num) {
    var randomFactor = 0.26;

    return Utils.jitter(num, randomFactor);
  }

  /// Subscribe to Server-Sent Events.
  ///
  /// [method] is the request method (GET or POST).
  /// [url] is the URL of the SSE endpoint.
  /// [header] is a map of request headers.
  /// [body] is an optional request body for POST requests.
  /// [oldStreamController] stream controller, used to retry to persist the
  /// stream from the old connection.
  /// [client] is an optional http client used for testing purpose
  /// or custom client.
  /// [maxRetryTime] is the maximum time to retry
  /// [maxRetry] is the maximum number of retries before giving up. if set to 0,
  /// it will retry indefinitely.
  /// [minRetryTime] is the minimum time to retry
  /// [retryCount] is the current retry count.
  /// [limitReachedCallback] is a callback function that will be called when the
  /// maximum number of retries is reached.
  ///
  /// Returns a [Stream] of [SSEModel] representing the SSE events.
  static Stream<SSEModel> subscribeToSSE({
    required SSERequestType method,
    required String url,
    required Map<String, String> header,
    StreamController<SSEModel>? oldStreamController,
    http.Client? client,
    Map<String, dynamic>? body,
    int maxRetryTime = 5000,
    int minRetryTime = 5000,
    int maxRetry = 5,
    int retryCount = 0,
    Future Function()? limitReachedCallback,
  }) {
    StreamController<SSEModel> streamController = StreamController();
    if (oldStreamController != null) {
      streamController = oldStreamController;
    }
    var lineRegex = RegExp(r'^([^:]*)(?::)?(?: )?(.*)?$');
    var currentSSEModel = SSEModel(data: '', id: '', event: '');
    _log.info("--SUBSCRIBING TO SSE---");
    while (true) {
      try {
        _client = client ?? http.Client();
        var request = new http.Request(
          method == SSERequestType.GET ? "GET" : "POST",
          Uri.parse(url),
        );

        /// Adding headers to the request
        header.forEach((key, value) {
          request.headers[key] = value;
        });

        /// Adding body to the request if exists
        if (body != null) {
          request.body = jsonEncode(body);
        }

        Future<http.StreamedResponse> response = _client.send(request);

        /// Listening to the response as a stream
        response.asStream().listen((data) {
          if (data.statusCode != 200) {
            _log.severe('---ERROR CODE ${data.statusCode}---');
            _retryConnection(
              method: method,
              url: url,
              header: header,
              body: body,
              streamController: streamController,
              maxRetryTime: maxRetryTime,
              minRetryTime: minRetryTime,
              currentRetry: retryCount,
              maxRetry: maxRetry,
              limitReachedCallback: limitReachedCallback,
            );
            return;
          }

          /// Applying transforms and listening to it
          data.stream
            ..transform(Utf8Decoder()).transform(LineSplitter()).listen(
              (dataLine) {
                if (dataLine.isEmpty) {
                  /// This means that the complete event set has been read.
                  /// We then add the event to the stream
                  streamController.add(currentSSEModel);
                  currentSSEModel = SSEModel(data: '', id: '', event: '');
                  return;
                }

                /// Get the match of each line through the regex
                Match match = lineRegex.firstMatch(dataLine)!;
                var field = match.group(1);
                if (field!.isEmpty) {
                  return;
                }
                var value = '';
                if (field == 'data') {
                  // If the field is data, we get the data through the substring
                  value = dataLine.substring(
                    5,
                  );
                } else {
                  value = match.group(2) ?? '';
                }
                switch (field) {
                  case 'event':
                    currentSSEModel.event = value;
                    break;
                  case 'data':
                    currentSSEModel.data =
                        (currentSSEModel.data ?? '') + value + '\n';
                    break;
                  case 'id':
                    currentSSEModel.id = value;
                    break;
                  case 'retry':
                    break;
                  default:
                    _log.severe('---ERROR---');
                    _log.severe(dataLine);
                    _retryConnection(
                      method: method,
                      url: url,
                      header: header,
                      streamController: streamController,
                      maxRetryTime: maxRetryTime,
                      minRetryTime: minRetryTime,
                      currentRetry: retryCount,
                      maxRetry: maxRetry,
                      limitReachedCallback: limitReachedCallback,
                    );
                }
              },
              onError: (e, s) {
                _log.severe('---ERROR---');
                _log.severe(e);
                _retryConnection(
                  method: method,
                  url: url,
                  header: header,
                  body: body,
                  streamController: streamController,
                  maxRetryTime: maxRetryTime,
                  minRetryTime: minRetryTime,
                  currentRetry: retryCount,
                  maxRetry: maxRetry,
                  limitReachedCallback: limitReachedCallback,
                );
              },
            );
        }, onError: (e, s) {
          _log.severe('---ERROR---');
          _log.severe(e);
          _retryConnection(
            method: method,
            url: url,
            header: header,
            body: body,
            streamController: streamController,
            maxRetryTime: maxRetryTime,
            minRetryTime: minRetryTime,
            currentRetry: retryCount,
            maxRetry: maxRetry,
            limitReachedCallback: limitReachedCallback,
          );
        });
      } catch (e) {
        _log.severe('---ERROR---');
        _log.severe(e);
        _retryConnection(
          method: method,
          url: url,
          header: header,
          body: body,
          streamController: streamController,
          maxRetryTime: maxRetryTime,
          minRetryTime: minRetryTime,
          currentRetry: retryCount,
          maxRetry: maxRetry,
          limitReachedCallback: limitReachedCallback,
        );
      }
      return streamController.stream;
    }
  }

  /// Unsubscribe from the SSE.
  static void unsubscribeFromSSE() {
    _client.close();
  }
}
