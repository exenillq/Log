import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DigikalaLoggerApp());
}

class DigikalaLoggerApp extends StatelessWidget {
  const DigikalaLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تحلیل ترافیک دیجی‌کالا',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEF394E),
          primary: const Color(0xFFEF394E),
        ),
        fontFamily: 'Tahoma',
      ),
      home: const DigikalaScreen(),
    );
  }
}

class DigikalaScreen extends StatefulWidget {
  const DigikalaScreen({super.key});

  @override
  State<DigikalaScreen> createState() => _DigikalaScreenState();
}

class _DigikalaScreenState extends State<DigikalaScreen> {
  late final WebViewController _controller;
  File? _logFile;
  bool _isLoading = true;
  int _capturedCount = 0;

  // اسکریپت رهگیری دقیق برای تمام متدهای Fetch و XHR
  static const String _interceptorScript = """
    (function() {
      if (window.__loggerActive) return;
      window.__loggerActive = true;

      function isApiCall(url) {
        if (!url) return false;
        var u = url.toLowerCase();

        // حذف فایل‌های استاتیک و بدون ارزش تحلیلی
        if (u.match(/\\.(png|jpg|jpeg|gif|webp|svg|ico|css|woff|woff2|ttf|otf|js)(\\?.*)?\$/)) return false;
        if (u.includes('google-analytics') || u.includes('analytics') || u.includes('hotjar') || u.includes('sentry') || u.includes('metrix') || u.includes('clarity')) return false;

        // ذخیره درخواست‌های مربوط به API دیجی‌کالا و وب‌سرویس‌ها
        return u.includes('api.digikala.com') || u.includes('/v1/') || u.includes('/v2/') || u.includes('/web/') || u.includes('user') || u.includes('cart') || u.includes('order');
      }

      function pushLog(data) {
        try {
          if (window.LogBridge) {
            window.LogBridge.postMessage(JSON.stringify(data));
          }
        } catch(e) {}
      }

      // ۱. رهگیری Fetch API
      var nativeFetch = window.fetch;
      window.fetch = async function() {
        var args = Array.from(arguments);
        var input = args[0];
        var init = args[1] || {};
        var url = typeof input === 'string' ? input : (input ? input.url : '');
        var method = init.method || (input && input.method) || 'GET';

        if (!isApiCall(url)) {
          return nativeFetch.apply(this, args);
        }

        var headers = init.headers || (input && input.headers) || {};
        var requestBody = init.body || null;

        try {
          var response = await nativeFetch.apply(this, args);
          var cloned = response.clone();
          var responseBody = '';

          try {
            responseBody = await cloned.text();
          } catch(e) {
            responseBody = '[محتوای پاسخ قابل خواندن نبود]';
          }

          pushLog({
            protocol: 'FETCH',
            url: url,
            method: method,
            headers: headers,
            reqBody: requestBody,
            status: response.status,
            resBody: responseBody
          });

          return response;
        } catch(err) {
          pushLog({
            protocol: 'FETCH_ERROR',
            url: url,
            method: method,
            headers: headers,
            reqBody: requestBody,
            error: err.toString()
          });
          throw err;
        }
      };

      // ۲. رهگیری XMLHttpRequest
      var nativeOpen = XMLHttpRequest.prototype.open;
      var nativeSend = XMLHttpRequest.prototype.send;
      var nativeSetHeader = XMLHttpRequest.prototype.setRequestHeader;

      XMLHttpRequest.prototype.open = function(method, url) {
        this.__logUrl = url;
        this.__logMethod = method;
        this.__logHeaders = {};
        return nativeOpen.apply(this, arguments);
      };

      XMLHttpRequest.prototype.setRequestHeader = function(name, val) {
        if (this.__logHeaders) {
          this.__logHeaders[name] = val;
        }
        return nativeSetHeader.apply(this, arguments);
      };

      XMLHttpRequest.prototype.send = function(body) {
        var self = this;
        var url = self.__logUrl;

        if (isApiCall(url)) {
          self.__logReqBody = body;
          self.addEventListener('load', function() {
            pushLog({
              protocol: 'XHR',
              url: url,
              method: self.__logMethod,
              headers: self.__logHeaders,
              reqBody: self.__logReqBody,
              status: self.status,
              resBody: self.responseText
            });
          });
        }
        return nativeSend.apply(this, arguments);
      };
    })();
  """;

  @override
  void initState() {
    super.initState();
    _initFileStorage();
    _setupController();
  }

  Future<void> _initFileStorage() async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/digikala_network_logs.txt');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
  }

  void _setupController() {
    final WebViewController controller = WebViewController();

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'LogBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _recordLog(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) async {
            setState(() => _isLoading = true);
            await controller.runJavaScript(_interceptorScript);
          },
          onPageFinished: (String url) async {
            setState(() => _isLoading = false);
            await controller.runJavaScript(_interceptorScript);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.digikala.com/'));

    _controller = controller;
  }

  Future<void> _recordLog(String rawJson) async {
    if (_logFile == null) await _initFileStorage();

    try {
      final Map<String, dynamic> data = json.decode(rawJson);
      final timestamp = DateTime.now().toIso8601String();

      final buffer = StringBuffer();
      buffer.writeln("================================================================================");
      buffer.writeln("زمان: $timestamp");
      buffer.writeln("پروتکل: ${data['protocol']} | متد: ${data['method']} | کد وضعیت: ${data['status'] ?? 'نامشخص'}");
      buffer.writeln("آدرس: ${data['url']}");
      buffer.writeln("--- هدرهای درخواست ---");
      buffer.writeln(data['headers'] != null ? const JsonEncoder.withIndent('  ').convert(data['headers']) : "ندارد");
      buffer.writeln("--- بدنه درخواست (Request Body) ---");
      buffer.writeln(data['reqBody'] ?? "ندارد");
      buffer.writeln("--- بدنه پاسخ (Response Body) ---");
      buffer.writeln(data['resBody'] ?? data['error'] ?? "ندارد");
      buffer.writeln("================================================================================\n");

      await _logFile!.writeAsString(buffer.toString(), mode: FileMode.append, flush: true);

      if (mounted) {
        setState(() {
          _capturedCount++;
        });
      }
    } catch (_) {}
  }

  void _showFileLocation() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("اطلاعات فایل ذخیره‌شده", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SelectableText(
          "تعداد درخواست‌های ثبت‌شده: $_capturedCount\n\nمسیر فایل لاگ در گوشی:\n${_logFile?.path ?? 'در حال آماده‌سازی...'}",
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (_logFile != null && await _logFile!.exists()) {
                await _logFile!.writeAsString("");
              }
              setState(() => _capturedCount = 0);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("فایل لاگ خالی شد.")),
              );
            },
            child: const Text("پاکسازی لاگ‌ها", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("تایید"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (await _controller.canGoBack()) {
          await _controller.goBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          title: Row(
            children: [
              const Text(
                "دیجی‌کالا",
                style: TextStyle(color: Color(0xFFEF394E), fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "لاگ: $_capturedCount",
                  style: const TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Color(0xFF334155)),
              tooltip: 'تازه سازی صفحه',
              onPressed: () => _controller.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.folder_open, color: Color(0xFF334155)),
              tooltip: 'مشاهده مسیر ذخیره',
              onPressed: _showFileLocation,
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading)
              const LinearProgressIndicator(
                color: Color(0xFFEF394E),
                backgroundColor: Colors.transparent,
                minHeight: 3,
              ),
          ],
        ),
      ),
    );
  }
}
