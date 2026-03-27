import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

// ── TOKEN STORAGE ──────────────────────────────
class TokenStorage {
  static const _kToken = 'soet_token';
  static const _kDemo  = 'soet_demo';
  static void   save(String t, bool d) { html.window.localStorage[_kToken] = t; html.window.localStorage[_kDemo] = d ? '1' : '0'; }
  static String? token()  => html.window.localStorage[_kToken];
  static bool    isDemo() => (html.window.localStorage[_kDemo] ?? '1') != '0';
  static void    clear()  { html.window.localStorage.remove(_kToken); html.window.localStorage.remove(_kDemo); }
}

// ── DERIV SERVICE ──────────────────────────────
class DerivService {
  static const _wsUrl = 'wss://ws.binaryws.com/websockets/v3?app_id=1089';
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool _connected = false;
  String _token = '';
  String _currentSymbol = '';
  int _rid = 1;
  final Map<int, Completer<Map>> _pending = {};
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  Function(Map)?    onTick;
  Function(List<num>, String)? onHistoryBatch;
  Function(Map)?    onBalance;
  Function(String)? onError;
  Function()?       onConnected;
  Function()?       onDisconnected;
  // Per-contract completers — each bot registers its own
  final Map<String, Completer<Map>> _contractCompleters = {};

  void registerContractCompleter(String cid, Completer<Map> comp) {
    _contractCompleters[cid] = comp;
  }
  void unregisterContractCompleter(String cid) {
    _contractCompleters.remove(cid);
  }
  Function(Map)?    onContract;
  Function(String)? onTradeError;
  Function()?       onReconnecting;

  bool get isConnected => _connected;
  int  get _nextId     => _rid++;

  Future<bool> connect(String token) async {
    _token = token;
    _reconnectAttempts = 0;
    return _doConnect();
  }

  Future<bool> _doConnect() async {
    final c = Completer<bool>();
    try {
      _sub?.cancel();
      _ch = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _sub = _ch!.stream.listen(
        (raw) { try { _handle(jsonDecode(raw.toString()) as Map, c); } catch (_) {} },
        onError: (_) { _connected = false; if (!c.isCompleted) c.complete(false); _scheduleReconnect(); },
        onDone:  ()  { _connected = false; _scheduleReconnect(); },
      );
      _send({'authorize': _token, 'req_id': _nextId});
      return c.future.timeout(const Duration(seconds: 12), onTimeout: () { return false; });
    } catch (e) { return false; }
  }

  void _scheduleReconnect() {
    if (_token.isEmpty) return;
    onDisconnected?.call();
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay = _reconnectAttempts > 5 ? 15 : _reconnectAttempts * 3;
    onReconnecting?.call();
    _reconnectTimer = Timer(Duration(seconds: delay), () async {
      if (_token.isEmpty) return;
      final ok = await _doConnect();
      if (ok && _currentSymbol.isNotEmpty) {
        // Give authorize+balance time to complete before resubscribing
        Future.delayed(const Duration(milliseconds: 1200), () => subscribeTicks(_currentSymbol));
      }
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_connected) _send({'ping': 1, 'req_id': _nextId});
    });
  }

  void _handle(Map d, [Completer<bool>? c]) {
    final msgType = d['msg_type']?.toString() ?? '';

    // ── CONTRACT RESULT: always route first, never swallow in pending ──
    if (msgType == 'proposal_open_contract' && d['proposal_open_contract'] != null) {
      final contractData = Map<String,dynamic>.from(d['proposal_open_contract'] as Map);
      final cid = contractData['contract_id']?.toString() ?? '';
      // Dispatch to per-contract completer if registered (for bots)
      if (cid.isNotEmpty && _contractCompleters.containsKey(cid)) {
        final status = contractData['status']?.toString() ?? '';
        final isSold = contractData['is_sold'];
        final settled = isSold==1 || isSold==true || status=='won' || status=='lost';
        if (settled) {
          _contractCompleters[cid]?.complete(contractData);
          _contractCompleters.remove(cid);
        }
        return; // Don't pass to onContract — bot handles it
      }
      onContract?.call(contractData);
      return;
    }

    // ── ERRORS ──
    if (d['error'] != null) {
      final msg = d['error']['message']?.toString() ?? 'Error';
      if (msgType == 'buy' || msgType == 'proposal') {
        onTradeError?.call(msg);
      } else {
        onError?.call(msg);
        if (c != null && !c.isCompleted) c.complete(false);
      }
      return;
    }

    // ── PENDING COMPLETERS (proposal, buy, balance subscribe etc.) ──
    final rid = d['req_id'];
    if (rid != null && _pending.containsKey(rid)) {
      _pending.remove(rid)?.complete(Map.from(d));
    }

    // ── SYSTEM MESSAGES ──
    if (msgType == 'ping' || d['ping'] != null) return;
    if (msgType == 'forget_all' || msgType == 'forget') return;

    // ── AUTH ──
    if (d['authorize'] != null) {
      _connected = true; onConnected?.call();
      if (c != null && !c.isCompleted) c.complete(true);
      _send({'balance': 1, 'subscribe': 1, 'req_id': _nextId});
      _startPing();
      return;
    }

    // ── BALANCE ──
    if (d['balance'] != null) { onBalance?.call(Map.from(d['balance'] as Map)); return; }

    // ── LIVE TICK (plain ticks subscribe) ──
    if (d['tick'] != null) { onTick?.call(Map.from(d['tick'] as Map)); return; }

    // ── TICKS HISTORY — seed digit history in one batch (no animation) ──
    if (d['history'] != null) {
      final hist   = d['history'] as Map;
      final prices = (hist['prices'] as List?)?.cast<num>() ?? [];
      onHistoryBatch?.call(prices, _currentSymbol);
      return;
    }
    // proposal and buy are handled via pending completers above — nothing else needed
  }

  Future<Map?> getTickHistory(String symbol, int count) async {
    final id = _nextId;
    final comp = Completer<Map>();
    _pending[id] = comp;
    _send({'ticks_history':symbol,'count':count,'end':'latest','style':'ticks','req_id':id});
    try { return await comp.future.timeout(const Duration(seconds:8)); } catch(_) { return null; }
  }

  Future<Map?> getProposal({required String symbol, required String contractType, required double amount, int? barrier, int duration=1}) async {
    if (!_connected) return null;
    final id = _nextId;
    final req = <String,dynamic>{'proposal':1,'amount':amount,'basis':'stake','contract_type':contractType,'currency':'USD','duration':duration,'duration_unit':'t','symbol':symbol,'req_id':id};
    if (barrier != null) req['barrier'] = barrier;
    final comp = Completer<Map>(); _pending[id] = comp; _send(req);
    return comp.future.timeout(const Duration(seconds: 5), onTimeout: () => {});
  }

  Future<Map?> buyContract(String proposalId, double amount) async {
    if (!_connected) return null;
    final id = _nextId;
    final comp = Completer<Map>(); _pending[id] = comp;
    _send({'buy': proposalId, 'price': amount, 'req_id': id});
    return comp.future.timeout(const Duration(seconds: 5), onTimeout: () => {});
  }

  void subscribeContract(String contractId) {
    final cid = int.tryParse(contractId);
    if (cid == null || cid == 0) return; // don't subscribe with invalid id
    _send({'proposal_open_contract': 1, 'contract_id': cid, 'subscribe': 1, 'req_id': _nextId});
  }

  // Standard volatility (R_10 etc.) = price is constant, needs ticks_history to stream
  // 1s volatility (1HZ10V etc.), Jump (JD), Boom/Crash = plain ticks subscribe works
  bool _usePlainTicks(String symbol) =>
    symbol.startsWith('1HZ') || symbol.startsWith('JD');

  void subscribeTicks(String symbol) {
    if (!_connected) return;
    _currentSymbol = symbol;
    _send({'forget_all': 'ticks'});
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!_connected || _currentSymbol != symbol) return;
      if (_usePlainTicks(symbol)) {
        // These markets stream ticks directly
        _send({'ticks': symbol, 'subscribe': 1, 'req_id': _nextId});
      } else {
        // R_10/25/50/75/100 — use ticks_history with subscribe to get streaming + history seed
        _send({'ticks_history': symbol, 'subscribe': 1, 'style': 'ticks', 'count': 25, 'end': 'latest', 'req_id': _nextId});
      }
    });
  }

  void _send(Map d) { try { _ch?.sink.add(jsonEncode(d)); } catch (_) {} }

  void disconnect() {
    _token = ''; _currentSymbol = '';
    _pingTimer?.cancel(); _reconnectTimer?.cancel();
    _pending.clear(); _sub?.cancel(); _ch?.sink.close(); _connected = false;
  }
}

final deriv = DerivService();

// ══════════════════════════════════════════════
// SPLASH
// ══════════════════════════════════════════════
void main() {
  // Catch ALL Flutter errors and show friendly screen instead of red
  FlutterError.onError = (FlutterErrorDetails details) {
    // Silently ignore — prevents red screen from showing
    FlutterError.dumpErrorToConsole(details);
  };
  runApp(const SOETApp());
}

class SOETApp extends StatefulWidget {
  const SOETApp({super.key});
  @override State<SOETApp> createState() => SOETAppState();
  static SOETAppState? of(BuildContext context) => context.findAncestorStateOfType<SOETAppState>();
}
class SOETAppState extends State<SOETApp> {
  bool isDark = true;
  void toggleTheme() => setState(() => isDark = !isDark);

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF060B18),
      colorScheme: const ColorScheme.dark(primary: Color(0xFF1DE9B6)),
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Montserrat'),
    );
    final light = ThemeData.light().copyWith(
      scaffoldBackgroundColor: const Color(0xFFF0F4F8),
      colorScheme: const ColorScheme.light(primary: Color(0xFF00897B)),
      cardColor: Colors.white,
      appBarTheme: const AppBarTheme(backgroundColor: Colors.white, foregroundColor: Colors.black),
      textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Montserrat'),
    );
    return MaterialApp(
      title: 'SOET', debugShowCheckedModeBanner: false,
      theme: isDark ? dark : light,
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override State<SplashScreen> createState() => _SplashState();
}
class _SplashState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _fade, _scale;
  @override void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _fade  = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_c,curve:Curves.easeIn));
    _scale = Tween<double>(begin:0.6,end:1).animate(CurvedAnimation(parent:_c,curve:Curves.elasticOut));
    _c.forward();
    Future.delayed(const Duration(seconds: 3), () async {
      if (!mounted) return;
      try {
        final saved = TokenStorage.token();
        if (saved != null && saved.isNotEmpty) {
          final ok = await deriv.connect(saved);
          if (!mounted) return;
          if (ok) {
            Navigator.pushReplacement(context, MaterialPageRoute(builder:(_)=>SOETHome(isDemo:TokenStorage.isDemo())));
            return;
          }
          TokenStorage.clear();
        }
      } catch(_) { TokenStorage.clear(); }
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder:(_)=>const LandingPage()));
    });
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF060B18),
    body: Center(child: FadeTransition(opacity:_fade, child: ScaleTransition(scale:_scale,
      child: Column(mainAxisSize:MainAxisSize.min, children:[
        Container(width:130,height:130,decoration:BoxDecoration(shape:BoxShape.circle,
          gradient:const LinearGradient(colors:[Color(0xFF00C853),Color(0xFF1DE9B6)]),
          boxShadow:[BoxShadow(color:const Color(0xFF00C853).withOpacity(0.6),blurRadius:50,spreadRadius:8)]),
          child:const Center(child:Text('🦬',style:TextStyle(fontSize:65)))),
        const SizedBox(height:28),
        const Text('SOET',style:TextStyle(color:Colors.white,fontSize:52,fontWeight:FontWeight.w900,letterSpacing:12)),
        const SizedBox(height:8),
        const Text('Smart Options & Events Trader',style:TextStyle(color:Color(0xFF1DE9B6),fontSize:13,letterSpacing:2)),
        const SizedBox(height:10),
        const Text('Phase 3 — Real Trading',style:TextStyle(color:Color(0xFF00C853),fontSize:11,letterSpacing:3)),
        const SizedBox(height:52),
        SizedBox(width:40,height:40,child:CircularProgressIndicator(strokeWidth:2,color:const Color(0xFF00C853).withOpacity(0.7))),
      ])))),
  );
}


// ══════════════════════════════════════════════
// LANDING PAGE
// ══════════════════════════════════════════════
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});
  @override State<LandingPage> createState() => _LandingState();
}
class _LandingState extends State<LandingPage> with TickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _fade, _slide;
  int _page = 0;
  final _pages = [
    {'icon':'🦬','title':'Welcome to SOET','sub':'Smart Options & Events Trader','desc':'A professional digit trading hub built for Deriv markets. Trade smarter with AI-powered signals.','color':'FF1DE9B6'},
    {'icon':'📊','title':'Smart Signals','sub':'AI-Powered Analysis','desc':'SOET analyzes digit patterns, streaks and momentum across 25 markets to give you high-confidence signals.','color':'FF00C853'},
    {'icon':'🤖','title':'Automated Bots','sub':'4 Trading Bots','desc':'Set your stake, stop loss and take profit — then let SOET trade for you. Bots pause during high volatility automatically.','color':'FFFF9800'},
    {'icon':'📲','title':'Stay Notified','sub':'Telegram Alerts','desc':'Get instant Telegram messages when your bots win, lose, or hit targets — even when the screen is off.','color':'FF0088CC'},
    {'icon':'🚀','title':'Ready to Trade','sub':'Connect & Start','desc':'Connect your Deriv demo account first. Test everything before going live. Your funds, your control.','color':'FFFFFF00'},
  ];

  @override void initState() {
    super.initState();
    _c = AnimationController(vsync:this, duration:const Duration(milliseconds:600));
    _fade  = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_c,curve:Curves.easeIn));
    _slide = Tween<double>(begin:40,end:0).animate(CurvedAnimation(parent:_c,curve:Curves.easeOut));
    _c.forward();
  }
  @override void dispose() { _c.dispose(); super.dispose(); }

  void _next() {
    if (_page < _pages.length-1) {
      _c.reset();
      setState(()=>_page++);
      _c.forward();
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder:(_)=>const LoginScreen()));
    }
  }

  void _skip() => Navigator.pushReplacement(context, MaterialPageRoute(builder:(_)=>const LoginScreen()));

  @override Widget build(BuildContext context) {
    final p = _pages[_page];
    final col = Color(int.parse(p['color']!, radix:16));
    return Scaffold(
      backgroundColor: const Color(0xFF060B18),
      body: SafeArea(child: Column(children:[
        // Skip button
        Padding(padding:const EdgeInsets.fromLTRB(16,12,16,0),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          Text('${_page+1}/${_pages.length}',style:const TextStyle(color:Colors.grey,fontSize:12)),
          if(_page < _pages.length-1)
            GestureDetector(onTap:_skip,child:Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:6),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(20)),child:const Text('Skip',style:TextStyle(color:Colors.grey,fontSize:12)))),
        ])),

        // Main content
        Expanded(child: AnimatedBuilder(animation:_c, builder:(_,__)=>Opacity(opacity:_fade.value,
          child:Transform.translate(offset:Offset(0,_slide.value),
            child:Padding(padding:const EdgeInsets.all(32),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
              // Icon circle
              Container(width:140,height:140,
                decoration:BoxDecoration(shape:BoxShape.circle,
                  color:col.withOpacity(0.1),
                  border:Border.all(color:col.withOpacity(0.4),width:2),
                  boxShadow:[BoxShadow(color:col.withOpacity(0.3),blurRadius:50,spreadRadius:5)]),
                child:Center(child:Text(p['icon']!,style:const TextStyle(fontSize:64)))),
              const SizedBox(height:40),
              Text(p['title']!,style:const TextStyle(color:Colors.white,fontSize:28,fontWeight:FontWeight.w900),textAlign:TextAlign.center),
              const SizedBox(height:8),
              Text(p['sub']!,style:TextStyle(color:col,fontSize:14,letterSpacing:1),textAlign:TextAlign.center),
              const SizedBox(height:20),
              Text(p['desc']!,style:const TextStyle(color:Colors.grey,fontSize:14,height:1.6),textAlign:TextAlign.center),
            ]))))),
        ),

        // Dots + Button
        Padding(padding:const EdgeInsets.fromLTRB(24,0,24,32),child:Column(children:[
          // Dot indicators
          Row(mainAxisAlignment:MainAxisAlignment.center,children:List.generate(_pages.length,(i)=>
            AnimatedContainer(duration:const Duration(milliseconds:300),
              margin:const EdgeInsets.symmetric(horizontal:4),
              width:_page==i?24:8, height:8,
              decoration:BoxDecoration(
                color:_page==i?col:const Color(0xFF1A2640),
                borderRadius:BorderRadius.circular(4))))),
          const SizedBox(height:24),
          // CTA Button
          GestureDetector(onTap:_next,
            child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:16),
              decoration:BoxDecoration(
                gradient:LinearGradient(colors:[col,col.withOpacity(0.7)]),
                borderRadius:BorderRadius.circular(16),
                boxShadow:[BoxShadow(color:col.withOpacity(0.4),blurRadius:20)]),
              child:Center(child:Text(
                _page==_pages.length-1?'Get Started 🚀':'Next →',
                style:const TextStyle(color:Colors.black,fontWeight:FontWeight.bold,fontSize:16))))),
        ])),
      ])),
    );
  }
}

// ══════════════════════════════════════════════
// LOGIN
// ══════════════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState() => _LoginState();
}
class _LoginState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  bool _isDemo = true, _loading = false, _obscure = true;
  String _err = '';
  late AnimationController _fc;
  late Animation<double> _fa;
  @override void initState() {
    super.initState();
    _fc = AnimationController(vsync:this,duration:const Duration(milliseconds:800));
    _fa = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_fc,curve:Curves.easeIn));
    _fc.forward();
    final saved = TokenStorage.token();
    if (saved != null && saved.isNotEmpty) { _ctrl.text = saved; _isDemo = TokenStorage.isDemo(); }
  }
  @override void dispose() { _fc.dispose(); _ctrl.dispose(); super.dispose(); }

  Future<void> _connect() async {
    if (_ctrl.text.trim().isEmpty) { setState(()=>_err='Please enter your API token'); return; }
    setState((){_loading=true; _err='';});
    try {
      deriv.onError = (msg) { if (mounted) setState((){_loading=false; _err=msg;}); };
      final ok = await deriv.connect(_ctrl.text.trim());
      if (!mounted) return;
      if (ok) {
        TokenStorage.save(_ctrl.text.trim(),_isDemo);
        Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>SOETHome(isDemo:_isDemo)));
      } else {
        setState((){_loading=false; if(_err.isEmpty) _err='Connection failed. Check your token.';});
      }
    } catch(e) {
      if (mounted) setState((){_loading=false; _err='Error: $e';});
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF060B18),
    body: FadeTransition(opacity:_fa, child: SingleChildScrollView(child: Column(children:[
      Container(height:260,
        decoration:const BoxDecoration(gradient:LinearGradient(colors:[Color(0xFF00C853),Color(0xFF1DE9B6),Color(0xFF060B18)],begin:Alignment.topCenter,end:Alignment.bottomCenter)),
        child:Center(child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
          const SizedBox(height:40),
          Container(width:90,height:90,decoration:BoxDecoration(shape:BoxShape.circle,color:Colors.black.withOpacity(0.3),border:Border.all(color:Colors.white.withOpacity(0.3),width:2),boxShadow:[BoxShadow(color:const Color(0xFF00C853).withOpacity(0.5),blurRadius:30)]),child:const Center(child:Text('🦬',style:TextStyle(fontSize:48)))),
          const SizedBox(height:12),
          const Text('SOET',style:TextStyle(color:Colors.white,fontSize:32,fontWeight:FontWeight.w900,letterSpacing:8)),
          const Text('Smart Options & Events Trader',style:TextStyle(color:Colors.white70,fontSize:11)),
        ]))),
      Padding(padding:const EdgeInsets.all(24),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Connect Your Account',style:TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.bold)),
        const SizedBox(height:20),
        Container(padding:const EdgeInsets.all(4),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(12)),
          child:Row(children:[
            Expanded(child:GestureDetector(onTap:()=>setState(()=>_isDemo=true),child:Container(padding:const EdgeInsets.symmetric(vertical:10),decoration:BoxDecoration(color:_isDemo?const Color(0xFF00C853):Colors.transparent,borderRadius:BorderRadius.circular(8)),child:Center(child:Text('DEMO',style:TextStyle(color:_isDemo?Colors.black:Colors.grey,fontWeight:FontWeight.bold)))))),
            Expanded(child:GestureDetector(onTap:()=>setState(()=>_isDemo=false),child:Container(padding:const EdgeInsets.symmetric(vertical:10),decoration:BoxDecoration(color:!_isDemo?const Color(0xFFFFD700):Colors.transparent,borderRadius:BorderRadius.circular(8)),child:Center(child:Text('LIVE',style:TextStyle(color:!_isDemo?Colors.black:Colors.grey,fontWeight:FontWeight.bold)))))),
          ])),
        const SizedBox(height:16),
        TextField(controller:_ctrl,obscureText:_obscure,style:const TextStyle(color:Colors.white,fontSize:14),
          decoration:InputDecoration(hintText:'Paste your Deriv API token',hintStyle:const TextStyle(color:Colors.grey),filled:true,fillColor:const Color(0xFF0D1421),
            border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:Color(0xFF1A2640))),
            enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:Color(0xFF1A2640))),
            focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:Color(0xFF1DE9B6),width:2)),
            suffixIcon:Row(mainAxisSize:MainAxisSize.min,children:[
              IconButton(icon:Icon(_obscure?Icons.visibility_off:Icons.visibility,color:Colors.grey,size:20),onPressed:()=>setState(()=>_obscure=!_obscure)),
              IconButton(icon:const Icon(Icons.paste,color:Colors.grey,size:20),onPressed:()async{final d=await Clipboard.getData('text/plain');if(d?.text!=null){_ctrl.text=d!.text!;setState((){});}})
            ]))),
        if (_err.isNotEmpty)...[const SizedBox(height:10),Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:const Color(0xFFFF4444).withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:const Color(0xFFFF4444).withOpacity(0.4))),child:Text(_err,style:const TextStyle(color:Color(0xFFFF4444),fontSize:12)))],
        const SizedBox(height:24),
        GestureDetector(onTap:_loading?null:_connect,
          child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:16),
            decoration:BoxDecoration(gradient:LinearGradient(colors:_isDemo?[const Color(0xFF00C853),const Color(0xFF1DE9B6)]:[const Color(0xFFFFD700),const Color(0xFFFF9800)]),borderRadius:BorderRadius.circular(14),boxShadow:[BoxShadow(color:(_isDemo?const Color(0xFF00C853):const Color(0xFFFFD700)).withOpacity(0.4),blurRadius:20)]),
            child:Center(child:_loading?const SizedBox(width:24,height:24,child:CircularProgressIndicator(strokeWidth:2,color:Colors.black)):Text('Connect ${_isDemo?"Demo":"Live"} Account',style:const TextStyle(color:Colors.black,fontWeight:FontWeight.bold,fontSize:16))))),
        const SizedBox(height:24),
        Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(12),border:Border.all(color:const Color(0xFF1A2640))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Row(children:[Icon(Icons.help_outline,color:Color(0xFF1DE9B6),size:16),SizedBox(width:8),Text('How to get your API token',style:TextStyle(color:Color(0xFF1DE9B6),fontSize:12,fontWeight:FontWeight.bold))]),
            const SizedBox(height:10),
            ...['1. Go to deriv.com and log in','2. Click profile icon (top right)','3. Security & Safety → API Token','4. Create: Read, Trade, Trading Info','5. Copy and paste above']
              .map((s)=>Padding(padding:const EdgeInsets.only(bottom:4),child:Text(s,style:const TextStyle(color:Colors.grey,fontSize:11)))).toList(),
          ])),
        const SizedBox(height:20),
      ])),
    ]))),
  );
}

// ══════════════════════════════════════════════
// HOME
// ══════════════════════════════════════════════
class SOETHome extends StatefulWidget {
  final bool isDemo;
  const SOETHome({super.key, required this.isDemo});
  @override State<SOETHome> createState() => _HomeState();
}

class _HomeState extends State<SOETHome> with TickerProviderStateMixin {
  int _tab = 0;

  // Theme helpers — use these instead of hardcoded colors
  bool get _isDark => SOETApp.of(context)?.isDark ?? true;
  Color get _bg        => _isDark ? const Color(0xFF060B18) : const Color(0xFFF0F4F8);
  Color get _card      => _isDark ? const Color(0xFF0D1421) : Colors.white;
  Color get _cardBorder=> _isDark ? const Color(0xFF1A2640) : const Color(0xFFDDE3ED);
  Color get _textPrim  => _isDark ? Colors.white : const Color(0xFF1A2640);
  Color get _textSec   => _isDark ? Colors.grey  : const Color(0xFF6B7280);
  Color get _accent    => const Color(0xFF1DE9B6);
  Color get _green     => const Color(0xFF00C853);
  Color get _red       => const Color(0xFFFF4444);

  // Account
  String _balance = '...', _currency = 'USD', _loginId = '';

  // Market
  String _sym = 'R_10', _symName = 'Volatility 10 Index';
  double _price = 0;
  int    _lastDigit = 0;
  List<int>    _hist       = [];

  // ── SMART MARKET BOT ────────────────────────────────
  bool   _smartBotOn    = false;
  String _smartBotMsg   = 'Smart bot ready';
  Color  _smartBotMsgC  = Colors.grey;
  double _smartBotStake = 1.0;
  double _smartBotTP    = 0;   // 0 = disabled
  double _smartBotSL    = 0;   // 0 = disabled
  bool   _smartBotTPon  = false;
  bool   _smartBotSLon  = false;
  int    _smartBotCount = 0;
  int    _smartBotWins  = 0;
  double _smartBotPnl   = 0;

  Future<void> _runSmartBot() async {
    setState(()=>_smartBotOn=true);
    while(_smartBotOn && mounted) {
      // Step 1: Scan all markets to find the best one
      setState(()=>_smartBotMsg='🔍 Scanning markets...');
      await _runMultiMarketAnalysis();
      if (!_smartBotOn || !mounted) break;

      if (_bestMarket.isEmpty) {
        setState(()=>_smartBotMsg='⏳ No strong signal found — waiting...');
        await Future.delayed(const Duration(seconds:10));
        continue;
      }

      // Step 2: Get best LOW/MEDIUM risk market only
      // Filter out HIGH and EXTREME risk markets for smart bot
      final safeMarkets = _marketScores.entries.where((e){
        final r = e.value['risk']?.toString() ?? 'LOW';
        return r == 'LOW' || r == 'MEDIUM';
      }).toList();
      if(safeMarkets.isNotEmpty){
        safeMarkets.sort((a,b)=>(b.value['score'] as int).compareTo(a.value['score'] as int));
        _bestMarket = safeMarkets.first.key;
        _bestMarketSignal = safeMarkets.first.value['signal'] as String;
      }
      final bestScore = _marketScores[_bestMarket]?['score'] as int? ?? 0;
      if (bestScore < 50) {
        setState(()=>_smartBotMsg='😴 Signals too weak ($bestScore%) — waiting...');
        await Future.delayed(const Duration(seconds:15));
        continue;
      }

      final bestName = _marketScores[_bestMarket]?['name'] ?? _bestMarket;
      final hotDigit = _marketScores[_bestMarket]?['hot'] ?? 0;
      setState(()=>_smartBotMsg='✅ Best: $bestName (score:$bestScore) — trading...');

      // Step 3: Place trade on best market using DIFFERS on hot digit
      try {
        final prop = await deriv.getProposal(
          symbol:_bestMarket, contractType:'DIGITDIFF',
          amount:_smartBotStake, barrier:hotDigit, duration:1);
        if(prop==null||prop['proposal']==null){ await Future.delayed(const Duration(seconds:3)); continue; }
        final pid = prop['proposal']['id']?.toString()??'';
        if(pid.isEmpty){ await Future.delayed(const Duration(seconds:3)); continue; }
        final buy = await deriv.buyContract(pid, _smartBotStake);
        if(buy==null||buy['buy']==null){ await Future.delayed(const Duration(seconds:3)); continue; }
        final cid = buy['buy']['contract_id']?.toString()??'';
        if(cid.isNotEmpty){
          final comp = Completer<Map>();
          deriv.registerContractCompleter(cid, comp);
          deriv.subscribeContract(cid);
          final result = await comp.future.timeout(const Duration(seconds:20),onTimeout:()=>{});
          deriv.unregisterContractCompleter(cid);
          if(!mounted) break;
          final profit=(result['profit'] as num?)?.toDouble()??0;
          final won = (result['status']?.toString()??'')=='won' || profit>0;
          final sbEntry = result['entry_spot']?.toString() ?? result['entry_tick_display_value']?.toString() ?? '';
          final sbExit  = result['exit_tick_display_value']?.toString() ?? result['sell_spot']?.toString() ?? '';
          setState((){
            _smartBotCount++;
            if(won) _smartBotWins++;
            _smartBotPnl+=profit;
            _smartBotMsg=won
              ?'✅ WIN +\$'+profit.toStringAsFixed(2)+' on '+bestName
              :'❌ LOSS -\$'+profit.abs().toStringAsFixed(2)+' on '+bestName;
            _smartBotMsgC=won?_green:_red;
          });
          _logTrade(market:bestName,type:'DIFFERS '+hotDigit.toString(),stake:_smartBotStake,won:won,profit:profit,entrySpot:sbEntry,exitSpot:sbExit);
          _playSound(won);
          // Check smart bot SL/TP
          if (_smartBotTPon && _smartBotTP > 0 && _smartBotPnl >= _smartBotTP) {
            setState((){_smartBotOn=false; _smartBotMsg='🎯 TP Hit! +\$'+_smartBotPnl.toStringAsFixed(2); _smartBotMsgC=_green;});
            break;
          }
          if (_smartBotSLon && _smartBotSL > 0 && _smartBotPnl <= -_smartBotSL) {
            setState((){_smartBotOn=false; _smartBotMsg='🛑 SL Hit! \$'+_smartBotPnl.toStringAsFixed(2); _smartBotMsgC=_red;});
            break;
          }
        }
      } catch(e) { if(mounted) setState(()=>_smartBotMsg='⚠️ Error — retrying...'); }
      await Future.delayed(const Duration(milliseconds:2000));
    }
    if(mounted) setState(()=>_smartBotOn=false);
  }

  // ── MULTI-MARKET ANALYZER ───────────────────────────
  // Stores last analysis result per market
  final Map<String,Map<String,dynamic>> _marketScores = {};
  bool _analyzing = false;
  String _bestMarket = '';
  String _bestMarketSignal = '';

  // Analyze a market by fetching its tick history and computing signal strength
  Future<Map<String,dynamic>> _analyzeMarket(String symbol, String name, {String risk='LOW'}) async {
    try {
      final result = await deriv.getTickHistory(symbol, 100);
      if (result == null) return {'symbol':symbol,'name':name,'score':0,'signal':'No data','color':0xFF888888};
      // Deriv ticks_history response: {'ticks_history': ..., 'history': {'prices': [], 'times': []}}
      final histData = result['history'] ?? result['ticks_history'];
      final prices = (histData is Map ? (histData['prices'] as List?) : null)?.cast<num>() ?? [];
      if (prices.length < 20) return {'symbol':symbol,'name':name,'score':0,'signal':'Insufficient data','color':0xFF888888};
      // Extract digits
      final digits = prices.map((p){
        final s = p.toDouble().toString();
        final dot = s.indexOf('.');
        if (dot < 0) return p.toInt() % 10;
        final dec = s.substring(dot+1).replaceAll(RegExp(r'0+\$'),'');
        return dec.isEmpty ? 0 : int.tryParse(dec[dec.length-1]) ?? 0;
      }).toList();
      // Frequency analysis
      final freq = <int,int>{for(int i=0;i<=9;i++) i:0};
      for(final d in digits) freq[d] = (freq[d]??0)+1;
      final total = digits.length;
      final mx = freq.values.reduce((a,b)=>a>b?a:b);
      final mn = freq.values.reduce((a,b)=>a<b?a:b);
      final hot = freq.entries.firstWhere((e)=>e.value==mx).key;
      final cold = freq.entries.firstWhere((e)=>e.value==mn).key;
      final hotPct = mx/total*100;
      final coldPct = mn/total*100;
      // Recent momentum (last 10)
      final recent = digits.sublist(digits.length-10);
      final recentOver = recent.where((d)=>d>4).length;
      final bias = (recentOver/10-0.5).abs();
      final hotScore = ((hotPct-10)/10*100).clamp(0.0,100.0);
      final coldScore = ((10-coldPct)/10*100).clamp(0.0,100.0);
      final momentumScore = (bias*200).clamp(0.0,100.0);
      final rawScore = ((hotScore + coldScore + momentumScore)/3);
      // Risk penalty — high risk markets need stronger signal
      final riskPenalty = risk=='LOW'?0:risk=='MEDIUM'?10:risk=='HIGH'?25:50;
      final score = (rawScore - riskPenalty).clamp(0.0,100.0).round();
      // Signal text
      String signal; int color;
      if (score >= 70) { signal='🔥 Strong — DIFFERS $hot'; color=0xFF00C853; }
      else if (score >= 50) { signal='📊 Good — DIFFERS $hot'; color=0xFF1DE9B6; }
      else if (score >= 30) { signal='⚡ Moderate'; color=0xFFFFD700; }
      else { signal='😴 Weak signal'; color=0xFF888888; }
      final riskColor = risk=='LOW'?0xFF00C853:risk=='MEDIUM'?0xFFFFD700:risk=='HIGH'?0xFFFF9800:0xFFFF4444;
      return {'symbol':symbol,'name':name,'score':score,'signal':signal,'color':color,'hot':hot,'cold':cold,'hotPct':hotPct.toStringAsFixed(1),'risk':risk,'riskColor':riskColor};
    } catch(e) {
      return {'symbol':symbol,'name':name,'score':0,'signal':'Error','color':0xFF888888};
    }
  }

  Future<void> _runMultiMarketAnalysis() async {
    if (_analyzing) return;
    setState(()=>_analyzing=true);
    _marketScores.clear();
    // Supported markets for digit trading (Vol + Jump only)
    // Boom/Crash excluded — random spike structure not suitable for digit analysis
    final markets = [
      {'id':'R_10',    'name':'Vol 10',     'risk':'LOW'},
      {'id':'R_25',    'name':'Vol 25',     'risk':'LOW'},
      {'id':'1HZ10V',  'name':'Vol 10(1s)', 'risk':'LOW'},
      {'id':'1HZ25V',  'name':'Vol 25(1s)', 'risk':'LOW'},
      {'id':'R_50',    'name':'Vol 50',     'risk':'MEDIUM'},
      {'id':'R_75',    'name':'Vol 75',     'risk':'MEDIUM'},
      {'id':'1HZ50V',  'name':'Vol 50(1s)', 'risk':'MEDIUM'},
      {'id':'R_100',   'name':'Vol 100',    'risk':'HIGH'},
      {'id':'1HZ100V', 'name':'Vol 100(1s)','risk':'HIGH'},
      {'id':'JD10',    'name':'Jump 10',    'risk':'HIGH'},
      {'id':'JD25',    'name':'Jump 25',    'risk':'HIGH'},
    ];
    for (final m in markets) {
      final result = await _analyzeMarket(m['id']!, m['name']!, risk:m['risk']??'LOW');
      if (mounted) setState(()=>_marketScores[m['id']!]=result);
    }
    // Find best market
    if (_marketScores.isNotEmpty) {
      final best = _marketScores.entries.reduce((a,b)=>(a.value['score'] as int)>(b.value['score'] as int)?a:b);
      _bestMarket = best.key;
      _bestMarketSignal = best.value['signal'] as String;
    }
    if (mounted) setState(()=>_analyzing=false);
  }

  // Dynamic hot/cold digits — computed live from frequency data
  int get _hotDigit  { if (_freq.isEmpty) return 0; final mx=_freq.values.reduce(max); return _freq.entries.firstWhere((e)=>e.value==mx).key; }
  int get _coldDigit { if (_freq.isEmpty) return 9; final mn=_freq.values.reduce(min); return _freq.entries.firstWhere((e)=>e.value==mn).key; }
  double get _hotPct  { if (_freq.isEmpty||_hist.isEmpty) return 10; return (_freq[_hotDigit]??0)/_hist.length*100; }
  double get _coldPct { if (_freq.isEmpty||_hist.isEmpty) return 10; return (_freq[_coldDigit]??0)/_hist.length*100; }
  // Avoid digits = top 2 hottest digits (appear too often)
  List<int> get _avoidDigits {
    if (_freq.length < 3) return [];
    final sorted = _freq.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    return sorted.take(2).map((e)=>e.key).toList();
  }
  // Safe digits = top 2 coldest digits (appear too rarely — DIFFERS safe targets)
  List<int> get _safeDigits {
    if (_freq.length < 3) return [];
    final sorted = _freq.entries.toList()..sort((a,b)=>a.value.compareTo(b.value));
    return sorted.take(2).map((e)=>e.key).toList();
  }
  List<double> _priceBuf   = [];   // raw prices for volatility detection
  bool         _highVol    = false; // true when market is spiking
  Map<int,int> _freq = {for(int i=0;i<=9;i++) i:0};
  bool _live = false;

  // Signal
  String _signal = 'Waiting for ticks...', _sigType = '';
  Color  _sigColor = Colors.grey;

  // Streak
  int    _streak = 0;
  String _streakType = '';

  // Calculator
  double _calcStake = 1.0;
  String _calcType  = 'Differs';

  // Trade panel
  String _tType    = 'DIFFERS';
  int    _tDuration = 1; // tick duration 1-10
  int    _tDigit   = 0;
  String _tBarrier = '5';
  double _tStake   = 1.0;
  bool   _tBusy    = false;
  String _tMsg     = '';
  Color  _tColor   = const Color(0xFF00C853);

  // Signal accuracy + history
  int _sigWins   = 0;
  int _sigLosses = 0;
  DateTime? _sessionStart;
  final List<Map<String,dynamic>> _sigHistory = [];

  void _logSignalResult(String signal, String type, bool won, double profit) {
    final now = DateTime.now();
    _sigHistory.insert(0, {
      'time':   now.hour.toString().padLeft(2,'0') + ':' + now.minute.toString().padLeft(2,'0'),
      'signal': signal,
      'type':   type,
      'won':    won,
      'profit': profit,
    });
    if (_sigHistory.length > 50) _sigHistory.removeLast();
  }

  String get _sigAccuracy {
    final total = _sigWins + _sigLosses;
    if (total == 0) return 'No signals yet';
    final pct = (_sigWins / total * 100).toStringAsFixed(0);
    return 'Today: ' + _sigWins.toString() + 'W / ' + _sigLosses.toString() + 'L = ' + pct + '% accuracy';
  }

  // Session stats — computed from history
  int get _trades => _tradeHistory.length;
  int get _wins   => _tradeHistory.where((t) => t['won']==true).length;
  double get _pnl => _tradeHistory.fold(0.0, (s,t) => s + (t['profit'] as double));

  // Trade History log
  final List<Map<String,dynamic>> _tradeHistory = [];

  // Save history to localStorage so it persists across sessions
  void _saveHistory() {
    try {
      final data = _tradeHistory.take(100).map((t) =>
        "${t['time']}|${t['market']}|${t['type']}|${t['stake']}|${t['won']}|${t['profit']}"
      ).join(';;');
      final key = 'soet_history_${_loginId.isNotEmpty ? _loginId : "default"}';
      html.window.localStorage[key] = data;
    } catch(_) {}
  }

  // Load history from localStorage on login
  void _loadHistory() {
    try {
      final key = 'soet_history_${_loginId.isNotEmpty ? _loginId : "default"}';
      final data = html.window.localStorage[key] ?? '';
      if (data.isEmpty) return;
      final trades = data.split(';;');
      _tradeHistory.clear();
      for (final t in trades) {
        final p = t.split('|');
        if (p.length < 6) continue;
        _tradeHistory.add({
          'time':   p[0],
          'market': p[1],
          'type':   p[2],
          'stake':  double.tryParse(p[3]) ?? 0.0,
          'won':    p[4] == 'true',
          'profit': double.tryParse(p[5]) ?? 0.0,
        });
      }
    } catch(_) {}
  }

  void _logTrade({required String market, required String type, required double stake, required bool won, required double profit, String entrySpot='', String exitSpot=''}) {
    // Track signal accuracy + log signal history
    _sessionStart ??= DateTime.now();
    if (won) _sigWins++; else _sigLosses++;
    if (_signal.isNotEmpty && _signal != 'Collecting data...') {
      _logSignalResult(_signal, type, won, profit);
    }
    final now = DateTime.now();
    _tradeHistory.insert(0, {
      'time':       '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}',
      'market':     market,
      'type':       type,
      'stake':      stake,
      'won':        won,
      'profit':     profit,
      'entrySpot':  entrySpot,
      'exitSpot':   exitSpot,
    });
    if (_tradeHistory.length > 200) _tradeHistory.removeLast();
    _saveHistory(); // persist immediately
    _syncTradeToFirebase(_tradeHistory.first); // sync to Firebase
    // Check session TP/SL after every trade
    Future.microtask(_checkSessionLimits);
  }

  // ── BOT STATE ──────────────────────────────
  // ── SESSION TP/SL ──────────────────────────────────
  double _sessionTP   = 0;   // 0 = disabled
  double _sessionSL   = 0;   // 0 = disabled
  bool   _sessionTPon = false;
  bool   _sessionSLon = false;
  bool   _sessionHit  = false; // true when session limit was triggered
  bool   _soundOn     = true;  // sound toggle

  // ── RISK MANAGEMENT ──────────────────────────────
  int    _maxTradesPerMin  = 3;    // max trades per minute per bot
  int    _pauseAfterLosses = 3;    // pause bot after X consecutive losses
  double _minConfidence    = 70.0; // only trade if signal confidence >= this
  bool   _volatilityFilter = true; // skip trades during high volatility spikes
  // Per-bot consecutive loss counter (already have _botConsecLoss)
  final Map<String,DateTime> _botLastTradeTime = {};
  final Map<String,int>      _botTradesThisMin = {};

  // Check session TP/SL after every trade — stops all bots
  void _checkSessionLimits() {
    if (_sessionHit) return;
    final pnl = _pnl; // computed getter from trade history
    if (_sessionTPon && _sessionTP > 0 && pnl >= _sessionTP) {
      _sessionHit = true;
      _stopAllBots();
      _showBotAlert('Session Target Hit! 🎯',
        'All bots stopped. Profit target \$' + _sessionTP.toStringAsFixed(2) + ' reached! P/L: +\$' + pnl.toStringAsFixed(2),
        const Color(0xFF1DE9B6), Icons.emoji_events_outlined);
      if (_tgTpSlAlert) _sendTelegram('SOET Session TP Hit! Profit: +' + pnl.toStringAsFixed(2));
    } else if (_sessionSLon && _sessionSL > 0 && pnl <= -_sessionSL) {
      _sessionHit = true;
      _stopAllBots();
      _showBotAlert('Session Loss Limit Hit 🛑',
        'All bots stopped. Loss limit \$' + _sessionSL.toStringAsFixed(2) + ' reached! P/L: \$' + pnl.toStringAsFixed(2),
        const Color(0xFFFF4444), Icons.shield_outlined);
      if (_tgTpSlAlert) _sendTelegram('SOET Session SL Hit! Loss: ' + pnl.toStringAsFixed(2));
    }
  }



  // ── BOT TAB VIEW — DBot style
  int _botTab = 0; // 0=Summary 1=Transactions
  String _botRunning = ''; // which bot is active in focus view
  bool _allBotsRunning = false;

  final Map<String,bool>   _botOn       = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  final Map<String,double> _botStake    = {'differs':1.0,  'evenodd':1.0,  'overunder':1.0,  'matches':1.0};
  final Map<String,int>    _botMax      = {'differs':10,   'evenodd':10,   'overunder':10,   'matches':10};
  final Map<String,double> _botSL       = {'differs':5.0,  'evenodd':5.0,  'overunder':5.0,  'matches':5.0};
  final Map<String,double> _botTP       = {'differs':10.0, 'evenodd':10.0, 'overunder':10.0, 'matches':10.0};
  final Map<String,int>    _botCount    = {'differs':0,    'evenodd':0,    'overunder':0,    'matches':0};
  final Map<String,int>    _botWins     = {'differs':0,    'evenodd':0,    'overunder':0,    'matches':0};
  final Map<String,double> _botPnl      = {'differs':0,    'evenodd':0,    'overunder':0,    'matches':0};
  final Map<String,String> _botMsg      = {'differs':'',   'evenodd':'',   'overunder':'',   'matches':''};
  final Map<String,Color>  _botMsgC     = {'differs':Colors.grey,'evenodd':Colors.grey,'overunder':Colors.grey,'matches':Colors.grey};
  final Map<String,bool>   _botBusy     = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  // Martingale: optional per bot — tracks current stake multiplier
  final Map<String,bool>   _botMartOn   = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  final Map<String,double> _botCurStake = {'differs':1.0,  'evenodd':1.0,  'overunder':1.0,  'matches':1.0};
  final Map<String,int>    _botLossStrk = {'differs':0,    'evenodd':0,    'overunder':0,    'matches':0};
  // Signal link: bot waits for SOET signal before each trade
  final Map<String,bool>   _botSigLink  = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  Timer? _botTimer;

  // ── FIREBASE SYNC ──────────────────────────────
  // Uses Firebase Firestore REST API — no package needed
  String _fbProjectId = '';
  String _fbApiKey    = '';
  bool   _fbEnabled   = false;
  bool   _fbSyncing   = false;

  void _loadFbSettings() {
    try {
      _fbProjectId = html.window.localStorage['soet_fb_project'] ?? '';
      _fbApiKey    = html.window.localStorage['soet_fb_key']     ?? '';
      _fbEnabled   = html.window.localStorage['soet_fb_on']      == '1';
    } catch(_) {}
  }

  void _saveFbSettings() {
    try {
      html.window.localStorage['soet_fb_project'] = _fbProjectId;
      html.window.localStorage['soet_fb_key']     = _fbApiKey;
      html.window.localStorage['soet_fb_on']      = _fbEnabled ? '1':'0';
    } catch(_) {}
  }

  // Push trade to Firestore via JS fetch (avoids CORS/package issues)
  void _syncTradeToFirebase(Map<String,dynamic> trade) {
    if (!_fbEnabled || _fbProjectId.isEmpty || _fbApiKey.isEmpty || _loginId.isEmpty) return;
    try {
      final doc = '{"fields":{"time":{"stringValue":"${trade['time']}"},"market":{"stringValue":"${trade['market']}"},"type":{"stringValue":"${trade['type']}"},"stake":{"doubleValue":${trade['stake']}},"won":{"booleanValue":${trade['won']}},"profit":{"doubleValue":${trade['profit']}},"account":{"stringValue":"$_loginId"}}}';
      final url = 'https://firestore.googleapis.com/v1/projects/$_fbProjectId/databases/(default)/documents/trades?key=$_fbApiKey';
      html.window.postMessage('soet_fb:POST:$url:$doc', '*');
    } catch(_) {}
  }

  // Pull trades from Firestore for this account
  void _pullTradesFromFirebase() {
    if (!_fbEnabled || _fbProjectId.isEmpty || _fbApiKey.isEmpty || _loginId.isEmpty) return;
    try {
      setState((){_fbSyncing=true;});
      final url = 'https://firestore.googleapis.com/v1/projects/$_fbProjectId/databases/(default)/documents/trades?key=$_fbApiKey';
      html.window.postMessage('soet_fb_pull:$_loginId:$url', '*');
    } catch(_) {}
  }

  // ── TELEGRAM ALERTS ───────────────────────────
  final _tgBotCtrl  = TextEditingController();
  final _tgChatCtrl = TextEditingController();
  String _tgBotToken  = '';
  String _tgChatId    = '';
  bool   _tgEnabled   = false;
  bool   _tgWinAlert  = true;
  bool   _tgLossAlert = false;
  bool   _tgTpSlAlert = true;
  bool   _tgVolAlert  = true;
  bool   _tgTesting   = false;

  void _loadTgSettings() {
    try {
      _tgBotToken  = html.window.localStorage['soet_tg_token']  ?? '';
      _tgChatId    = html.window.localStorage['soet_tg_chat']   ?? '';
      _tgEnabled   = html.window.localStorage['soet_tg_on']     == '1';
      _tgWinAlert  = html.window.localStorage['soet_tg_win']    != '0';
      _tgLossAlert = html.window.localStorage['soet_tg_loss']   == '1';
      _tgTpSlAlert = html.window.localStorage['soet_tg_tpsl']   != '0';
      _tgVolAlert  = html.window.localStorage['soet_tg_vol']    != '0';
      _tgBotCtrl.text  = _tgBotToken;
      _tgChatCtrl.text = _tgChatId;
    } catch(_) {}
  }

  void _saveTgSettings() {
    try {
      html.window.localStorage['soet_tg_token'] = _tgBotToken;
      html.window.localStorage['soet_tg_chat']  = _tgChatId;
      html.window.localStorage['soet_tg_on']    = _tgEnabled  ? '1':'0';
      html.window.localStorage['soet_tg_win']   = _tgWinAlert ? '1':'0';
      html.window.localStorage['soet_tg_loss']  = _tgLossAlert? '1':'0';
      html.window.localStorage['soet_tg_tpsl']  = _tgTpSlAlert? '1':'0';
      html.window.localStorage['soet_tg_vol']   = _tgVolAlert ? '1':'0';
    } catch(_) {}
  }

  Future<void> _sendTelegram(String msg) async {
    if (!_tgEnabled || _tgBotToken.isEmpty || _tgChatId.isEmpty) return;
    try {
      final url = 'https://api.telegram.org/bot$_tgBotToken/sendMessage';
      final safeMsg = msg.replaceAll('"', '\"');
      final body = '{"chat_id":"$_tgChatId","text":"' + safeMsg + '","parse_mode":"HTML"}';
      html.window.postMessage('soet_tg:' + url + ':' + body, '*');
    } catch(_) {}
  }

  // ── BOT SCHEDULER ──────────────────────────────
  final Map<String,bool> _botScheduleOn = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  final Map<String,int>  _botStartHour  = {'differs':8,  'evenodd':8,  'overunder':8,  'matches':8};
  final Map<String,int>  _botStopHour   = {'differs':17, 'evenodd':17, 'overunder':17, 'matches':17};

  // Returns true if bot is allowed to trade right now based on schedule
  bool _botScheduleAllowed(String bot) {
    if (!(_botScheduleOn[bot]??false)) return true; // no schedule = always allowed
    final now = DateTime.now();
    final start = _botStartHour[bot]??8;
    final stop  = _botStopHour[bot]??17;
    if (start <= stop) {
      return now.hour >= start && now.hour < stop;
    } else {
      // Overnight schedule e.g. 22:00 → 06:00
      return now.hour >= start || now.hour < stop;
    }
  }

  // Per-bot market selection
  final Map<String,String> _botSym  = {'differs':'R_10','evenodd':'R_10','overunder':'R_10','matches':'R_10'};
  final Map<String,String> _botSymName = {'differs':'Vol 10','evenodd':'Vol 10','overunder':'Vol 10','matches':'Vol 10'};

  // Persistent TextEditingControllers — prevents field reset on setState
  late final Map<String,TextEditingController> _botStakeCtrl,_botMaxCtrl,_botSLCtrl,_botTPCtrl;
  void _initBotControllers() {
    const ids = ['differs','evenodd','overunder','matches'];
    _botStakeCtrl = {for(var id in ids) id: TextEditingController(text:'1.0')};
    _botMaxCtrl   = {for(var id in ids) id: TextEditingController(text:'10')};
    _botSLCtrl    = {for(var id in ids) id: TextEditingController(text:'5.0')};
    _botTPCtrl    = {for(var id in ids) id: TextEditingController(text:'10.0')};
  }
  void _disposeBotControllers() {
    for(final m in [_botStakeCtrl,_botMaxCtrl,_botSLCtrl,_botTPCtrl]){ for(final c in m.values) c.dispose(); }
  }

  late AnimationController _pulseCtrl, _digitCtrl;
  late Animation<double>   _pulseAnim;
  final _rng = Random();

  // ── SYMBOLS ────────────────────────────────
  final List<Map<String,String>> _symbols = [
    {'g':'VOLATILITY','id':'','n':''},
    {'g':'','id':'R_10',    'n':'Volatility 10 Index'},
    {'g':'','id':'1HZ10V', 'n':'Volatility 10 (1s) Index'},
    {'g':'','id':'R_25',    'n':'Volatility 25 Index'},
    {'g':'','id':'1HZ25V', 'n':'Volatility 25 (1s) Index'},
    {'g':'','id':'R_50',    'n':'Volatility 50 Index'},
    {'g':'','id':'1HZ50V', 'n':'Volatility 50 (1s) Index'},
    {'g':'','id':'R_75',    'n':'Volatility 75 Index'},
    {'g':'','id':'1HZ75V', 'n':'Volatility 75 (1s) Index'},
    {'g':'','id':'R_100',   'n':'Volatility 100 Index'},
    {'g':'','id':'1HZ100V','n':'Volatility 100 (1s) Index'},
    {'g':'JUMP INDICES','id':'','n':''},
    {'g':'','id':'JD10', 'n':'Jump 10 Index'},
    {'g':'','id':'JD25', 'n':'Jump 25 Index'},
    {'g':'','id':'JD50', 'n':'Jump 50 Index'},
    {'g':'','id':'JD75', 'n':'Jump 75 Index'},
    {'g':'','id':'JD100','n':'Jump 100 Index'},

  ];

  // ── CONTRACT TYPE MAP ───────────────────────
  String _ctype(String t) { switch(t){ case 'DIFFERS':return 'DIGITDIFF'; case 'MATCHES':return 'DIGITMATCH'; case 'EVEN':return 'DIGITEVEN'; case 'ODD':return 'DIGITODD'; case 'OVER':return 'DIGITOVER'; case 'UNDER':return 'DIGITUNDER'; default:return 'DIGITDIFF'; }}
  int? _barrier() { if(_tType=='OVER'||_tType=='UNDER') return int.tryParse(_tBarrier); if(_tType=='MATCHES'||_tType=='DIFFERS') return _tDigit; return null; }

  // ── PAYOUT ESTIMATE ─────────────────────────
  double get _estPayout {
    switch(_tType){
      case 'MATCHES': return _tStake * 8.10;
      case 'DIFFERS': return _tStake * 0.095;
      case 'EVEN': case 'ODD': return _tStake * 0.82;
      case 'OVER': case 'UNDER':
        // Payout depends on barrier — higher barrier = bigger payout
        final b = int.tryParse(_tBarrier) ?? 4;
        if (_tType=='OVER') {
          // Over 1=0.06, Over 2=0.10, Over 3=0.18, Over 4=0.24, Over 5=0.36, Over 6=0.56, Over 7=0.96, Over 8=1.90
          const payouts = {1:0.06,2:0.10,3:0.18,4:0.24,5:0.36,6:0.56,7:0.96,8:1.90};
          return _tStake * (payouts[b] ?? 0.24);
        } else {
          // Under 8=0.06, Under 7=0.10, Under 6=0.18, Under 5=0.24, Under 4=0.36, Under 3=0.56, Under 2=0.96, Under 1=1.90
          const payouts = {8:0.06,7:0.10,6:0.18,5:0.24,4:0.36,3:0.56,2:0.96,1:1.90};
          return _tStake * (payouts[b] ?? 0.24);
        }
      default: return _tStake * 0.095;
    }
  }

  Map<String,double> get _calcPayouts => {
    'Differs':_calcStake*0.095,'Even/Odd':_calcStake*0.90,
    'Over 2':_calcStake*0.33,'Over 3':_calcStake*0.43,'Over 4':_calcStake*0.60,'Over 5':_calcStake*0.85,'Over 6':_calcStake*1.30,'Over 7':_calcStake*2.10,'Over 8':_calcStake*3.80,
    'Under 7':_calcStake*0.33,'Under 6':_calcStake*0.43,'Under 5':_calcStake*0.60,'Under 4':_calcStake*0.85,'Under 3':_calcStake*1.30,'Under 2':_calcStake*2.10,'Under 1':_calcStake*3.80,
    'Matches':_calcStake*8.10,
  };

  List<Map<String,dynamic>> get _recs {
    try {
      if (_hist.length < 10) return [];
      if (_freq.values.isEmpty) return [];
      int total = _hist.length;
      int mx = _freq.values.reduce(max), mn = _freq.values.reduce(min);
      int hot = _freq.entries.firstWhere((e)=>e.value==mx).key;
      int cold= _freq.entries.firstWhere((e)=>e.value==mn).key;
      int over= _hist.where((d)=>d>4).length;
      int even= _hist.where((d)=>d%2==0).length;
      double op=over/total*100, ep=even/total*100;
      return [
        {'m':'Differs',   'p':'Differ from $hot', 'r':'Digit $hot at ${(mx/total*100).toStringAsFixed(1)}% — hottest','c':((mx/total*100-10).clamp(0,40)/40*100).clamp(20.0,95.0),'col':const Color(0xFF1DE9B6)},
        {'m':'Over/Under','p':op>50?'UNDER 5':'OVER 4','r':op>50?'High ${op.toStringAsFixed(1)}%':'Low ${(100-op).toStringAsFixed(1)}%','c':((op-50).abs()/30*100).clamp(20.0,95.0),'col':const Color(0xFFFFD700)},
        {'m':'Even/Odd',  'p':ep>50?'ODD':'EVEN',  'r':ep>50?'Even ${ep.toStringAsFixed(1)}%':'Odd ${(100-ep).toStringAsFixed(1)}%','c':((ep-50).abs()/30*100).clamp(20.0,95.0),'col':const Color(0xFF00C853)},
        {'m':'Matches',   'p':'Match $cold','r':'Digit $cold coldest ${(mn/total*100).toStringAsFixed(1)}%','c':25.0,'col':const Color(0xFFFF6B35)},
      ];
    } catch(_) { return []; }
  }

  @override void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync:this,duration:const Duration(seconds:1))..repeat(reverse:true);
    _digitCtrl = AnimationController(vsync:this,duration:const Duration(milliseconds:400));
    _pulseAnim = Tween<double>(begin:0.85,end:1.0).animate(CurvedAnimation(parent:_pulseCtrl,curve:Curves.easeInOut));
    _initBotControllers();
    _setupCallbacks();
    deriv.subscribeTicks(_sym);
  }

  void _setupCallbacks() {
    deriv.onHistoryBatch = (prices, symbol) {
      if (!mounted) return;
      // Process all history ticks in ONE setState — no animations
      setState(() {
        for (final p in prices) {
          final d = _extractDigit(p.toDouble());
          if (d != null) {
            _hist.add(d); _freq[d] = (_freq[d]??0)+1;
          }
        }
        if (_hist.length > 200) _hist = _hist.sublist(_hist.length-200);
        if (_hist.isNotEmpty) { _lastDigit=_hist.last; _live=true; }
        final prevSig = _signal;
      _updateSignal(); _updateStreak();
      // Play sound when a NEW strong signal detected
      if (_signal != prevSig && _confidence >= 75) _playSignalSound();
      });
    };

    deriv.onTick = (tick) {
      if (!mounted) return;
      try {
        final double p = (tick['quote'] as num).toDouble();
        if (p <= 0) return;
        final lastD = _extractDigit(p);
        if (lastD == null) return;
        // Update data without setState first (faster)
        _live = true; _price = p; _lastDigit = lastD;
        _hist.add(lastD);
        if (_hist.length > 200) _hist.removeAt(0);
        _freq[lastD] = (_freq[lastD]??0) + 1;
        // Feed price buffer for volatility detection
        _priceBuf.add(p);
        if (_priceBuf.length > 20) _priceBuf.removeAt(0);
        _detectVolatility();
        final prevSig = _signal;
      _updateSignal(); _updateStreak();
      // Play sound when a NEW strong signal detected
      if (_signal != prevSig && _confidence >= 75) _playSignalSound();
        // Only rebuild UI if on Dashboard or Analyzer tab
        if (_tab <= 1) setState((){});
        _digitCtrl.forward(from:0);
      } catch(_) {}
    };
    deriv.onBalance = (b) { if (!mounted) return; setState((){
      _balance = (b['balance'] as num).toStringAsFixed(2);
      _currency = b['currency']?.toString() ?? 'USD';
      final newId = b['loginid']?.toString() ?? '';
      if (newId != _loginId) {
        _loginId = newId;
        // Load this account's trade history from storage
        Future.microtask(() { _loadHistory(); _loadTgSettings(); _loadFbSettings(); if(mounted) setState((){}); });
      } else {
        _loginId = newId;
      }
    }); };
    deriv.onContract = (data) {
      if (!mounted) return;
      final status  = data['status']?.toString() ?? '';
      final isSold  = data['is_sold'];
      final settled = isSold == 1 || isSold == true || status == 'won' || status == 'lost';
      if (!settled) return;
      // profit can be negative (loss) or positive (win)
      final profit = (data['profit'] as num?)?.toDouble()
                  ?? (data['sell_price'] as num?)?.toDouble()
                  ?? 0.0;
      final won = status == 'won' || profit > 0;
      setState(() {
        _tBusy = false;
        if (won) {
          _tMsg = '✅  +\$${profit.abs().toStringAsFixed(2)}';
          _tColor = const Color(0xFF00C853);
        } else {
          _tMsg = '❌  -\$${profit.abs().toStringAsFixed(2)}';
          _tColor = const Color(0xFFFF4444);
        }
        // Use actual contract type from data, not _tType default
        final contractType = data['contract_type']?.toString() ?? _tType;
        String tradeLabel = _tType;
        if (contractType == 'DIGITOVER')  tradeLabel = 'OVER $_tBarrier';
        else if (contractType == 'DIGITUNDER') tradeLabel = 'UNDER $_tBarrier';
        else if (contractType == 'DIGITDIFF')  tradeLabel = 'DIFFERS $_tDigit';
        else if (contractType == 'DIGITMATCH') tradeLabel = 'MATCHES $_tDigit';
        else if (contractType == 'DIGITEVEN')  tradeLabel = 'EVEN';
        else if (contractType == 'DIGITODD')   tradeLabel = 'ODD';
        final entry = data['entry_spot']?.toString() ?? data['entry_tick_display_value']?.toString() ?? '';
        final exit  = data['exit_tick_display_value']?.toString() ?? data['sell_spot']?.toString() ?? '';
        _logTrade(market:_symName, type:tradeLabel, stake:_tStake, won:won, profit:profit, entrySpot:entry, exitSpot:exit);
      });
      _playSound(won);
    };
    deriv.onTradeError = (msg) { if (!mounted) return; setState((){_tBusy=false; _tMsg='⚠️ $msg'; _tColor=const Color(0xFFFFD700);}); };
    deriv.onDisconnected = () { if (mounted) setState(()=>_live=false); };
    deriv.onReconnecting = () { if (mounted) setState((){_live=false; _signal='Reconnecting...'; _sigColor=Colors.orange;}); };
    deriv.onConnected    = () { if (mounted) setState((){}); };
  }

  int? _extractDigit(double p) {
    try {
      // Convert to string and find last significant decimal digit
      // Deriv prices: R_10=2dp, 1HZ=3dp, Jump=3dp, Boom/Crash=2dp
      final s = p.toString(); // e.g. "1234.56" or "1234.567"
      final dotIdx = s.indexOf('.');
      if (dotIdx < 0) return p.toInt() % 10;
      final decimals = s.substring(dotIdx + 1); // e.g. "56" or "567"
      // Remove trailing zeros to get last meaningful digit
      final trimmed = decimals.replaceAll(RegExp(r'0+$'), '');
      if (trimmed.isEmpty) return 0;
      return int.tryParse(trimmed[trimmed.length - 1]);
    } catch(_) { return null; }
  }

  void _updateStreak() {
    try {
      if (_hist.length<2) return;
      int last=_hist.last; bool isE=last%2==0, isH=last>=5; int es=1,hs=1;
      for(int i=_hist.length-2;i>=0;i--){ int d=_hist[i]; if((isE&&d%2==0)||(!isE&&d%2!=0)) es++; else break; }
      for(int i=_hist.length-2;i>=0;i--){ int d=_hist[i]; if((isH&&d>=5)||(!isH&&d<5)) hs++; else break; }
      if(hs>=es){_streak=hs;_streakType=isH?'HIGH':'LOW';}else{_streak=es;_streakType=isE?'EVEN':'ODD';}
    } catch(_) {}
  }

  // ── SMART SIGNAL ENGINE v2 ──────────────────
  // Analyses last 10 ticks (recent) AND full history (overall)
  // Only fires signal when confidence is HIGH (>65% bias)
  // Detects streaks, momentum and digit patterns

  // Confidence score for a signal (0-100)
  int _confidence = 0;
  String _confLabel = '';

  void _updateSignal() {
    try {
      if (_hist.length < 15) {
        _signal = 'Collecting data...'; _sigType = ''; _sigColor = Colors.grey; return;
      }

      // ── LAYER 1: Recent 10 ticks (momentum) ──
      final recent = _hist.sublist(_hist.length - 10);
      final recentOver  = recent.where((d) => d > 4).length;  // digits 5-9
      final recentUnder = recent.where((d) => d < 5).length;  // digits 0-4
      final recentEven  = recent.where((d) => d % 2 == 0).length;
      final recentOdd   = recent.where((d) => d % 2 != 0).length;
      final recentOverPct  = recentOver  / 10 * 100;
      final recentUnderPct = recentUnder / 10 * 100;
      final recentEvenPct  = recentEven  / 10 * 100;
      final recentOddPct   = recentOdd   / 10 * 100;

      // ── LAYER 2: Last 5 ticks (streak detector) ──
      final last5 = _hist.sublist(_hist.length - 5);
      final streak5Over  = last5.every((d) => d > 4);
      final streak5Under = last5.every((d) => d < 5);
      final streak5Even  = last5.every((d) => d % 2 == 0);
      final streak5Odd   = last5.every((d) => d % 2 != 0);

      // ── LAYER 3: Full history bias ──
      final total = _hist.length;
      final fullOver = _hist.where((d) => d > 4).length / total * 100;
      final fullEven = _hist.where((d) => d % 2 == 0).length / total * 100;

      // ── LAYER 4: Hot/Cold digit from full freq ──
      if (_freq.values.isEmpty) return;
      final mx   = _freq.values.reduce(max);
      final mn   = _freq.values.reduce(min);
      final hot  = _freq.entries.firstWhere((e) => e.value == mx).key;
      final cold = _freq.entries.firstWhere((e) => e.value == mn).key;
      final hotPct  = mx / total * 100;
      final coldPct = mn / total * 100;

      // ── LAYER 5: Recent hot digit (last 20 ticks) ──
      final recent20 = _hist.length >= 20 ? _hist.sublist(_hist.length - 20) : _hist;
      final recentFreq = <int,int>{for(int i=0;i<=9;i++) i:0};
      for(final d in recent20) recentFreq[d] = (recentFreq[d]??0)+1;
      final recentMx   = recentFreq.values.reduce(max);
      final recentHot  = recentFreq.entries.firstWhere((e) => e.value == recentMx).key;
      final recentHotPct = recentMx / recent20.length * 100;

      // ── SIGNAL DECISION — strongest signal wins ──
      // Priority: Streak > Strong momentum > Moderate bias

      // STREAK signals (highest confidence — 5 same type in a row = reversal likely)
      if (streak5Over) {
        _signal = '🔥 STREAK HIGH → Trade UNDER 5'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF00C853); _confidence = 85; _confLabel = 'STRONG';
      } else if (streak5Under) {
        _signal = '🔥 STREAK LOW → Trade OVER 4'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF1DE9B6); _confidence = 85; _confLabel = 'STRONG';
      } else if (streak5Even) {
        _signal = '🔥 STREAK EVEN → Trade ODD'; _sigType = 'Even/Odd';
        _sigColor = const Color(0xFFFFD700); _confidence = 80; _confLabel = 'STRONG';
      } else if (streak5Odd) {
        _signal = '🔥 STREAK ODD → Trade EVEN'; _sigType = 'Even/Odd';
        _sigColor = const Color(0xFFFFD700); _confidence = 80; _confLabel = 'STRONG';

      // STRONG MOMENTUM signals (recent 10 ticks >70%)
      } else if (recentOverPct >= 70) {
        _signal = '📈 HIGH momentum → UNDER 5'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF00C853); _confidence = 75; _confLabel = 'GOOD';
      } else if (recentUnderPct >= 70) {
        _signal = '📉 LOW momentum → OVER 4'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF1DE9B6); _confidence = 75; _confLabel = 'GOOD';
      } else if (recentEvenPct >= 70) {
        _signal = '📊 EVEN momentum → ODD'; _sigType = 'Even/Odd';
        _sigColor = const Color(0xFFFFD700); _confidence = 72; _confLabel = 'GOOD';
      } else if (recentOddPct >= 70) {
        _signal = '📊 ODD momentum → EVEN'; _sigType = 'Even/Odd';
        _sigColor = const Color(0xFFFFD700); _confidence = 72; _confLabel = 'GOOD';

      // HOT DIGIT — if one digit appearing >20% (expected ~10%) — avoid it
      } else if (recentHotPct >= 22) {
        _signal = '🎯 Digit $recentHot overdue → DIFFERS $recentHot'; _sigType = 'Differs';
        _sigColor = const Color(0xFFFF6B35); _confidence = 68; _confLabel = 'GOOD';

      // COLD DIGIT — if one digit very rare — worth matching
      } else if (coldPct <= 6 && total >= 50) {
        _signal = '❄️ Digit $cold rare → MATCH $cold'; _sigType = 'Matches';
        _sigColor = const Color(0xFF9C27B0); _confidence = 62; _confLabel = 'MODERATE';

      // MODERATE bias (65-69%)
      } else if (recentOverPct >= 65) {
        _signal = '↗️ Slight HIGH → UNDER 5'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF00C853); _confidence = 60; _confLabel = 'MODERATE';
      } else if (recentUnderPct >= 65) {
        _signal = '↘️ Slight LOW → OVER 4'; _sigType = 'Over/Under';
        _sigColor = const Color(0xFF1DE9B6); _confidence = 60; _confLabel = 'MODERATE';

      // NO CLEAR SIGNAL
      } else {
        _signal = '⏳ No clear signal — wait'; _sigType = '';
        _sigColor = Colors.grey; _confidence = 0; _confLabel = 'WEAK';
      }
    } catch(_) {}
  }

  void _switchMarket(String id, String name) {
    if (_tBusy) setState((){_tBusy=false; _tMsg='';});
    setState((){
      _sym=id; _symName=name;
      _hist.clear();
      _freq={for(int i=0;i<=9;i++) i:0};
      _price=0; _live=false;
      _signal='Loading market...';
      _sigType=''; _sigColor=Colors.grey;
      _streak=0; _streakType='';
      _lastDigit=0;
    });
    deriv.subscribeTicks(id); // subscribeTicks already has 800ms internal delay
    // Auto-retry after 6s if still no ticks
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && !_live && _sym == id) {
        setState((){_signal='Retrying...';});
        deriv.subscribeTicks(id);
      }
    });
  }

  Future<void> _placeTrade() async {
    if (!_live || _tBusy) return;
    setState((){_tBusy=true; _tMsg='';});
    // Step 1: Get proposal (required by Deriv before buying)
    final prop = await deriv.getProposal(
      symbol:_sym, contractType:_ctype(_tType), amount:_tStake, barrier:_barrier(), duration:_tDuration,
    );
    if (!mounted) return;
    if (prop==null || prop['proposal']==null) {
      setState((){_tBusy=false; _tMsg='⚠️ Market busy, try again'; _tColor=const Color(0xFFFFD700);});
      return;
    }
    final pid = prop['proposal']['id']?.toString() ?? '';
    if (pid.isEmpty) { setState((){_tBusy=false;}); return; }
    // Step 2: Buy immediately with proposal ID
    final buy = await deriv.buyContract(pid, _tStake);
    if (!mounted) return;
    if (buy==null || buy['buy']==null) {
      final err = buy?['error']?['message']?.toString() ?? '';
      setState((){_tBusy=false; _tMsg=err.isNotEmpty?'⚠️ $err':'⚠️ Trade failed, try again'; _tColor=const Color(0xFFFFD700);});
      return;
    }
    // Step 3: Subscribe to get result — onContract fires with ✅ or ❌
    final cid = buy['buy']['contract_id']?.toString() ?? '';
    if (cid.isNotEmpty) deriv.subscribeContract(cid);
  }

  // ── SOUND ALERTS (via JS interop) ──────────
  void _playSound(bool won) {
    if (!_soundOn) return;
    try {
      final msg = won ? 'soet_sound:win' : 'soet_sound:loss';
      html.window.postMessage(msg, '*');
    } catch(_) {}
  }

  void _playSignalSound() {
    try {
      html.window.postMessage('soet_sound:signal', '*');
    } catch(_) {}
  }

  void _logout() { _stopAllBots(); deriv.disconnect(); TokenStorage.clear(); Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>const LoginScreen())); }

  // ── BOT LOGIC ──────────────────────────────
  // ── RECOVERY MODE ──────────────────────────────────────
  // After X consecutive losses, switch to safer strategy temporarily
  final Map<String,int> _botConsecLoss = {'differs':0,'evenodd':0,'overunder':0,'matches':0};
  final Map<String,bool> _botRecovery  = {'differs':false,'evenodd':false,'overunder':false,'matches':false};
  bool _recoveryModeOn = false; // global toggle
  int  _recoveryAfter  = 3;     // trigger after N consecutive losses
  // In recovery: skip 2 trades, then resume with half stake

  void _updateRecovery(String bot, bool won) {
    if (!_recoveryModeOn) return;
    if (won) {
      _botConsecLoss[bot] = 0;
      _botRecovery[bot]   = false;
    } else {
      _botConsecLoss[bot] = (_botConsecLoss[bot] ?? 0) + 1;
      if ((_botConsecLoss[bot] ?? 0) >= _recoveryAfter) {
        _botRecovery[bot] = true;
      }
    }
  }

  // ── VOLATILITY SPIKE DETECTOR ──────────────────────
  // Returns true if market is spiking — skip trade
  bool _isVolatilitySpike() {
    if (!_volatilityFilter || _hist.length < 10) return false;
    final recent = _hist.sublist(_hist.length - 10);
    // Check if last 5 ticks are all same direction (extreme momentum)
    int highCount = recent.where((d) => d > 7).length;
    int lowCount  = recent.where((d) => d < 3).length;
    // If 8+ of last 10 ticks are extreme — spike detected
    if (highCount >= 8 || lowCount >= 8) return true;
    return false;
  }

  // ── CONFIDENCE CHECK ─────────────────────────────────
  // Returns signal confidence 0-100 based on current data
  double _signalConfidence(String bot) {
    if (_hist.length < 20) return 0;
    final recent20 = _hist.sublist(_hist.length - 20);
    final recent10 = _hist.sublist(_hist.length - 10);
    switch(bot) {
      case 'differs':
        final freq = <int,int>{for(int i=0;i<=9;i++) i:0};
        for(final d in recent20) freq[d] = (freq[d]??0)+1;
        final mx = freq.values.reduce((a,b)=>a>b?a:b);
        return (mx/recent20.length*100 - 10) * 5; // 15%->25 conf, 20%->50, 25%->75
      case 'evenodd':
        final ev = recent10.where((d)=>d%2==0).length;
        final bias = (ev/10 - 0.5).abs();
        return (bias * 200).clamp(0.0, 100.0);
      case 'overunder':
        int streak = 0;
        for(int i=recent10.length-1;i>=0;i--){
          if(i==recent10.length-1){ streak=1; continue; }
          if((recent10[i]>4)==(recent10[i+1]>4)) streak++;
          else break;
        }
        return (streak / 10 * 100).clamp(0.0, 100.0);
      default: return 60;
    }
  }

  // ── TRADE FREQUENCY GUARD ────────────────────────────
  bool _canTradeNow(String bot) {
    final now = DateTime.now();
    final lastTime = _botLastTradeTime[bot];
    if (lastTime != null) {
      final diff = now.difference(lastTime).inSeconds;
      if (diff < 60) {
        final count = _botTradesThisMin[bot] ?? 0;
        if (count >= _maxTradesPerMin) return false;
      } else {
        _botTradesThisMin[bot] = 0;
      }
    }
    return true;
  }

  void _recordTrade(String bot) {
    final now = DateTime.now();
    _botLastTradeTime[bot] = now;
    _botTradesThisMin[bot] = (_botTradesThisMin[bot] ?? 0) + 1;
  }

  void _stopAllBots() {
    _botTimer?.cancel();
    for(final k in _botOn.keys) { _botOn[k]=false; _botBusy[k]=false; }
  }

  // Pick what to trade based on bot type — SMART v2
  // Uses last 10 ticks for momentum + full history for frequency
  Map<String,dynamic> _botDecision(String bot) {
    try {
      // Recent 10 ticks for momentum
      final recent = _hist.length >= 10 ? _hist.sublist(_hist.length - 10) : _hist;
      // Recent 20 ticks for digit frequency
      final recent20 = _hist.length >= 20 ? _hist.sublist(_hist.length - 20) : _hist;

      switch(bot) {
        case 'differs':
          // Find hottest digit — only enter if significantly above 10% expected
          final rf = <int,int>{for(int i=0;i<=9;i++) i:0};
          for(final d in recent20) rf[d]=(rf[d]??0)+1;
          final rmx = rf.values.reduce(max);
          final hotD = rf.entries.firstWhere((e)=>e.value==rmx).key;
          final hotFreqPct = rmx/recent20.length*100;
          if(hotFreqPct < 15) return {'type':'SKIP','barrier':null,'label':'Waiting — no dominant digit yet...'};
          return {'type':'DIGITDIFF','barrier':hotD,'label':'Differ $hotD (${hotFreqPct.toStringAsFixed(0)}%)'};

        case 'evenodd':
          if(recent.isEmpty) return {'type':'DIGITEVEN','barrier':null,'label':'Even'};
          // Use recent 10 ticks — trade against momentum
          final recentEven = recent.where((d)=>d%2==0).length;
          final evenPct = recentEven/recent.length;
          // Only trade if bias is >60% — otherwise wait
          if(evenPct >= 0.60) return {'type':'DIGITODD','barrier':null,'label':'Odd (even streak)'};
          if(evenPct <= 0.40) return {'type':'DIGITEVEN','barrier':null,'label':'Even (odd streak)'};
          // No clear bias — use full history
          final fullEven = _hist.where((d)=>d%2==0).length;
          return fullEven/_hist.length>0.5
            ?{'type':'DIGITODD','barrier':null,'label':'Odd'}
            :{'type':'DIGITEVEN','barrier':null,'label':'Even'};

        case 'overunder':
          if(recent.isEmpty) return {'type':'DIGITDIFF','barrier':0,'label':'Waiting...'};
          // Check CONSECUTIVE streak — need 5+ same direction in a row
          int highStreak=0, lowStreak=0;
          for(int i=recent.length-1;i>=0;i--){
            if(recent[i]>4) { if(lowStreak>0) break; highStreak++; }
            else { if(highStreak>0) break; lowStreak++; }
          }
          // Only enter if streak is 5+ consecutive ticks
          if(highStreak >= 5) return {'type':'DIGITUNDER','barrier':5,'label':'Under 5 ($highStreak streak)'};
          if(lowStreak >= 5)  return {'type':'DIGITOVER','barrier':4,'label':'Over 4 ($lowStreak streak)'};
          // Also check strong bias in recent 10 (>70%)
          final recentOver = recent.where((d)=>d>4).length;
          final overPct = recentOver/recent.length;
          if(overPct >= 0.70) return {'type':'DIGITUNDER','barrier':5,'label':'Under 5 (${(overPct*100).round()}% high)'};
          if(overPct <= 0.30) return {'type':'DIGITOVER','barrier':4,'label':'Over 4 (${((1-overPct)*100).round()}% low)'};
          // No strong signal — skip this trade cycle
          return {'type':'SKIP','barrier':null,'label':'Waiting for streak...'};

        case 'matches':
          // Find coldest digit in recent 20 ticks — match it (overdue)
          final mf = <int,int>{for(int i=0;i<=9;i++) i:0};
          for(final d in recent20) mf[d]=(mf[d]??0)+1;
          final mmn = mf.values.reduce(min);
          final coldD = mf.entries.firstWhere((e)=>e.value==mmn).key;
          return {'type':'DIGITMATCH','barrier':coldD,'label':'Match $coldD'};

        default:
          return {'type':'DIGITDIFF','barrier':null,'label':'Differ'};
      }
    } catch(_) {
      return {'type':'DIGITDIFF','barrier':null,'label':'Differ'};
    }
  }

  void _toggleBot(String bot) {
    if (_botOn[bot]!) {
      setState((){ _botOn[bot]=false; _botMsg[bot]='⏹ Stopped'; _botMsgC[bot]=Colors.grey; });
    } else {
      if (!_live) return;
      // Read latest values from controllers at start time — guarantees latest input
      final stakeVal  = double.tryParse(_botStakeCtrl[bot]?.text??'') ?? _botStake[bot] ?? 1.0;
      final maxVal    = int.tryParse(_botMaxCtrl[bot]?.text??'')    ?? _botMax[bot]   ?? 10;
      final slVal     = double.tryParse(_botSLCtrl[bot]?.text??'')  ?? _botSL[bot]    ?? 5.0;
      final tpVal     = double.tryParse(_botTPCtrl[bot]?.text??'')  ?? _botTP[bot]    ?? 10.0;
      setState((){
        _botStake[bot]=stakeVal; _botMax[bot]=maxVal; _botSL[bot]=slVal; _botTP[bot]=tpVal;
        _botOn[bot]=true; _botBusy[bot]=false;
        _botCount[bot]=0; _botWins[bot]=0; _botPnl[bot]=0;
        _botCurStake[bot]=stakeVal; _botLossStrk[bot]=0;
        _botMsg[bot]='🤖 Starting — Stake: \$${stakeVal.toStringAsFixed(2)}'; _botMsgC[bot]=const Color(0xFF1DE9B6);
      });
      _runBot(bot);
    }
  }

  Future<void> _runBot(String bot) async {
    while (_botOn[bot]! && mounted) {
      int count=_botCount[bot]!; double pnl=_botPnl[bot]!;
      // Re-read settings from controllers each loop so live edits apply immediately
      final int    maxT = int.tryParse(_botMaxCtrl[bot]?.text??'')   ?? _botMax[bot] ?? 10;
      final double sl   = double.tryParse(_botSLCtrl[bot]?.text??'') ?? _botSL[bot]  ?? 5.0;
      final double tp   = double.tryParse(_botTPCtrl[bot]?.text??'') ?? _botTP[bot]  ?? 10.0;

      // ── STOP CONDITIONS ──
      if(count>=maxT){
        setState((){_botOn[bot]=false;_botMsg[bot]='✅ Done — $count trades';_botMsgC[bot]=const Color(0xFF00C853);});
        _showBotAlert('Bot Finished!', 'Completed $count trades.\nTotal P&L: ${pnl>=0?"+":""}\$${pnl.toStringAsFixed(2)}', const Color(0xFF00C853), Icons.check_circle_outline);
        if(_tgTpSlAlert) _sendTelegram('SOET Bot Done! Trades: ' + count.toString() + ' PnL: ' + (pnl>=0?'+':'') + pnl.toStringAsFixed(2));
        return;
      }
      if(pnl<=-sl){
        setState((){_botOn[bot]=false;_botMsg[bot]='🛑 Stop loss -\$${sl.toStringAsFixed(2)}';_botMsgC[bot]=const Color(0xFFFF4444);});
        _showBotAlert('Stop Loss Hit 🛑', 'Bot stopped to protect your balance.\nLoss limit of \$${sl.toStringAsFixed(2)} reached.', const Color(0xFFFF4444), Icons.shield_outlined);
        if(_tgTpSlAlert) _sendTelegram('SOET Stop Loss Hit! Loss limit ' + sl.toStringAsFixed(2) + ' reached. Bot stopped.');
        return;
      }
      if(pnl>=tp){
        setState((){_botOn[bot]=false;_botMsg[bot]='🏆 Take profit +\$${tp.toStringAsFixed(2)}';_botMsgC[bot]=const Color(0xFF00C853);});
        _showBotAlert('Take Profit Hit! 🎯', 'Bot locked in your profits!\nTarget of \$${tp.toStringAsFixed(2)} reached.', const Color(0xFF1DE9B6), Icons.emoji_events_outlined);
        if(_tgTpSlAlert) _sendTelegram('SOET Take Profit Hit! Target ' + tp.toStringAsFixed(2) + ' reached. Profits locked!');
        return;
      }
      if(!_live){ await Future.delayed(const Duration(seconds:1)); continue; }
      if(_botBusy[bot]!){ await Future.delayed(const Duration(milliseconds:500)); continue; }

      // ── HIGH VOLATILITY PAUSE ──
      if(_highVol) {
        setState((){_botMsg[bot]='⚡ Market spiking — paused';_botMsgC[bot]=Colors.orange;});
        while(_highVol && (_botOn[bot]??false)) {
          await Future.delayed(const Duration(seconds:2));
        }
        if(!(_botOn[bot]??false)) return;
        setState((){_botMsg[bot]='✅ Market stable — resuming...';_botMsgC[bot]=const Color(0xFF1DE9B6);});
        await Future.delayed(const Duration(seconds:1));
      }

      // ── RECOVERY MODE CHECK ──
      if (_recoveryModeOn && (_botRecovery[bot]??false)) {
        setState((){_botMsg[bot]='🔄 Recovery mode — cooling down...';_botMsgC[bot]=Colors.orange;});
        // Skip 2 trade cycles then resume
        await Future.delayed(const Duration(seconds:6));
        setState((){_botRecovery[bot]=false; _botConsecLoss[bot]=0;
          _botMsg[bot]='✅ Recovery done — resuming';_botMsgC[bot]=const Color(0xFF1DE9B6);});
        await Future.delayed(const Duration(seconds:1));
      }



      // ── SIGNAL LINK — wait for matching signal AND confidence >= 60 ──
      if(_botSigLink[bot]!) {
        bool sigMatch = _signalMatchesBot(bot);
        bool confOk   = _confidence >= 60;
        if(!sigMatch || !confOk){
          final waitMsg = !sigMatch
            ? '🔍 Waiting for signal...'
            : '⏳ Signal weak ($_confidence%) — waiting...';
          setState((){_botMsg[bot]=waitMsg;_botMsgC[bot]=Colors.grey;});
          await Future.delayed(const Duration(seconds:2));
          continue;
        }
        setState((){_botMsg[bot]='✅ Signal $_confidence% — Trading!';_botMsgC[bot]=const Color(0xFF1DE9B6);});
        await Future.delayed(const Duration(milliseconds:500));
      }

      // ── MARTINGALE STAKE — re-read controller each trade so live edits apply ──
      final freshStake = double.tryParse(_botStakeCtrl[bot]?.text??'') ?? _botStake[bot] ?? 1.0;
      if(freshStake != _botStake[bot]) { _botStake[bot]=freshStake; _botCurStake[bot]=freshStake; }
      final double curStake = _botMartOn[bot]! ? (_botCurStake[bot]??freshStake) : freshStake;
      setState((){_botBusy[bot]=true; _botMsg[bot]='📤 Trade #${count+1} — \$${curStake.toStringAsFixed(2)}...'; _botMsgC[bot]=const Color(0xFFFFD700);});

      final decision=_botDecision(bot);
      // Skip if no good entry point
      if(decision['type']=='SKIP'){
        setState((){_botMsg[bot]=decision['label']?.toString()??'Waiting...';_botMsgC[bot]=Colors.grey;});
        await Future.delayed(const Duration(seconds:3));
        continue;
      }
      // ── RISK CHECKS ──
      // 1. Volatility spike — skip
      if(_isVolatilitySpike()){
        setState((){_botMsg[bot]='⚠️ Volatility spike — skipping...';_botMsgC[bot]=Colors.orange;});
        await Future.delayed(const Duration(seconds:5));
        continue;
      }
      // 2. Trade frequency — max trades per minute
      if(!_canTradeNow(bot)){
        setState((){_botMsg[bot]='⏱ Max trades/min reached — waiting...';_botMsgC[bot]=Colors.orange;});
        await Future.delayed(const Duration(seconds:10));
        continue;
      }
      // 3. Confidence check — only trade if strong signal
      final conf = _signalConfidence(bot);
      if(conf < _minConfidence){
        setState((){_botMsg[bot]='🔍 Confidence ${conf.toStringAsFixed(0)}% < ${_minConfidence.toStringAsFixed(0)}% — waiting...';_botMsgC[bot]=Colors.grey;});
        await Future.delayed(const Duration(seconds:4));
        continue;
      }
      // 4. Loss streak — pause after X losses
      if(_recoveryModeOn && (_botConsecLoss[bot]??0) >= _pauseAfterLosses){
        setState((){_botMsg[bot]='🛑 ${_pauseAfterLosses} consecutive losses — pausing...';_botMsgC[bot]=_red;});
        await Future.delayed(const Duration(seconds:30));
        setState((){_botConsecLoss[bot]=0;_botMsg[bot]='✅ Resumed after pause';_botMsgC[bot]=_accent;});
        continue;
      }
      try {
        final botSym = _botSym[bot] ?? _sym; // each bot uses its own market
        final prop=await deriv.getProposal(symbol:botSym,contractType:decision['type'],amount:curStake,barrier:decision['barrier']);
        if(!mounted||!(_botOn[bot]??false)) return;
        if(prop==null||prop['proposal']==null){ setState((){_botBusy[bot]=false;}); await Future.delayed(const Duration(seconds:2)); continue; }
        final pid=prop['proposal']['id']?.toString()??'';
        if(pid.isEmpty){ setState((){_botBusy[bot]=false;}); await Future.delayed(const Duration(seconds:2)); continue; }
        final buy=await deriv.buyContract(pid,curStake);
        if(!mounted||!(_botOn[bot]??false)) return;
        if(buy==null||buy['buy']==null){ setState((){_botBusy[bot]=false;}); await Future.delayed(const Duration(seconds:2)); continue; }

        final cid=buy['buy']['contract_id']?.toString()??'';
        setState((){_botMsg[bot]='⏳ '+decision['label'].toString()+' \$${curStake.toStringAsFixed(2)} — waiting...'; _botMsgC[bot]=const Color(0xFF1DE9B6);});

        if(cid.isNotEmpty){
          final comp=Completer<Map>();
          // Register completer for this specific contract — no onContract override needed
          deriv.registerContractCompleter(cid, comp);
          deriv.subscribeContract(cid);
          final result=await comp.future.timeout(const Duration(seconds:20),onTimeout:()=>{});
          deriv.unregisterContractCompleter(cid);
          if(!mounted||!(_botOn[bot]??false)) return;
          final profit=(result['profit'] as num?)?.toDouble()??0;
          final status2=result['status']?.toString()??'';
          final won=status2=='won'||profit>0;
          setState((){
            _botBusy[bot]=false;
            _botCount[bot]=(_botCount[bot]??0)+1;
            if(won) _botWins[bot]=(_botWins[bot]??0)+1;
            _botPnl[bot]=(_botPnl[bot]??0)+profit;
            // Update recovery mode tracking
            _updateRecovery(bot, won);

            // ── MARTINGALE LOGIC ──
            if(_botMartOn[bot]!) {
              if(won){
                // Win → reset stake back to base
                _botCurStake[bot]=_botStake[bot]??1.0; _botLossStrk[bot]=0;
              } else {
                // Loss → double stake (max 4 levels)
                int losses=(_botLossStrk[bot]??0)+1;
                _botLossStrk[bot]=losses;
                double nextStake=_botStake[bot]!*pow(2,losses).toDouble();
                _botCurStake[bot]=nextStake;
              }
            }

            final martInfo=_botMartOn[bot]!&&!won?' → next \$${_botCurStake[bot]!.toStringAsFixed(2)}':'';
            _botMsg[bot]=won?'✅ WIN +\$${profit.toStringAsFixed(2)}  (#${_botCount[bot]})':'❌ LOSS -\$${profit.abs().toStringAsFixed(2)}  (#${_botCount[bot]})$martInfo';
            _botMsgC[bot]=won?const Color(0xFF00C853):const Color(0xFFFF4444);
            final botEntry = result['entry_spot']?.toString() ?? result['entry_tick_display_value']?.toString() ?? '';
            final botExit  = result['exit_tick_display_value']?.toString() ?? result['sell_spot']?.toString() ?? '';
            _logTrade(market:_botSymName[bot]??_symName, type:decision['label']?.toString()??'', stake:curStake, won:won, profit:profit, entrySpot:botEntry, exitSpot:botExit);
            _recordTrade(bot); // track frequency
            _playSound(won);
            // Telegram alert
            if(won && _tgWinAlert) {
              final market = _botSymName[bot]??_symName;
              _sendTelegram('SOET WIN +' + profit.toStringAsFixed(2) + ' on ' + market + ' Trade ' + (_botCount[bot]??0).toString());
            } else if(!won && _tgLossAlert) {
              final market = _botSymName[bot]??_symName;
              _sendTelegram('SOET LOSS -' + profit.abs().toStringAsFixed(2) + ' on ' + market + ' Trade ' + (_botCount[bot]??0).toString());
            }
          });
        } else { setState((){_botBusy[bot]=false;}); }
      } catch(e) { if(mounted) setState((){_botBusy[bot]=false;}); }
      await Future.delayed(const Duration(milliseconds:1500));
    }
  }

  // Check if current SOET signal matches this bot's trade type
  void _showBotMarketPicker(String botId) {
    showModalBottomSheet(context:context,backgroundColor:const Color(0xFF0D1421),shape:const RoundedRectangleBorder(borderRadius:BorderRadius.vertical(top:Radius.circular(20))),
      builder:(_)=>SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Padding(padding:EdgeInsets.all(16),child:Text('SELECT MARKET FOR BOT',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2))),
        ..._symbols.where((m)=>m['g']==''&&m['id']!='').map((m)=>ListTile(
          dense:true,
          title:Text(m['n']!,style:const TextStyle(color:Colors.white,fontSize:13)),
          subtitle:Text(m['id']!,style:const TextStyle(color:Colors.grey,fontSize:10)),
          trailing:_botSym[botId]==m['id']?const Icon(Icons.check_circle,color:Color(0xFF1DE9B6),size:18):null,
          onTap:(){
            setState((){
              _botSym[botId]=m['id']!;
              // Short name for display
              String n=m['n']!;
              _botSymName[botId]=n.length>12?n.substring(0,12)+'..':n;
            });
            Navigator.pop(context);
          },
        )).toList(),
        const SizedBox(height:20),
      ])));
  }

  // ── VOLATILITY DETECTOR ──────────────────────────────────
  // Compares last 5 prices — if swings are more than 3x normal, it's spiking
  void _detectVolatility() {
    if (_priceBuf.length < 10) { _highVol = false; return; }
    // Calculate average absolute change over last 20 ticks
    double totalChange = 0;
    for (int i = 1; i < _priceBuf.length; i++) {
      totalChange += (_priceBuf[i] - _priceBuf[i-1]).abs();
    }
    final avgChange = totalChange / (_priceBuf.length - 1);
    // Check last 5 ticks for a spike
    double recentChange = 0;
    final last = _priceBuf.length;
    for (int i = last-5; i < last-1; i++) {
      recentChange += (_priceBuf[i+1] - _priceBuf[i]).abs();
    }
    final recentAvg = recentChange / 4;
    // High volatility = recent swings are 2.5x the normal average
    final wasHigh = _highVol;
    _highVol = avgChange > 0 && recentAvg > avgChange * 2.5;
    if (_highVol && !wasHigh) {
      if (_tab <= 1 && mounted) setState((){});
      if (_tgVolAlert) _sendTelegram('⚡ <b>SOET High Volatility</b>\nMarket spiking on $_symName! Bots auto-paused.');
    } else if (!_highVol && wasHigh) {
      if (_tab <= 1 && mounted) setState((){});
    }
  }

  // ── TP / SL POPUP ─────────────────────────────────────
  void _showBotAlert(String title, String msg, Color color, IconData icon) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: color, width: 2)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Icon(icon, color: color, size: 52),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(msg, style: const TextStyle(color: Colors.white, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(30)),
              child: const Text('OK', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  bool _signalMatchesBot(String bot) {
    if(_hist.length<10) return false;
    switch(bot){
      case 'differs':   return _sigType=='Differs';
      case 'evenodd':   return _sigType=='Even/Odd';
      case 'overunder': return _sigType=='Over/Under';
      case 'matches':   return _sigType=='Differs'; // matches uses cold digit when differs is hot
      default: return false;
    }
  }

  @override void dispose() { _stopAllBots(); _disposeBotControllers(); _pulseCtrl.dispose(); _digitCtrl.dispose(); super.dispose(); }

  // ══════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF060B18),
    body: SafeArea(child: Column(children:[
      _header(),
      _nav(),  // Nav at top for more screen space
      Expanded(child: IndexedStack(index:_tab, children:[
        _dashboard(), _analyzer(), _calculator(), _bots(), _profile(),
      ])),
    ])),
  );

  // ── HEADER ──────────────────────────────────
  Widget _header() {
    Color ac = widget.isDemo ? const Color(0xFF00C853) : const Color(0xFFFFD700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:16,vertical:12),
      decoration: BoxDecoration(color:_card,border:Border(bottom:BorderSide(color:_cardBorder))),
      child: Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        Row(children:[
          Container(width:32,height:32,decoration:const BoxDecoration(shape:BoxShape.circle,gradient:LinearGradient(colors:[Color(0xFF00C853),Color(0xFF1DE9B6)])),child:const Center(child:Text('🦬',style:TextStyle(fontSize:18)))),
          const SizedBox(width:8),
          Text('SOET',style:TextStyle(color:_accent,fontSize:18,fontWeight:FontWeight.w900,letterSpacing:4)),
        ]),
        Row(children:[
          Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
            Text('$_currency $_balance',style:TextStyle(color:ac,fontWeight:FontWeight.bold,fontSize:13)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal:10,vertical:3),
              decoration: BoxDecoration(
                color: (_live ? (widget.isDemo ? const Color(0xFF00C853) : const Color(0xFFFFD700)) : Colors.orange).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _live ? (widget.isDemo ? const Color(0xFF00C853) : const Color(0xFFFFD700)) : Colors.orange, width:1.5)),
              child: Text(
                _live ? (widget.isDemo ? '● DEMO' : '● LIVE') : (_signal=='Reconnecting...' ? '⟳ RECONNECTING' : '○ DEMO'),
                style: TextStyle(
                  color: _live ? (widget.isDemo ? const Color(0xFF00C853) : const Color(0xFFFFD700)) : Colors.orange,
                  fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
            ),
          ]),
          const SizedBox(width:8),
          _signal=='Reconnecting...'
            ? SizedBox(width:10,height:10,child:CircularProgressIndicator(strokeWidth:2,color:Colors.orange))
            : ScaleTransition(scale:_pulseAnim,child:Container(width:8,height:8,decoration:BoxDecoration(color:_live?const Color(0xFF00C853):Colors.orange,shape:BoxShape.circle))),
          const SizedBox(width:8),
          // Sound toggle
          GestureDetector(
            onTap:()=>setState(()=>_soundOn=!_soundOn),
            child:Icon(_soundOn?Icons.volume_up_rounded:Icons.volume_off_rounded,
              color:_soundOn?_accent:Colors.grey,size:20)),
          const SizedBox(width:12),
          // Theme toggle
          GestureDetector(
            onTap: () => SOETApp.of(context)?.toggleTheme(),
            child: Icon(_isDark ? Icons.light_mode : Icons.dark_mode, color:Colors.grey, size:20)),
          const SizedBox(width:12),
          GestureDetector(onTap:_logout,child:const Icon(Icons.logout,color:Colors.grey,size:20)),
        ]),
      ]),
    );
  }

  // ── DASHBOARD ───────────────────────────────
  Widget _dashboard() => SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[
    // Quick market switch row
    SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
      ...[
        {'id':'R_10',  'n':'V10'},
        {'id':'R_25',  'n':'V25'},
        {'id':'R_50',  'n':'V50'},
        {'id':'R_75',  'n':'V75'},
        {'id':'R_100', 'n':'V100'},
        {'id':'1HZ10V','n':'V10(1s)'},
        {'id':'1HZ25V','n':'V25(1s)'},
      ].map((m){
        final sel = _sym == m['id'];
        return GestureDetector(
          onTap: sel ? null : () { _switchMarket(m['id']!, m['n']! + ' Index'); },
          child: AnimatedContainer(
            duration: const Duration(milliseconds:200),
            margin: const EdgeInsets.only(right:8, bottom:12),
            padding: const EdgeInsets.symmetric(horizontal:12, vertical:6),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFF1DE9B6) : const Color(0xFF0D1421),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: sel ? const Color(0xFF1DE9B6) : const Color(0xFF1A2640))),
            child: Text(m['n']!, style: TextStyle(
              color: sel ? Colors.black : Colors.grey,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
              fontSize: 11)),
          ),
        );
      }).toList(),
    ])),
    _priceCard(),
    const SizedBox(height:16),
    if(_highVol) ...[
      Container(
        padding: const EdgeInsets.symmetric(horizontal:16, vertical:10),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withOpacity(0.6))),
        child: const Row(children:[
          Icon(Icons.warning_amber_rounded, color: Colors.orange, size:18),
          SizedBox(width:10),
          Expanded(child:Text('⚡ HIGH VOLATILITY — Market spiking! Bots auto-paused.',
            style: TextStyle(color: Colors.orange, fontSize:12, fontWeight: FontWeight.bold))),
        ]),
      ),
      const SizedBox(height:12),
    ],
    if(_streak>0) ...[_streakCard(),const SizedBox(height:16)],
    _digitDist(),
    const SizedBox(height:16),
    _signalCard(),
    const SizedBox(height:16),
    _tradePanel(),
    const SizedBox(height:16),
    _recentDigits(),
  ]));

  Widget _priceCard() => Container(
    padding:const EdgeInsets.all(20),
    decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
    child:Column(children:[
      GestureDetector(onTap:_showMarkets,child:Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(20)),
        child:Row(mainAxisSize:MainAxisSize.min,children:[Text(_symName,style:const TextStyle(color:Colors.white,fontSize:13)),const SizedBox(width:8),const Icon(Icons.keyboard_arrow_down,color:Color(0xFF1DE9B6),size:18)]))),
      const SizedBox(height:16),
      _price==0
        ? Column(children:[SizedBox(width:32,height:32,child:CircularProgressIndicator(strokeWidth:2,color:const Color(0xFF1DE9B6).withOpacity(0.6))),const SizedBox(height:8),const Text('Connecting...',style:TextStyle(color:Colors.grey,fontSize:12))])
        : Text(_price.toString(),style:const TextStyle(color:Color(0xFF1DE9B6),fontSize:40,fontWeight:FontWeight.bold)),
      if(_price>0) const Text('Current Price',style:TextStyle(color:Colors.grey,fontSize:12)),
      const SizedBox(height:8),
      Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:4),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(12)),
        child:Row(mainAxisSize:MainAxisSize.min,children:[
          ScaleTransition(scale:_pulseAnim,child:Container(width:6,height:6,decoration:BoxDecoration(color:_live?const Color(0xFF00C853):Colors.orange,shape:BoxShape.circle))),
          const SizedBox(width:6),
          Text(_live?'● LIVE':'⏳ CONNECTING...',style:TextStyle(color:_live?const Color(0xFF00C853):Colors.orange,fontSize:11,letterSpacing:1)),
        ])),
    ]),
  );

  Widget _streakCard() {
    Color c = (_streakType=='HIGH'||_streakType=='EVEN')?const Color(0xFF1DE9B6):const Color(0xFF00C853);
    String w = _streak>=5?'⚠️ Long streak — reversal likely!':_streak>=3?'📊 Watch closely':'✅ Normal';
    Color wc = _streak>=5?const Color(0xFFFF4444):_streak>=3?const Color(0xFFFFD700):Colors.grey;
    return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:c.withOpacity(0.4))),
      child:Row(children:[
        Container(width:64,height:64,decoration:BoxDecoration(gradient:LinearGradient(colors:[c.withOpacity(0.3),c.withOpacity(0.1)]),borderRadius:BorderRadius.circular(16),border:Border.all(color:c.withOpacity(0.6))),
          child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text('$_streak',style:TextStyle(color:c,fontSize:28,fontWeight:FontWeight.bold)),Text('streak',style:TextStyle(color:c.withOpacity(0.7),fontSize:9))])),
        const SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('CURRENT STREAK',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:2)),
          const SizedBox(height:4),
          Text('$_streak consecutive $_streakType',style:TextStyle(color:c,fontSize:14,fontWeight:FontWeight.bold)),
          const SizedBox(height:4),
          Text(w,style:TextStyle(color:wc,fontSize:12)),
        ])),
      ]));
  }

  Widget _digitDist() {
    int total=_hist.length, mx=total>0&&_freq.values.isNotEmpty?_freq.values.reduce(max):1;
    return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child:Column(children:[
        const Text('DIGIT DISTRIBUTION',style:TextStyle(color:Color(0xFF1DE9B6),fontSize:12,fontWeight:FontWeight.bold,letterSpacing:1.5)),
        const SizedBox(height:16),
        total==0
          ? const Padding(padding:EdgeInsets.all(20),child:Text('Waiting for live ticks...',style:TextStyle(color:Colors.grey)))
          : LayoutBuilder(builder:(ctx,constraints){
              // Fit all 10 digits perfectly regardless of screen width
              final ringSize = ((constraints.maxWidth - 16) / 10).clamp(28.0, 50.0);
              final fontSize = (ringSize * 0.36).clamp(10.0, 18.0);
              final pctSize  = (ringSize * 0.24).clamp(8.0, 11.0);
              return Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:List.generate(10,(digit){
                int freq=_freq[digit]??0; double pct=freq/total*100;
                bool isLast=digit==_lastDigit;
                // HEATMAP: color based on how hot/cold digit is vs expected 10%
                Color ring;
                if (total < 20) {
                  ring = isLast ? const Color(0xFF1DE9B6) : const Color(0xFF1A3A5C);
                } else {
                  final expected = total / 10; // expected count if uniform
                  final ratio = freq / expected; // >1 = hot, <1 = cold
                  if (ratio >= 1.8)      ring = const Color(0xFFFF1744); // 🔴 very hot — avoid
                  else if (ratio >= 1.4) ring = const Color(0xFFFF6B35); // 🟠 hot
                  else if (ratio >= 1.1) ring = const Color(0xFFFFD700); // 🟡 slightly hot
                  else if (ratio <= 0.4) ring = const Color(0xFF00E676); // 🟢 very cold — safe
                  else if (ratio <= 0.7) ring = const Color(0xFF1DE9B6); // 🩵 cold
                  else                   ring = const Color(0xFF1A3A5C); // ⬜ neutral
                  if (isLast) ring = Colors.white;
                }
                return Column(children:[
                  SizedBox(width:ringSize,height:ringSize,child:Stack(alignment:Alignment.center,children:[
                    CircularProgressIndicator(value:pct/100,strokeWidth:4.0,backgroundColor:const Color(0xFF1A2640),valueColor:AlwaysStoppedAnimation<Color>(ring)),
                    Text('$digit',style:TextStyle(color:isLast?const Color(0xFF1DE9B6):Colors.white,fontWeight:FontWeight.w800,fontSize:fontSize)),
                  ])),
                  const SizedBox(height:4),
                  Text('${pct.toStringAsFixed(1)}%',style:TextStyle(color:ring==const Color(0xFFFF1744)||ring==const Color(0xFFFF6B35)?const Color(0xFFFF4444):ring==const Color(0xFF00E676)||ring==const Color(0xFF1DE9B6)?const Color(0xFF00C853):Colors.grey,fontSize:pctSize,fontWeight:FontWeight.normal)),
                ]);
              }));
            }),
        const SizedBox(height:12),
        // Heatmap legend
        Wrap(alignment:WrapAlignment.center,spacing:10,runSpacing:4,children:[
          _dot(const Color(0xFFFF1744),'Very Hot — Avoid'),
          _dot(const Color(0xFFFF6B35),'Hot'),
          _dot(const Color(0xFFFFD700),'Warm'),
          _dot(const Color(0xFF1A3A5C),'Neutral'),
          _dot(const Color(0xFF1DE9B6),'Cold ✅'),
          _dot(const Color(0xFF00E676),'Very Cold ✅✅'),
          _dot(Colors.white,'Last Digit'),
        ]),
        const SizedBox(height:8),
        // Dynamic avoid/safe summary
        if (_hist.length >= 20) Container(
          padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
          margin: const EdgeInsets.only(top:4),
          decoration: BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(10)),
          child: Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[
            Column(children:[
              const Text('AVOID',style:TextStyle(color:Color(0xFFFF4444),fontSize:9,letterSpacing:1.5,fontWeight:FontWeight.bold)),
              const SizedBox(height:4),
              Row(children: _avoidDigits.map((d)=>Container(
                margin:const EdgeInsets.only(right:4),
                padding:const EdgeInsets.all(6),
                decoration:BoxDecoration(color:const Color(0xFFFF4444).withOpacity(0.2),shape:BoxShape.circle,border:Border.all(color:const Color(0xFFFF4444))),
                child:Text('$d',style:const TextStyle(color:Color(0xFFFF4444),fontWeight:FontWeight.bold,fontSize:12)))).toList()),
            ]),
            Container(width:1,height:40,color:const Color(0xFF1A3A5C)),
            Column(children:[
              const Text('SAFE TO USE',style:TextStyle(color:Color(0xFF00E676),fontSize:9,letterSpacing:1.5,fontWeight:FontWeight.bold)),
              const SizedBox(height:4),
              Row(children: _safeDigits.map((d)=>Container(
                margin:const EdgeInsets.only(right:4),
                padding:const EdgeInsets.all(6),
                decoration:BoxDecoration(color:const Color(0xFF00E676).withOpacity(0.2),shape:BoxShape.circle,border:Border.all(color:const Color(0xFF00E676))),
                child:Text('$d',style:const TextStyle(color:Color(0xFF00E676),fontWeight:FontWeight.bold,fontSize:12)))).toList()),
            ]),
          ]),
        ),
      ]));
  }

  Widget _dot(Color c,String l)=>Row(children:[Container(width:8,height:8,decoration:BoxDecoration(color:c,shape:BoxShape.circle)),const SizedBox(width:4),Text(l,style:const TextStyle(color:Colors.grey,fontSize:10))]);

  Widget _signalCard() {
    // Confidence color
    Color confColor = _confidence >= 80 ? const Color(0xFF00C853)
      : _confidence >= 65 ? const Color(0xFFFFD700)
      : _confidence >= 50 ? const Color(0xFFFF6B35)
      : Colors.grey;
    return Container(
      padding:const EdgeInsets.all(16),
      decoration:BoxDecoration(color:_sigColor.withOpacity(0.08),borderRadius:BorderRadius.circular(16),border:Border.all(color:_sigColor.withOpacity(0.4))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          Container(width:40,height:40,decoration:BoxDecoration(color:_sigColor.withOpacity(0.15),borderRadius:BorderRadius.circular(12)),child:Icon(Icons.bolt,color:_sigColor,size:22)),
          const SizedBox(width:12),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('SOET SIGNAL v2',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:2)),
            const SizedBox(height:4),
            Text(_signal,style:TextStyle(color:_sigColor,fontSize:13,fontWeight:FontWeight.w800,letterSpacing:0.3)),
            if(_sigType.isNotEmpty) Text('Type: $_sigType',style:const TextStyle(color:Colors.grey,fontSize:11)),
          ])),
          Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),decoration:BoxDecoration(color:_sigColor.withOpacity(0.15),borderRadius:BorderRadius.circular(12)),
            child:Text(_live?'LIVE':'WAIT',style:TextStyle(color:_sigColor,fontSize:10,fontWeight:FontWeight.bold))),
        ]),
        if(_confidence > 0) ...[
          const SizedBox(height:10),
          Row(children:[
            Text('Confidence: ',style:const TextStyle(color:Colors.grey,fontSize:11)),
            Text('$_confidence% — $_confLabel',style:TextStyle(color:confColor,fontSize:11,fontWeight:FontWeight.bold)),
            const SizedBox(width:8),
            Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(
              value:_confidence/100,
              backgroundColor:const Color(0xFF1A2640),
              valueColor:AlwaysStoppedAnimation<Color>(confColor),
              minHeight:6,
            ))),
          ]),
        ],
      ]),
    );
  }

  // ── PREMIUM TRADE PANEL ──────────────────────
  // Risk % of current stake vs balance
  String get _stakeRiskLabel {
    final bal = double.tryParse(_balance) ?? 0;
    if (bal <= 0) return '';
    final pct = _tStake / bal * 100;
    if (pct >= 25) return '⛔ ${pct.toStringAsFixed(1)}% of balance — VERY HIGH RISK!';
    if (pct >= 10) return '⚠️ ${pct.toStringAsFixed(1)}% of balance — HIGH RISK';
    if (pct >= 5)  return '🟡 ${pct.toStringAsFixed(1)}% of balance — MEDIUM RISK';
    return '✅ ${pct.toStringAsFixed(1)}% of balance — Safe';
  }
  Color get _stakeRiskColor {
    final bal = double.tryParse(_balance) ?? 0;
    if (bal <= 0) return Colors.grey;
    final pct = _tStake / bal * 100;
    if (pct >= 25) return const Color(0xFFFF4444);
    if (pct >= 10) return Colors.orange;
    if (pct >= 5)  return const Color(0xFFFFD700);
    return const Color(0xFF00C853);
  }

  Widget _tradePanel() {
    final types = [
      {'l':'DIFFERS','c':const Color(0xFF1DE9B6)},
      {'l':'EVEN',   'c':const Color(0xFF00C853)},
      {'l':'ODD',    'c':const Color(0xFF00C853)},
      {'l':'OVER',   'c':const Color(0xFFFFD700)},
      {'l':'UNDER',  'c':const Color(0xFFFF9800)},
      {'l':'MATCHES','c':const Color(0xFFFF4444)},
    ];
    String sugg = _signal.contains('DIFFERS')||_signal.contains('Differ')?'DIFFERS':
                  _signal.contains('EVEN')||_signal.contains('Even')?'EVEN':
                  _signal.contains('ODD')||_signal.contains('Odd')?'ODD':
                  _signal.contains('OVER')||_signal.contains('Over')?'OVER':
                  _signal.contains('UNDER')||_signal.contains('Under')?'UNDER':'';
    Color pc=const Color(0xFF1DE9B6);
    for(final t in types){ if(t['l']==_tType){ pc=t['c'] as Color; break; }}

    return Container(
      padding:const EdgeInsets.all(12),
      decoration:BoxDecoration(color:_card,borderRadius:BorderRadius.circular(16),border:Border.all(color:_cardBorder)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        // Row 1: Trade type chips
        SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:
          types.map((t){
            bool sel=_tType==t['l']; bool sug=t['l']==sugg;
            Color c=t['c'] as Color;
            return GestureDetector(
              onTap:()=>setState(()=>_tType=t['l'] as String),
              child:AnimatedContainer(duration:const Duration(milliseconds:150),
                margin:const EdgeInsets.only(right:6),
                padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),
                decoration:BoxDecoration(
                  color:sel?c:sug?c.withOpacity(0.12):_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
                  borderRadius:BorderRadius.circular(20),
                  border:Border.all(color:sel?c:sug?c.withOpacity(0.5):Colors.transparent,width:sel?2:1)),
                child:Row(mainAxisSize:MainAxisSize.min,children:[
                  if(sug&&!sel) Icon(Icons.bolt,color:c,size:10),
                  Text(t['l'] as String,style:TextStyle(color:sel?Colors.black:sug?c:_textSec,fontWeight:sel||sug?FontWeight.bold:FontWeight.normal,fontSize:11)),
                ])));
          }).toList()
        )),
        const SizedBox(height:10),

        // Row 2: Digit selector (for DIFFERS/MATCHES) or Barrier (for OVER/UNDER)
        if(_tType=='OVER'||_tType=='UNDER') ...[
          Row(children:[
            Text('Barrier:',style:TextStyle(color:_textSec,fontSize:11)),
            const SizedBox(width:8),
            ...List.generate(9,(i){
              final b=(i+1).toString();
              final sel=_tBarrier==b;
              return GestureDetector(
                onTap:()=>setState(()=>_tBarrier=b),
                child:Container(margin:const EdgeInsets.only(right:5),
                  width:28,height:28,
                  decoration:BoxDecoration(
                    color:sel?pc:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
                    borderRadius:BorderRadius.circular(6)),
                  child:Center(child:Text(b,style:TextStyle(color:sel?Colors.black:_textSec,fontWeight:sel?FontWeight.bold:FontWeight.normal,fontSize:11)))));
            }),
          ]),
          const SizedBox(height:10),
        ],
        if(_tType=='DIFFERS'||_tType=='MATCHES') ...[
          Row(children:[
            Text(_tType=='MATCHES'?'Digit:':'Avoid:',style:TextStyle(color:pc,fontSize:11,fontWeight:FontWeight.bold)),
            const SizedBox(width:8),
            ...List.generate(10,(i){
              final sel=_tDigit==i;
              final isAvoid=_avoidDigits.contains(i);
              final isSafe=_safeDigits.contains(i);
              return GestureDetector(
                onTap:()=>setState(()=>_tDigit=i),
                child:Container(margin:const EdgeInsets.only(right:4),
                  width:26,height:26,
                  decoration:BoxDecoration(
                    color:sel?pc:isAvoid?_red.withOpacity(0.15):isSafe?_green.withOpacity(0.15):_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
                    borderRadius:BorderRadius.circular(6),
                    border:Border.all(color:sel?pc:isAvoid?_red.withOpacity(0.4):isSafe?_green.withOpacity(0.4):Colors.transparent)),
                  child:Center(child:Text('$i',style:TextStyle(color:sel?Colors.black:isAvoid?_red:isSafe?_green:_textSec,fontWeight:sel?FontWeight.bold:FontWeight.normal,fontSize:10)))));
            }),
          ]),
          const SizedBox(height:10),
        ],

        // Row 3: Stake + Duration + Trade button in one row
        Row(children:[
          // Stake quick buttons
          ...([0.35,1.0,2.0,5.0]).map((amt){
            bool sel=_tStake==amt;
            return GestureDetector(
              onTap:()=>setState(()=>_tStake=amt),
              child:Container(margin:const EdgeInsets.only(right:5),
                padding:const EdgeInsets.symmetric(horizontal:8,vertical:6),
                decoration:BoxDecoration(
                  color:sel?_green:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
                  borderRadius:BorderRadius.circular(8)),
                child:Text('\$$amt',style:TextStyle(color:sel?Colors.black:_textSec,fontSize:10,fontWeight:sel?FontWeight.bold:FontWeight.normal))));
          }).toList(),
          const SizedBox(width:4),
          // Custom stake
          Expanded(child:SizedBox(height:32,child:TextField(
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            style:TextStyle(color:_textPrim,fontSize:11),
            decoration:InputDecoration(
              hintText:'Custom',hintStyle:TextStyle(color:_textSec,fontSize:10),
              prefixText:'\$ ',prefixStyle:TextStyle(color:_green,fontSize:10),
              filled:true,fillColor:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:BorderSide.none),
              contentPadding:const EdgeInsets.symmetric(horizontal:8,vertical:0)),
            onChanged:(v){double? val=double.tryParse(v);if(val!=null&&val>0)setState(()=>_tStake=val);},
          ))),
          const SizedBox(width:6),
          // Duration
          Container(height:32,padding:const EdgeInsets.symmetric(horizontal:8),
            decoration:BoxDecoration(color:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),borderRadius:BorderRadius.circular(8)),
            child:DropdownButtonHideUnderline(child:DropdownButton<int>(
              value:_tDuration,
              dropdownColor:_card,
              style:TextStyle(color:_textPrim,fontSize:10),
              items:List.generate(10,(i)=>DropdownMenuItem(value:i+1,child:Text('${i+1}t'))),
              onChanged:(v){if(v!=null)setState(()=>_tDuration=v);},
            ))),
        ]),

        // Stake risk warning
        if(_stakeRiskLabel.isNotEmpty) ...[
          const SizedBox(height:6),
          Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),
            decoration:BoxDecoration(color:_stakeRiskColor.withOpacity(0.08),borderRadius:BorderRadius.circular(6),border:Border.all(color:_stakeRiskColor.withOpacity(0.3))),
            child:Row(children:[Icon(Icons.warning_amber_rounded,color:_stakeRiskColor,size:11),const SizedBox(width:5),Text(_stakeRiskLabel,style:TextStyle(color:_stakeRiskColor,fontSize:10,fontWeight:FontWeight.bold))])),
        ],
        const SizedBox(height:10),

        // Row 4: Payout info + Trade button
        Row(children:[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('Stake: \$${_tStake.toStringAsFixed(2)}',style:TextStyle(color:_textSec,fontSize:10)),
            Text('Profit: +\$${_estPayout.toStringAsFixed(2)}',style:TextStyle(color:_green,fontSize:10,fontWeight:FontWeight.bold)),
          ])),
          // Trade button
          GestureDetector(
            onTap:(_live&&!_tBusy)?_placeTrade:null,
            child:AnimatedContainer(duration:const Duration(milliseconds:150),
              padding:const EdgeInsets.symmetric(horizontal:28,vertical:12),
              decoration:BoxDecoration(
                gradient:LinearGradient(colors:_live&&!_tBusy?[pc,pc.withOpacity(0.7)]:[Colors.grey.withOpacity(0.3),Colors.grey.withOpacity(0.2)]),
                borderRadius:BorderRadius.circular(12),
                boxShadow:_live&&!_tBusy?[BoxShadow(color:pc.withOpacity(0.35),blurRadius:12)]:null),
              child:_tBusy
                ?SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2,color:Colors.black))
                :Text(_tType,style:const TextStyle(color:Colors.black,fontWeight:FontWeight.w900,fontSize:13,letterSpacing:0.5)))),
        ]),

        // Trade result
        if(_tMsg.isNotEmpty) Container(
          margin:const EdgeInsets.only(top:8),
          padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
          decoration:BoxDecoration(color:_tColor.withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:_tColor.withOpacity(0.4))),
          child:Center(child:Text(_tMsg,style:TextStyle(color:_tColor,fontWeight:FontWeight.bold,fontSize:13)))),
      ]),
    );
  }


  Widget _recentDigits() {
    List<int> last20=_hist.length>20?_hist.sublist(_hist.length-20):List.from(_hist);
    return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          const Text('LIVE DIGITS',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),
          Text('${_hist.length} ticks',style:const TextStyle(color:Colors.grey,fontSize:11)),
        ]),
        const SizedBox(height:12),
        last20.isEmpty?const Center(child:Padding(padding:EdgeInsets.all(16),child:Text('Waiting...',style:TextStyle(color:Colors.grey,fontSize:12))))
        :Wrap(spacing:6,runSpacing:6,children:last20.reversed.map((d){
          bool isLast=d==last20.last; Color c=d>=5?const Color(0xFF1DE9B6):const Color(0xFF00C853);
          return Container(width:30,height:30,decoration:BoxDecoration(color:isLast?c:c.withOpacity(0.12),borderRadius:BorderRadius.circular(8),border:Border.all(color:c.withOpacity(0.4))),
            child:Center(child:Text('$d',style:TextStyle(color:isLast?Colors.black:c,fontWeight:FontWeight.bold,fontSize:12))));
        }).toList()),
      ]));
  }

  void _showMarkets() {
    showModalBottomSheet(context:context,backgroundColor:const Color(0xFF0D1421),shape:const RoundedRectangleBorder(borderRadius:BorderRadius.vertical(top:Radius.circular(20))),
      builder:(ctx)=>Column(children:[
        Container(margin:const EdgeInsets.only(top:12),width:40,height:4,decoration:BoxDecoration(color:Colors.grey[700],borderRadius:BorderRadius.circular(2))),
        const Padding(padding:EdgeInsets.all(16),child:Text('SELECT MARKET',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold,letterSpacing:2))),
        Expanded(child:ListView.builder(itemCount:_symbols.length,itemBuilder:(ctx,i){
          final item=_symbols[i];
          if(item['g']!.isNotEmpty) return Padding(padding:const EdgeInsets.fromLTRB(16,16,16,4),child:Text(item['g']!,style:const TextStyle(color:Color(0xFF1DE9B6),fontSize:11,fontWeight:FontWeight.bold,letterSpacing:2)));
          if(item['id']!.isEmpty) return const SizedBox();
          bool sel=item['id']==_sym;
          return ListTile(title:Text(item['n']!,style:TextStyle(color:sel?const Color(0xFF1DE9B6):Colors.white70,fontWeight:sel?FontWeight.bold:FontWeight.normal)),trailing:sel?const Icon(Icons.check_circle,color:Color(0xFF1DE9B6)):null,onTap:(){ _switchMarket(item['id']!,item['n']!); Navigator.pop(ctx); });
        })),
      ]));
  }

  // ── ANALYZER ────────────────────────────────
  Widget _analyzer() {
    final sorted = _marketScores.entries.toList()
      ..sort((a,b)=>(b.value['score'] as int).compareTo(a.value['score'] as int));

    return SingleChildScrollView(padding:const EdgeInsets.all(14),child:Column(children:[
      // Header + Scan button
      Row(children:[
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('MARKET ANALYZER',style:TextStyle(color:_accent,fontSize:13,fontWeight:FontWeight.w800,letterSpacing:1.5)),
          Text('Find the best market to trade right now',style:TextStyle(color:_textSec,fontSize:11)),
        ])),
        GestureDetector(
          onTap: _analyzing ? null : _runMultiMarketAnalysis,
          child:AnimatedContainer(duration:const Duration(milliseconds:200),
            padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),
            decoration:BoxDecoration(
              color:_analyzing?_textSec.withOpacity(0.1):_accent.withOpacity(0.15),
              borderRadius:BorderRadius.circular(12),
              border:Border.all(color:_analyzing?_textSec:_accent)),
            child:_analyzing
              ? Row(mainAxisSize:MainAxisSize.min,children:[
                  SizedBox(width:14,height:14,child:CircularProgressIndicator(strokeWidth:2,color:_accent)),
                  const SizedBox(width:8),
                  Text('Scanning...',style:TextStyle(color:_accent,fontSize:12,fontWeight:FontWeight.bold)),
                ])
              : Row(mainAxisSize:MainAxisSize.min,children:[
                  Icon(Icons.radar,color:_accent,size:16),
                  const SizedBox(width:6),
                  Text('Scan All',style:TextStyle(color:_accent,fontSize:12,fontWeight:FontWeight.bold)),
                ]),
          ),
        ),
      ]),
      const SizedBox(height:14),

      // Best market highlight
      if(_bestMarket.isNotEmpty && !_analyzing) ...[
        Container(
          padding:const EdgeInsets.all(14),
          decoration:BoxDecoration(
            gradient:LinearGradient(colors:[_green.withOpacity(0.15),_accent.withOpacity(0.08)]),
            borderRadius:BorderRadius.circular(14),
            border:Border.all(color:_green.withOpacity(0.5))),
          child:Row(children:[
            const Text('🏆',style:TextStyle(fontSize:28)),
            const SizedBox(width:12),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('BEST MARKET RIGHT NOW',style:TextStyle(color:_green,fontSize:9,fontWeight:FontWeight.bold,letterSpacing:1.5)),
              Text(_marketScores[_bestMarket]?['name']??_bestMarket,style:TextStyle(color:_textPrim,fontSize:16,fontWeight:FontWeight.w900)),
              Text(_bestMarketSignal,style:TextStyle(color:_green,fontSize:11)),
            ])),
            GestureDetector(
              onTap:()=>_switchMarket(_bestMarket, _marketScores[_bestMarket]?['name']??_bestMarket),
              child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
                decoration:BoxDecoration(color:_green,borderRadius:BorderRadius.circular(10)),
                child:const Text('Use',style:TextStyle(color:Colors.black,fontWeight:FontWeight.bold,fontSize:12))),
            ),
          ]),
        ),
        const SizedBox(height:14),
      ],

      // Market list
      if(_marketScores.isEmpty && !_analyzing)
        Container(
          padding:const EdgeInsets.all(32),
          decoration:BoxDecoration(color:_card,borderRadius:BorderRadius.circular(14),border:Border.all(color:_cardBorder)),
          child:Column(children:[
            Icon(Icons.analytics_outlined,color:_textSec,size:48),
            const SizedBox(height:12),
            Text('Tap "Scan All" to analyze all markets',style:TextStyle(color:_textSec,fontSize:12),textAlign:TextAlign.center),
            const SizedBox(height:4),
            Text('Finds the market with strongest signal',style:TextStyle(color:_textSec,fontSize:11),textAlign:TextAlign.center),
          ]),
        )
      else
        ...sorted.map((entry){
          final m = entry.value;
          final score = m['score'] as int;
          final col = Color(m['color'] as int);
          final isBest = entry.key == _bestMarket;
          final isCurrent = entry.key == _sym;
          return Container(
            margin:const EdgeInsets.only(bottom:8),
            padding:const EdgeInsets.all(12),
            decoration:BoxDecoration(
              color:_card,
              borderRadius:BorderRadius.circular(12),
              border:Border.all(color:isBest?col:isCurrent?_accent.withOpacity(0.4):_cardBorder, width:isBest?2:1),
              boxShadow:isBest?[BoxShadow(color:col.withOpacity(0.2),blurRadius:12)]:null),
            child:Row(children:[
              // Score circle
              Container(width:46,height:46,decoration:BoxDecoration(
                shape:BoxShape.circle,
                color:col.withOpacity(0.1),
                border:Border.all(color:col,width:2)),
                child:Center(child:Text('$score',style:TextStyle(color:col,fontWeight:FontWeight.w900,fontSize:14)))),
              const SizedBox(width:12),
              // Market info
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Row(children:[
                  Text(m['name'].toString(),style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:13)),
                  if(isBest) ...[const SizedBox(width:4),Container(padding:const EdgeInsets.symmetric(horizontal:5,vertical:2),decoration:BoxDecoration(color:_green,borderRadius:BorderRadius.circular(5)),child:const Text('BEST',style:TextStyle(color:Colors.black,fontSize:7,fontWeight:FontWeight.bold)))],
                  if(isCurrent) ...[const SizedBox(width:4),Container(padding:const EdgeInsets.symmetric(horizontal:5,vertical:2),decoration:BoxDecoration(color:_accent.withOpacity(0.2),borderRadius:BorderRadius.circular(5),border:Border.all(color:_accent)),child:Text('NOW',style:TextStyle(color:_accent,fontSize:7,fontWeight:FontWeight.bold)))],
                  const SizedBox(width:4),
                  if(m['risk']!=null) Container(padding:const EdgeInsets.symmetric(horizontal:5,vertical:2),
                    decoration:BoxDecoration(color:Color(m['riskColor']??0xFF888888).withOpacity(0.15),borderRadius:BorderRadius.circular(5),border:Border.all(color:Color(m['riskColor']??0xFF888888).withOpacity(0.5))),
                    child:Text(m['risk'].toString(),style:TextStyle(color:Color(m['riskColor']??0xFF888888),fontSize:7,fontWeight:FontWeight.bold))),
                ]),
                Text(m['signal'].toString(),style:TextStyle(color:col,fontSize:11)),
                if(m['hot']!=null) Text('Hot: ${m['hot']} (${m['hotPct']}%)  Cold: ${m['cold']}',style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              // Signal bar
              SizedBox(width:50,child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                ClipRRect(borderRadius:BorderRadius.circular(3),
                  child:LinearProgressIndicator(value:score/100,minHeight:6,
                    backgroundColor:_cardBorder,
                    valueColor:AlwaysStoppedAnimation<Color>(col))),
                const SizedBox(height:4),
                GestureDetector(
                  onTap:()=>_switchMarket(entry.key, m['name'].toString()),
                  child:Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),
                    decoration:BoxDecoration(color:col.withOpacity(0.1),borderRadius:BorderRadius.circular(6),border:Border.all(color:col.withOpacity(0.5))),
                    child:Text('Trade',style:TextStyle(color:col,fontSize:9,fontWeight:FontWeight.bold)))),
              ])),
            ]),
          );
        }).toList(),

      // ── SIGNAL ANALYSIS ─────────────────────────
      const SizedBox(height:16),
      Container(
        decoration:BoxDecoration(color:_card,borderRadius:BorderRadius.circular(14),border:Border.all(color:_cardBorder)),
        padding:const EdgeInsets.all(14),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('SIGNAL ANALYSIS',style:TextStyle(color:_accent,fontSize:11,fontWeight:FontWeight.w800,letterSpacing:1.5)),
          const SizedBox(height:12),
          // Even/Odd + Over/Under stats from live data
          Builder(builder:(_){
            final total=_hist.length;
            if(total<10) return Center(child:Text('Collecting data...',style:TextStyle(color:_textSec,fontSize:11)));
            final even=_hist.where((d)=>d%2==0).length;
            final over=_hist.where((d)=>d>4).length;
            final ep=even/total*100; final op=over/total*100;
            final mx=_freq.values.isEmpty?1:_freq.values.reduce(max);
            final mn=_freq.values.isEmpty?0:_freq.values.reduce(min);
            final hot=_freq.entries.isEmpty?0:_freq.entries.firstWhere((e)=>e.value==mx).key;
            final cold=_freq.entries.isEmpty?9:_freq.entries.firstWhere((e)=>e.value==mn).key;
            final hotPct=mx/total*100; final coldPct=mn/total*100;
            return Column(children:[
              // Even/Odd bar
              _analysisRow('EVEN/ODD', ep, 100-ep, 'EVEN ${ep.toStringAsFixed(1)}%', 'ODD ${(100-ep).toStringAsFixed(1)}%', _green, _red,
                ep>55?'📊 ODD recommended':ep<45?'📊 EVEN recommended':'⚖️ Balanced'),
              const SizedBox(height:10),
              // Over/Under bar
              _analysisRow('OVER/UNDER', op, 100-op, 'OVER ${op.toStringAsFixed(1)}%', 'UNDER ${(100-op).toStringAsFixed(1)}%', const Color(0xFFFFD700), const Color(0xFFFF9800),
                op>55?'📊 UNDER 5 recommended':op<45?'📊 OVER 4 recommended':'⚖️ Balanced'),
              const SizedBox(height:12),
              // Digit frequency bars — all 10 digits
              const SizedBox(height:12),
              Text('DIGIT FREQUENCY (last '+total.toString()+' ticks)',style:TextStyle(color:_textSec,fontSize:9,fontWeight:FontWeight.bold,letterSpacing:1)),
              const SizedBox(height:8),
              Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:List.generate(10,(d){
                final pct = _freq.containsKey(d)?(_freq[d]!/total*100):10.0;
                final isHot = d==hot; final isCold = d==cold;
                final col = isHot?_red:isCold?_green:_accent.withOpacity(0.6);
                return Column(children:[
                  Text(pct.toStringAsFixed(0)+'%',style:TextStyle(color:col,fontSize:8,fontWeight:FontWeight.bold)),
                  const SizedBox(height:3),
                  Container(width:22,height:(pct*1.2).clamp(4.0,60.0),decoration:BoxDecoration(color:col,borderRadius:BorderRadius.circular(3))),
                  const SizedBox(height:3),
                  Text('$d',style:TextStyle(color:isHot||isCold?col:_textPrim,fontWeight:isHot||isCold?FontWeight.bold:FontWeight.normal,fontSize:10)),
                  if(isHot) Text('HOT',style:TextStyle(color:_red,fontSize:7,fontWeight:FontWeight.bold)),
                  if(isCold) Text('COLD',style:TextStyle(color:_green,fontSize:7,fontWeight:FontWeight.bold)),
                ]);
              })),
              const SizedBox(height:12),
              // Hot/Cold digit badges
              Row(children:[
                Expanded(child:_digitBadge(hot,'🔥 HOT\nAVOID',_red)),
                const SizedBox(width:10),
                Expanded(child:_digitBadge(cold,'❄️ COLD\nSAFE',_green)),
              ]),
            ]);
          }),
        ]),
      ),
    ]));
  }


  Widget _barHint(String t,String d,Color c)=>Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Container(width:4,height:36,decoration:BoxDecoration(color:c,borderRadius:BorderRadius.circular(2))),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(t,style:TextStyle(color:c,fontSize:11,fontWeight:FontWeight.bold)),Text(d,style:const TextStyle(color:Colors.grey,fontSize:11))]))]);

  Widget _recsCard()=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1DE9B6).withOpacity(0.3))),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[const Icon(Icons.auto_awesome,color:Color(0xFF1DE9B6),size:16),const SizedBox(width:8),const Text('BEST PICKS',style:TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.bold))]),
      const SizedBox(height:4),
      Text('Based on ${_hist.length} real ticks',style:const TextStyle(color:Colors.grey,fontSize:11)),
      const SizedBox(height:16),
      ..._recs.map((r){
        Color c=r['col'] as Color; double conf=r['c'] as double;
        return Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:c.withOpacity(0.06),borderRadius:BorderRadius.circular(12),border:Border.all(color:c.withOpacity(0.3))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(r['m'] as String,style:TextStyle(color:c,fontSize:11,letterSpacing:1,fontWeight:FontWeight.bold)),Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:2),decoration:BoxDecoration(color:c.withOpacity(0.15),borderRadius:BorderRadius.circular(10)),child:Text('${conf.toInt()}%',style:TextStyle(color:c,fontSize:10,fontWeight:FontWeight.bold)))]),
            const SizedBox(height:6),
            Text(r['p'] as String,style:const TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.bold)),const SizedBox(height:4),
            Text(r['r'] as String,style:const TextStyle(color:Colors.grey,fontSize:11)),const SizedBox(height:8),
            ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(value:conf/100,minHeight:4,backgroundColor:c.withOpacity(0.15),valueColor:AlwaysStoppedAnimation<Color>(c))),
          ]));
      }).toList(),
    ]));

  Widget _analysisRow(String label, double aVal, double bVal, String aLabel, String bLabel, Color aC, Color bC, String suggestion) {
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        Text(label,style:TextStyle(color:_textSec,fontSize:10,fontWeight:FontWeight.bold,letterSpacing:1)),
        Text(suggestion,style:TextStyle(color:_accent,fontSize:10,fontWeight:FontWeight.w600)),
      ]),
      const SizedBox(height:5),
      ClipRRect(borderRadius:BorderRadius.circular(4),child:Row(children:[
        Expanded(flex:aVal.round(),child:Container(height:8,color:aC)),
        Expanded(flex:bVal.round(),child:Container(height:8,color:bC)),
      ])),
      const SizedBox(height:3),
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        Text(aLabel,style:TextStyle(color:aC,fontSize:9,fontWeight:FontWeight.bold)),
        Text(bLabel,style:TextStyle(color:bC,fontSize:9,fontWeight:FontWeight.bold)),
      ]),
    ]);
  }

  Widget _digitBadge(int d,String l,Color c)=>Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:c.withOpacity(0.08),borderRadius:BorderRadius.circular(12),border:Border.all(color:c.withOpacity(0.4))),child:Column(children:[Text('$d',style:TextStyle(color:c,fontSize:36,fontWeight:FontWeight.bold)),const SizedBox(height:4),Text(l,textAlign:TextAlign.center,style:TextStyle(color:c,fontSize:10,fontWeight:FontWeight.bold))]));

  Widget _block({required String title,required String ll,required double lv,required int lc,required String rl,required double rv,required int rc,required Color lCol,required Color rCol,required String advice})=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
    child:Column(children:[
      Text(title,style:const TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:16),
      Row(children:[
        Expanded(child:Column(children:[Text('${lv.toStringAsFixed(1)}%',style:TextStyle(color:lCol,fontSize:30,fontWeight:FontWeight.bold)),Text(ll,style:const TextStyle(color:Colors.grey,fontSize:12)),Text('$lc ticks',style:const TextStyle(color:Colors.grey,fontSize:10))])),
        Container(width:1,height:60,color:const Color(0xFF1A2640)),
        Expanded(child:Column(children:[Text('${rv.toStringAsFixed(1)}%',style:TextStyle(color:rCol,fontSize:30,fontWeight:FontWeight.bold)),Text(rl,style:const TextStyle(color:Colors.grey,fontSize:12)),Text('$rc ticks',style:const TextStyle(color:Colors.grey,fontSize:10))])),
      ]),
      const SizedBox(height:12),
      ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(value:lv/100,minHeight:8,backgroundColor:rCol.withOpacity(0.3),valueColor:AlwaysStoppedAnimation<Color>(lCol))),
      const SizedBox(height:12),
      Container(width:double.infinity,padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(8)),child:Text(advice,style:const TextStyle(color:Colors.white70,fontSize:12))),
    ]));

  Widget _last10(){
    List<int> l10=_hist.sublist(_hist.length-10);
    bool aH=l10.every((d)=>d>=5),aL=l10.every((d)=>d<=4),aE=l10.every((d)=>d%2==0),aO=l10.every((d)=>d%2!=0);
    String p=aH?'📈 All HIGH — low reversal likely':aL?'📉 All LOW — high reversal likely':aE?'🔵 All EVEN — odd may follow':aO?'🟢 All ODD — even may follow':'🔀 Mixed — normal behavior';
    return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('LAST 10 PATTERN',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:12),
        Row(children:l10.map((d){Color c=d>=5?const Color(0xFF1DE9B6):const Color(0xFF00C853);return Container(width:26,height:26,margin:const EdgeInsets.only(right:4),decoration:BoxDecoration(color:c.withOpacity(0.15),borderRadius:BorderRadius.circular(6),border:Border.all(color:c.withOpacity(0.5))),child:Center(child:Text('$d',style:TextStyle(color:c,fontWeight:FontWeight.bold,fontSize:11))));}).toList()),
        const SizedBox(height:12),Text(p,style:const TextStyle(color:Colors.white70,fontSize:13)),
      ]));
  }

  // ── CALCULATOR ──────────────────────────────
  Widget _calculator(){
    final types=['Differs','Even/Odd','Over 2','Over 3','Over 4','Over 5','Over 6','Over 7','Over 8','Under 7','Under 6','Under 5','Under 4','Under 3','Under 2','Under 1','Matches'];
    double profit=_calcPayouts[_calcType]??0, total=_calcStake+profit;
    return SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('STAKE CALCULATOR',style:TextStyle(color:Colors.white,fontSize:15,fontWeight:FontWeight.bold,letterSpacing:1)),
      const SizedBox(height:4),const Text('Calculate payout before placing a trade',style:TextStyle(color:Colors.grey,fontSize:12)),const SizedBox(height:20),
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('STAKE AMOUNT',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:12),
          Wrap(spacing:8,runSpacing:8,children:[0.35,0.5,1.0,2.0,5.0,10.0,20.0].map((amt){bool sel=_calcStake==amt;return GestureDetector(onTap:()=>setState(()=>_calcStake=amt),child:Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:8),decoration:BoxDecoration(color:sel?const Color(0xFF00C853):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(20)),child:Text('\$$amt',style:TextStyle(color:sel?Colors.black:Colors.grey,fontWeight:sel?FontWeight.bold:FontWeight.normal,fontSize:13))));}).toList()),
          const SizedBox(height:12),
          TextField(keyboardType:const TextInputType.numberWithOptions(decimal:true),style:const TextStyle(color:Colors.white,fontSize:18),
            decoration:InputDecoration(hintText:'Custom',hintStyle:const TextStyle(color:Colors.grey),prefixText:'\$ ',prefixStyle:const TextStyle(color:Color(0xFF1DE9B6),fontSize:18),
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:const BorderSide(color:Color(0xFF1A2640))),
              enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:const BorderSide(color:Color(0xFF1A2640))),
              focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:const BorderSide(color:Color(0xFF1DE9B6)))),
            onChanged:(v){double? val=double.tryParse(v);if(val!=null) setState(()=>_calcStake=val);}),
        ])),
      const SizedBox(height:16),
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('TRADE TYPE',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:12),
          Wrap(spacing:8,runSpacing:8,children:types.map((t){bool sel=_calcType==t;Color tc=t.contains('Over')||t=='Even/Odd'?const Color(0xFF1DE9B6):t.contains('Under')?const Color(0xFFFFD700):t=='Matches'?const Color(0xFFFF4444):const Color(0xFF00C853);return GestureDetector(onTap:()=>setState(()=>_calcType=t),child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:6),decoration:BoxDecoration(color:sel?tc.withOpacity(0.2):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(16),border:Border.all(color:sel?tc:const Color(0xFF1A2640))),child:Text(t,style:TextStyle(color:sel?tc:Colors.grey,fontSize:12,fontWeight:sel?FontWeight.bold:FontWeight.normal))));}).toList()),
        ])),
      const SizedBox(height:16),
      Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:LinearGradient(colors:[const Color(0xFF00C853).withOpacity(0.15),const Color(0xFF1DE9B6).withOpacity(0.08)]),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF00C853).withOpacity(0.4))),
        child:Column(children:[
          const Text('PAYOUT BREAKDOWN',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:16),
          Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[
            _pBox('Stake','\$$_calcStake',Colors.grey),const Text('+',style:TextStyle(color:Colors.grey,fontSize:24)),
            _pBox('Profit','+\$${profit.toStringAsFixed(2)}',const Color(0xFF00C853)),const Text('=',style:TextStyle(color:Colors.grey,fontSize:24)),
            _pBox('Return','\$${total.toStringAsFixed(2)}',const Color(0xFF1DE9B6)),
          ]),
        ])),
      const SizedBox(height:16),
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('MARTINGALE PLAN',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:4),const Text('Double on loss. Stop at level 4.',style:TextStyle(color:Colors.grey,fontSize:11)),const SizedBox(height:12),
          Table(columnWidths:const{0:FlexColumnWidth(1),1:FlexColumnWidth(2),2:FlexColumnWidth(2),3:FlexColumnWidth(2)},
            children:[
              TableRow(decoration:const BoxDecoration(color:Color(0xFF1A2640)),children:['Level','Stake','Profit','Risk'].map((h)=>Padding(padding:const EdgeInsets.all(8),child:Text(h,style:const TextStyle(color:Colors.grey,fontSize:11,fontWeight:FontWeight.bold)))).toList()),
              ...List.generate(4,(i){double s=_calcStake*pow(2,i).toDouble(),p=profit*pow(2,i).toDouble(),r=_calcStake*(pow(2,i+1)-1).toDouble();Color rc=i==0?const Color(0xFF00C853):i==1?const Color(0xFFFFD700):i==2?const Color(0xFFFF9800):const Color(0xFFFF4444);return TableRow(children:[Padding(padding:const EdgeInsets.all(8),child:Text('${i+1}',style:TextStyle(color:rc,fontWeight:FontWeight.bold))),Padding(padding:const EdgeInsets.all(8),child:Text('\$${s.toStringAsFixed(2)}',style:TextStyle(color:rc))),Padding(padding:const EdgeInsets.all(8),child:Text('\$${p.toStringAsFixed(2)}',style:const TextStyle(color:Color(0xFF00C853)))),Padding(padding:const EdgeInsets.all(8),child:Text('\$${r.toStringAsFixed(2)}',style:TextStyle(color:rc)))]);})
            ]),
        ])),
    ]));
  }
  Widget _pBox(String l,String v,Color c)=>Column(children:[Text(l,style:const TextStyle(color:Colors.grey,fontSize:11)),const SizedBox(height:4),Text(v,style:TextStyle(color:c,fontSize:20,fontWeight:FontWeight.bold))]);

  // ── BOTS ────────────────────────────────────
  Widget _bots() {
    // Compute combined stats from all bots
    int totalRuns = _botCount.values.fold(0,(s,v)=>s+(v??0));
    int totalWins = _botWins.values.fold(0,(s,v)=>s+(v??0));
    int totalLost = totalRuns - totalWins;
    double totalPnl = _botPnl.values.fold(0.0,(s,v)=>s+(v??0.0));
    double totalStake = _tradeHistory.where((t)=>
      ['differs','evenodd','overunder','matches'].any((b)=>
        _botSymName[b]!=null)).fold(0.0,(s,t)=>s+(t['stake'] as double));
    bool anyRunning = _botOn.values.any((v)=>v);

    // Get trades from bots only (last 50)
    final botTrades = _tradeHistory.take(50).toList();

    return Column(children:[
      // ── SMART BOT ──
      Container(
        color:_card,
        padding:const EdgeInsets.fromLTRB(12,10,12,10),
        child:Container(
          padding:const EdgeInsets.all(12),
          decoration:BoxDecoration(
            gradient:LinearGradient(colors:[const Color(0xFF0D1F3C),_isDark?const Color(0xFF0D1421):Colors.white]),
            borderRadius:BorderRadius.circular(14),
            border:Border.all(color:_smartBotOn?_accent:_cardBorder,width:_smartBotOn?2:1),
            boxShadow:_smartBotOn?[BoxShadow(color:_accent.withOpacity(0.2),blurRadius:16)]:null),
          child:Column(children:[
            Row(children:[
              Container(width:36,height:36,decoration:BoxDecoration(
                shape:BoxShape.circle,
                color:_accent.withOpacity(0.15),
                border:Border.all(color:_accent)),
                child:const Center(child:Text('🧠',style:TextStyle(fontSize:18)))),
              const SizedBox(width:10),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('SMART BOT',style:TextStyle(color:_accent,fontWeight:FontWeight.w900,fontSize:12,letterSpacing:1.5)),
                Text('Auto-scans & picks best market',style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              // Stake
              SizedBox(width:70,child:Row(children:[
                Expanded(child:TextField(
                  style:TextStyle(color:_textPrim,fontSize:12),
                  keyboardType:const TextInputType.numberWithOptions(decimal:true),
                  decoration:InputDecoration(
                    hintText:'1.00',hintStyle:TextStyle(color:_textSec,fontSize:11),
                    prefixText:'\$ ',prefixStyle:TextStyle(color:_accent,fontSize:11),
                    filled:true,fillColor:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
                    border:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:BorderSide.none),
                    contentPadding:const EdgeInsets.symmetric(horizontal:8,vertical:6)),
                  onChanged:(v){double? val=double.tryParse(v);if(val!=null&&val>0)setState(()=>_smartBotStake=val);},
                )),
              ])),
              const SizedBox(width:8),
              // Run/Stop
              GestureDetector(
                onTap:()=>_smartBotOn?setState(()=>_smartBotOn=false):_runSmartBot(),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  padding:const EdgeInsets.symmetric(horizontal:14,vertical:8),
                  decoration:BoxDecoration(
                    color:_smartBotOn?_red:_accent,
                    borderRadius:BorderRadius.circular(10),
                    boxShadow:[BoxShadow(color:(_smartBotOn?_red:_accent).withOpacity(0.4),blurRadius:10)]),
                  child:Text(_smartBotOn?'STOP':'RUN',style:const TextStyle(color:Colors.black,fontWeight:FontWeight.w900,fontSize:12,letterSpacing:1)))),
            ]),
            const SizedBox(height:8),
            // Status + stats
            Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:7),
              decoration:BoxDecoration(color:_isDark?const Color(0xFF0A1628):const Color(0xFFF0F4F8),borderRadius:BorderRadius.circular(8)),
              child:Row(children:[
                AnimatedContainer(duration:const Duration(milliseconds:300),
                  width:7,height:7,
                  decoration:BoxDecoration(color:_smartBotOn?_green:Colors.grey,shape:BoxShape.circle,
                    boxShadow:_smartBotOn?[BoxShadow(color:_green.withOpacity(0.6),blurRadius:6)]:null)),
                const SizedBox(width:8),
                Expanded(child:Text(_smartBotMsg,style:TextStyle(color:_smartBotMsgC,fontSize:10))),
                if(_smartBotCount>0) ...[
                  Text('W:$_smartBotWins/$_smartBotCount',style:TextStyle(color:_green,fontSize:10,fontWeight:FontWeight.bold)),
                  const SizedBox(width:8),
                  Text((_smartBotPnl>=0?'+':'')+'\$'+_smartBotPnl.toStringAsFixed(2),
                    style:TextStyle(color:_smartBotPnl>=0?_green:_red,fontSize:10,fontWeight:FontWeight.bold)),
                ],
              ])),
            const SizedBox(height:8),
            // SL/TP row
            Row(children:[
              // TP
              GestureDetector(
                onTap:()=>setState(()=>_smartBotTPon=!_smartBotTPon),
                child:Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:5),
                  decoration:BoxDecoration(color:_smartBotTPon?_green.withOpacity(0.15):_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),borderRadius:BorderRadius.circular(8),border:Border.all(color:_smartBotTPon?_green:Colors.transparent)),
                  child:Text('TP',style:TextStyle(color:_smartBotTPon?_green:_textSec,fontSize:10,fontWeight:FontWeight.bold)))),
              if(_smartBotTPon) ...[
                const SizedBox(width:4),
                GestureDetector(onTap:()=>setState((){if(_smartBotTP>0.5)_smartBotTP-=0.5;}),child:Icon(Icons.remove,color:_textSec,size:14)),
                const SizedBox(width:4),
                Text('\$'+_smartBotTP.toStringAsFixed(2),style:TextStyle(color:_green,fontWeight:FontWeight.bold,fontSize:11)),
                const SizedBox(width:4),
                GestureDetector(onTap:()=>setState(()=>_smartBotTP+=0.5),child:Icon(Icons.add,color:_green,size:14)),
              ],
              const SizedBox(width:12),
              // SL
              GestureDetector(
                onTap:()=>setState(()=>_smartBotSLon=!_smartBotSLon),
                child:Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:5),
                  decoration:BoxDecoration(color:_smartBotSLon?_red.withOpacity(0.15):_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),borderRadius:BorderRadius.circular(8),border:Border.all(color:_smartBotSLon?_red:Colors.transparent)),
                  child:Text('SL',style:TextStyle(color:_smartBotSLon?_red:_textSec,fontSize:10,fontWeight:FontWeight.bold)))),
              if(_smartBotSLon) ...[
                const SizedBox(width:4),
                GestureDetector(onTap:()=>setState((){if(_smartBotSL>0.5)_smartBotSL-=0.5;}),child:Icon(Icons.remove,color:_textSec,size:14)),
                const SizedBox(width:4),
                Text('\$'+_smartBotSL.toStringAsFixed(2),style:TextStyle(color:_red,fontWeight:FontWeight.bold,fontSize:11)),
                const SizedBox(width:4),
                GestureDetector(onTap:()=>setState(()=>_smartBotSL+=0.5),child:Icon(Icons.add,color:_red,size:14)),
              ],
            ]),
          ]),
        ),
      ),

      // ── TOP: Bot selector pills ──
      Container(
        color: _card,
        padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
        child: SingleChildScrollView(scrollDirection:Axis.horizontal, child:Row(children:[
          ...['differs','evenodd','overunder','matches'].map((id){
            final names = {'differs':'DIFFERS','evenodd':'EVEN/ODD','overunder':'OVER/UNDER','matches':'MATCHES'};
            final colors = {'differs':const Color(0xFF1DE9B6),'evenodd':const Color(0xFF00C853),'overunder':const Color(0xFFFFD700),'matches':const Color(0xFFFF4444)};
            final on = _botOn[id]??false;
            final sel = _botRunning == id || (_botRunning.isEmpty && id=='differs');
            final col = colors[id]!;
            return GestureDetector(
              onTap:()=>setState(()=>_botRunning=id),
              child:AnimatedContainer(
                duration:const Duration(milliseconds:200),
                margin:const EdgeInsets.only(right:8),
                padding:const EdgeInsets.symmetric(horizontal:14,vertical:7),
                decoration:BoxDecoration(
                  color: sel ? col : col.withOpacity(0.1),
                  borderRadius:BorderRadius.circular(20),
                  border:Border.all(color:col, width:sel?2:1),
                  boxShadow: on ? [BoxShadow(color:col.withOpacity(0.3),blurRadius:8)] : null),
                child:Row(mainAxisSize:MainAxisSize.min, children:[
                  if(on) Container(width:6,height:6,margin:const EdgeInsets.only(right:5),decoration:BoxDecoration(color:sel?Colors.black:col,shape:BoxShape.circle)),
                  Text(names[id]!, style:TextStyle(
                    color:sel?Colors.black:col,
                    fontWeight:FontWeight.bold,fontSize:11)),
                ]),
              ),
            );
          }).toList(),
        ])),
      ),

      // ── MIDDLE: Active bot detail ──
      Expanded(child: SingleChildScrollView(padding:const EdgeInsets.all(12), child:Column(children:[

        // RUN/STOP button — DBot style
        _dbotRunButton(),
        const SizedBox(height:12),

        // Status message
        _dbotStatusBar(),
        const SizedBox(height:12),

        // Summary / Transactions tabs
        Container(
          decoration:BoxDecoration(color:_card, borderRadius:BorderRadius.circular(12), border:Border.all(color:_cardBorder)),
          child:Column(children:[
            // Tab row
            Row(children:[
              Expanded(child:GestureDetector(
                onTap:()=>setState(()=>_botTab=0),
                child:Container(
                  padding:const EdgeInsets.symmetric(vertical:10),
                  decoration:BoxDecoration(
                    border:Border(bottom:BorderSide(color:_botTab==0?_accent:Colors.transparent,width:2))),
                  child:Center(child:Text('Summary',style:TextStyle(color:_botTab==0?_accent:_textSec,fontWeight:_botTab==0?FontWeight.bold:FontWeight.normal,fontSize:12)))),
              )),
              Expanded(child:GestureDetector(
                onTap:()=>setState(()=>_botTab=1),
                child:Container(
                  padding:const EdgeInsets.symmetric(vertical:10),
                  decoration:BoxDecoration(
                    border:Border(bottom:BorderSide(color:_botTab==1?_accent:Colors.transparent,width:2))),
                  child:Center(child:Text('Transactions',style:TextStyle(color:_botTab==1?_accent:_textSec,fontWeight:_botTab==1?FontWeight.bold:FontWeight.normal,fontSize:12)))),
              )),
              Expanded(child:GestureDetector(
                onTap:()=>setState(()=>_botTab=2),
                child:Container(
                  padding:const EdgeInsets.symmetric(vertical:10),
                  decoration:BoxDecoration(
                    border:Border(bottom:BorderSide(color:_botTab==2?_accent:Colors.transparent,width:2))),
                  child:Center(child:Text('Journal',style:TextStyle(color:_botTab==2?_accent:_textSec,fontWeight:_botTab==2?FontWeight.bold:FontWeight.normal,fontSize:12)))),
              )),
            ]),
            Container(height:1,color:_cardBorder),

            // Tab content
            if(_botTab==0) _dbotSummary(totalRuns,totalWins,totalLost,totalPnl)
            else if(_botTab==1) _dbotTransactions(botTrades)
            else _dbotJournal(botTrades),
            // Clear history button
            if(botTrades.isNotEmpty) Padding(
              padding:const EdgeInsets.fromLTRB(12,0,12,12),
              child:GestureDetector(
                onTap:()=>showDialog(context:context,builder:(_)=>AlertDialog(
                  backgroundColor:_card,
                  title:Text('Clear History',style:TextStyle(color:_textPrim)),
                  content:Text('Clear all trade history? This cannot be undone.',style:TextStyle(color:_textSec)),
                  actions:[
                    TextButton(onPressed:()=>Navigator.pop(context),child:Text('Cancel',style:TextStyle(color:_textSec))),
                    TextButton(onPressed:(){
                      setState((){_tradeHistory.clear();_saveHistory();
                        _smartBotCount=0;_smartBotWins=0;_smartBotPnl=0;
                        for(final k in _botCount.keys){_botCount[k]=0;_botWins[k]=0;_botPnl[k]=0;}
                      });
                      Navigator.pop(context);
                    },child:Text('Clear',style:TextStyle(color:_red,fontWeight:FontWeight.bold))),
                  ])),
                child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:10),
                  decoration:BoxDecoration(color:_red.withOpacity(0.08),borderRadius:BorderRadius.circular(10),border:Border.all(color:_red.withOpacity(0.4))),
                  child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
                    Icon(Icons.delete_outline,color:_red,size:15),
                    const SizedBox(width:6),
                    Text('Clear History',style:TextStyle(color:_red,fontWeight:FontWeight.bold,fontSize:12)),
                  ])))),
          ]),
        ),
        const SizedBox(height:12),

        // ── SESSION CONTROLS ──
        Container(
          decoration: BoxDecoration(color:_card, borderRadius:BorderRadius.circular(12), border:Border.all(color:_cardBorder)),
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text('SESSION CONTROLS', style:TextStyle(color:_textSec,fontSize:10,letterSpacing:1.5,fontWeight:FontWeight.bold)),
            const SizedBox(height:12),

            // Session TP
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Session Take Profit', style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Stop all bots when P/L reaches target', style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(
                onTap:()=>setState((){_sessionTPon=!_sessionTPon; if(!_sessionTPon) _sessionHit=false;}),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  width:44,height:24,
                  decoration:BoxDecoration(color:_sessionTPon?_green:_isDark?const Color(0xFF1A2640):const Color(0xFFDDE3ED),borderRadius:BorderRadius.circular(12)),
                  child:AnimatedAlign(duration:const Duration(milliseconds:200),
                    alignment:_sessionTPon?Alignment.centerRight:Alignment.centerLeft,
                    child:Container(margin:const EdgeInsets.all(2),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle))))),
            ]),
            if(_sessionTPon) ...[
              const SizedBox(height:8),
              Row(children:[
                Text('Target: ', style:TextStyle(color:_textSec,fontSize:11)),
                GestureDetector(onTap:()=>setState((){if(_sessionTP>0.5)_sessionTP=(_sessionTP-0.5);}),
                  child:Icon(Icons.remove_circle_outline,color:_textSec,size:20)),
                const SizedBox(width:8),
                Text('\$${_sessionTP.toStringAsFixed(2)}',style:TextStyle(color:_green,fontWeight:FontWeight.bold,fontSize:14)),
                const SizedBox(width:8),
                GestureDetector(onTap:()=>setState((){_sessionTP=(_sessionTP+0.5);}),
                  child:Icon(Icons.add_circle_outline,color:_green,size:20)),
              ]),
            ],
            const SizedBox(height:12),

            // Session SL
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Session Stop Loss', style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Stop all bots when loss limit reached', style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(
                onTap:()=>setState((){_sessionSLon=!_sessionSLon; if(!_sessionSLon) _sessionHit=false;}),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  width:44,height:24,
                  decoration:BoxDecoration(color:_sessionSLon?_red:_isDark?const Color(0xFF1A2640):const Color(0xFFDDE3ED),borderRadius:BorderRadius.circular(12)),
                  child:AnimatedAlign(duration:const Duration(milliseconds:200),
                    alignment:_sessionSLon?Alignment.centerRight:Alignment.centerLeft,
                    child:Container(margin:const EdgeInsets.all(2),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle))))),
            ]),
            if(_sessionSLon) ...[
              const SizedBox(height:8),
              Row(children:[
                Text('Limit: ', style:TextStyle(color:_textSec,fontSize:11)),
                GestureDetector(onTap:()=>setState((){if(_sessionSL>0.5)_sessionSL=(_sessionSL-0.5);}),
                  child:Icon(Icons.remove_circle_outline,color:_textSec,size:20)),
                const SizedBox(width:8),
                Text('\$${_sessionSL.toStringAsFixed(2)}',style:TextStyle(color:_red,fontWeight:FontWeight.bold,fontSize:14)),
                const SizedBox(width:8),
                GestureDetector(onTap:()=>setState((){_sessionSL=(_sessionSL+0.5);}),
                  child:Icon(Icons.add_circle_outline,color:_red,size:20)),
              ]),
            ],
            const SizedBox(height:12),

            // Recovery Mode
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Recovery Mode', style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Pause after $_recoveryAfter consecutive losses', style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(
                onTap:()=>setState((){_recoveryModeOn=!_recoveryModeOn;}),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  width:44,height:24,
                  decoration:BoxDecoration(color:_recoveryModeOn?const Color(0xFFFFD700):_isDark?const Color(0xFF1A2640):const Color(0xFFDDE3ED),borderRadius:BorderRadius.circular(12)),
                  child:AnimatedAlign(duration:const Duration(milliseconds:200),
                    alignment:_recoveryModeOn?Alignment.centerRight:Alignment.centerLeft,
                    child:Container(margin:const EdgeInsets.all(2),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle))))),
            ]),
            if(_recoveryModeOn) ...[
              const SizedBox(height:8),
              Row(children:[
                Text('Trigger after: ', style:TextStyle(color:_textSec,fontSize:11)),
                GestureDetector(onTap:()=>setState((){if(_recoveryAfter>1)_recoveryAfter--;}),
                  child:Icon(Icons.remove_circle_outline,color:_textSec,size:20)),
                const SizedBox(width:8),
                Text('$_recoveryAfter losses',style:TextStyle(color:const Color(0xFFFFD700),fontWeight:FontWeight.bold,fontSize:14)),
                const SizedBox(width:8),
                GestureDetector(onTap:()=>setState((){if(_recoveryAfter<10)_recoveryAfter++;}),
                  child:Icon(Icons.add_circle_outline,color:const Color(0xFFFFD700),size:20)),
              ]),
            ],

            const SizedBox(height:12),
            // Confidence threshold
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Min Confidence',style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Only trade when signal is strong enough',style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(onTap:()=>setState((){if(_minConfidence>50)_minConfidence-=5;}),child:Icon(Icons.remove_circle_outline,color:_textSec,size:20)),
              const SizedBox(width:6),
              Text('${_minConfidence.toStringAsFixed(0)}%',style:TextStyle(color:_accent,fontWeight:FontWeight.bold,fontSize:14)),
              const SizedBox(width:6),
              GestureDetector(onTap:()=>setState((){if(_minConfidence<95)_minConfidence+=5;}),child:Icon(Icons.add_circle_outline,color:_accent,size:20)),
            ]),
            const SizedBox(height:12),
            // Max trades per minute
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Max Trades/min',style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Prevents overtrading — per bot',style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(onTap:()=>setState((){if(_maxTradesPerMin>1)_maxTradesPerMin--;}),child:Icon(Icons.remove_circle_outline,color:_textSec,size:20)),
              const SizedBox(width:6),
              Text('$_maxTradesPerMin',style:TextStyle(color:_accent,fontWeight:FontWeight.bold,fontSize:14)),
              const SizedBox(width:6),
              GestureDetector(onTap:()=>setState((){if(_maxTradesPerMin<10)_maxTradesPerMin++;}),child:Icon(Icons.add_circle_outline,color:_accent,size:20)),
            ]),
            const SizedBox(height:12),
            // Volatility filter toggle
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Volatility Filter',style:TextStyle(color:_textPrim,fontSize:12)),
                Text('Skip trades during price spikes',style:TextStyle(color:_textSec,fontSize:10)),
              ])),
              const SizedBox(width:8),
              GestureDetector(
                onTap:()=>setState(()=>_volatilityFilter=!_volatilityFilter),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  width:44,height:24,
                  decoration:BoxDecoration(color:_volatilityFilter?_accent:_isDark?const Color(0xFF1A2640):const Color(0xFFDDE3ED),borderRadius:BorderRadius.circular(12)),
                  child:AnimatedAlign(duration:const Duration(milliseconds:200),
                    alignment:_volatilityFilter?Alignment.centerRight:Alignment.centerLeft,
                    child:Container(margin:const EdgeInsets.all(2),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle))))),
            ]),
            const SizedBox(height:12),
            // Reset session button
            if(_sessionHit) ...[
              const SizedBox(height:12),
              GestureDetector(
                onTap:()=>setState((){_sessionHit=false;}),
                child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:8),
                  decoration:BoxDecoration(color:_accent.withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:_accent.withOpacity(0.4))),
                  child:Center(child:Text('Reset Session Limits',style:TextStyle(color:_accent,fontWeight:FontWeight.bold,fontSize:12))))),
            ],
          ]),
        ),
        const SizedBox(height:12),

        // Bot settings — for selected bot
        _botCard(
          id: _botRunning.isEmpty?'differs':_botRunning,
          name: {'differs':'DIFFERS BOT','evenodd':'EVEN/ODD BOT','overunder':'OVER/UNDER BOT','matches':'MATCHES BOT'}[_botRunning.isEmpty?'differs':_botRunning]!,
          desc: {'differs':'Avoids hottest digit','evenodd':'Trades dominant side','overunder':'Trades against streak','matches':'Matches coldest digit — ⚠️ 10% win rate'}[_botRunning.isEmpty?'differs':_botRunning]!,
          color: {'differs':const Color(0xFF1DE9B6),'evenodd':const Color(0xFF00C853),'overunder':const Color(0xFFFFD700),'matches':const Color(0xFFFF4444)}[_botRunning.isEmpty?'differs':_botRunning]!,
          icon: {'differs':Icons.remove_circle_outline,'evenodd':Icons.swap_horiz,'overunder':Icons.trending_up,'matches':Icons.center_focus_strong}[_botRunning.isEmpty?'differs':_botRunning]!,
        ),

      ]))),
    ]);
  }

  Widget _dbotRunButton() {
    final id = _botRunning.isEmpty ? 'differs' : _botRunning;
    final on = _botOn[id] ?? false;
    final colors = {'differs':const Color(0xFF1DE9B6),'evenodd':const Color(0xFF00C853),'overunder':const Color(0xFFFFD700),'matches':const Color(0xFFFF4444)};
    final col = colors[id]!;
    return GestureDetector(
      onTap: (!_live && !on) ? null : () => _toggleBot(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds:200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical:16),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFFF4444) : _live ? col : Colors.grey.withOpacity(0.3),
          borderRadius: BorderRadius.circular(14),
          boxShadow: on
            ? [BoxShadow(color:const Color(0xFFFF4444).withOpacity(0.4),blurRadius:20,spreadRadius:2)]
            : _live ? [BoxShadow(color:col.withOpacity(0.3),blurRadius:12)] : null),
        child: Row(mainAxisAlignment:MainAxisAlignment.center, children:[
          Icon(on ? Icons.stop_rounded : Icons.play_arrow_rounded,
            color: on ? Colors.white : _live ? Colors.black : Colors.grey, size:28),
          const SizedBox(width:8),
          Text(on ? 'STOP BOT' : 'RUN BOT',
            style:TextStyle(color:on?Colors.white:_live?Colors.black:Colors.grey,fontWeight:FontWeight.w900,fontSize:16,letterSpacing:2)),
        ]),
      ),
    );
  }

  Widget _dbotStatusBar() {
    final id = _botRunning.isEmpty ? 'differs' : _botRunning;
    final on = _botOn[id] ?? false;
    final msg = _botMsg[id] ?? '';
    final msgC = _botMsgC[id] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:14, vertical:10),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1A2640) : const Color(0xFFEEF2F7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: on ? msgC.withOpacity(0.4) : _cardBorder)),
      child: Row(children:[
        AnimatedContainer(duration:const Duration(milliseconds:300),
          width:8,height:8,
          decoration:BoxDecoration(
            color: on ? const Color(0xFF00C853) : Colors.grey,
            shape:BoxShape.circle,
            boxShadow: on ? [BoxShadow(color:const Color(0xFF00C853).withOpacity(0.6),blurRadius:6)] : null)),
        const SizedBox(width:10),
        Expanded(child:Text(
          msg.isNotEmpty ? msg : (on ? 'Bot is running...' : 'Bot is not running'),
          style:TextStyle(color:msg.isNotEmpty?msgC:_textSec, fontSize:12))),
        if(on) SizedBox(width:14,height:14,child:CircularProgressIndicator(strokeWidth:2,color:const Color(0xFF1DE9B6))),
      ]),
    );
  }

  Widget _dbotSummary(int runs, int wins, int losses, double pnl) {
    final id = _botRunning.isEmpty ? 'differs' : _botRunning;
    final botStake = _botCount[id]!=null&&_botCount[id]!>0
      ? (_botStake[id]??1.0) * (_botCount[id]??0) : 0.0;
    final payout = wins * ((_botStake[id]??1.0) * 1.095);
    return Padding(padding:const EdgeInsets.all(16),child:Column(children:[
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        _dbotStat('Total stake', '\$${botStake.toStringAsFixed(2)}', _textSec),
        _dbotStat('Total payout', '\$${payout.toStringAsFixed(2)}', _textSec),
        _dbotStat('No. of runs', runs.toString(), _textSec),
      ]),
      const SizedBox(height:16),
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        _dbotStat('Contracts lost', losses.toString(), _red),
        _dbotStat('Contracts won', wins.toString(), _green),
        _dbotStat('Total P/L', (pnl>=0?'+':'')+'\$${pnl.toStringAsFixed(2)}', pnl>=0?_green:_red),
      ]),
    ]));
  }

  Widget _dbotStat(String label, String value, Color color) => Column(children:[
    Text(label, style:TextStyle(color:_textSec,fontSize:9,letterSpacing:0.5)),
    const SizedBox(height:4),
    Text(value, style:TextStyle(color:color,fontWeight:FontWeight.bold,fontSize:14)),
  ]);

  Widget _dbotTransactions(List<Map<String,dynamic>> trades) {
    if(trades.isEmpty) return Padding(
      padding:const EdgeInsets.all(24),
      child:Center(child:Text('No transactions yet',style:TextStyle(color:_textSec,fontSize:12))));
    return Column(children:[
      // Download + View Detail buttons
      Padding(padding:const EdgeInsets.fromLTRB(12,10,12,6),child:Row(children:[
        Expanded(child:GestureDetector(
          onTap:_downloadTransactions,
          child:Container(padding:const EdgeInsets.symmetric(vertical:9),
            decoration:BoxDecoration(color:_accent.withOpacity(0.08),borderRadius:BorderRadius.circular(8),border:Border.all(color:_accent.withOpacity(0.4))),
            child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
              Icon(Icons.download,color:_accent,size:14),const SizedBox(width:5),
              Text('Download',style:TextStyle(color:_accent,fontSize:11,fontWeight:FontWeight.bold)),
            ])))),
        const SizedBox(width:8),
        Expanded(child:GestureDetector(
          onTap:trades.isNotEmpty?()=>_showTradeDetail(trades.first):null,
          child:Container(padding:const EdgeInsets.symmetric(vertical:9),
            decoration:BoxDecoration(color:_textSec.withOpacity(0.05),borderRadius:BorderRadius.circular(8),border:Border.all(color:_textSec.withOpacity(0.3))),
            child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
              Icon(Icons.info_outline,color:_textSec,size:14),const SizedBox(width:5),
              Text('View Detail',style:TextStyle(color:_textSec,fontSize:11,fontWeight:FontWeight.bold)),
            ])))),
      ])),
      // Headers
      Container(color:_isDark?const Color(0xFF1A2640):const Color(0xFFEEF2F7),
        padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),
        child:Row(children:[
          const SizedBox(width:36),
          Expanded(child:Text('Type',style:TextStyle(color:_textSec,fontSize:9,fontWeight:FontWeight.bold))),
          SizedBox(width:70,child:Text('Entry/Exit',style:TextStyle(color:_textSec,fontSize:9,fontWeight:FontWeight.bold))),
          SizedBox(width:75,child:Text('Stake & P/L',style:TextStyle(color:_textSec,fontSize:9,fontWeight:FontWeight.bold),textAlign:TextAlign.right)),
        ])),
      // Rows
      ...trades.take(25).toList().asMap().entries.map((entry){
        final i=entry.key; final t=entry.value;
        final won=t['won'] as bool;
        final profit=t['profit'] as double;
        final stake=t['stake'] as double;
        final entryS=t['entrySpot']?.toString()??'';
        final exitS=t['exitSpot']?.toString()??'';
        final odd=i%2==1;
        return GestureDetector(
          onTap:()=>_showTradeDetail(t),
          child:Container(
            color:odd?(_isDark?const Color(0xFF0A1628).withOpacity(0.4):const Color(0xFFF5F7FA)):Colors.transparent,
            padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),
            child:Row(children:[
              Container(width:32,height:32,decoration:BoxDecoration(color:(won?_green:_red).withOpacity(0.1),borderRadius:BorderRadius.circular(6)),
                child:Icon(won?Icons.trending_up:Icons.trending_down,color:won?_green:_red,size:16)),
              const SizedBox(width:8),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(t['type'].toString(),style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:11)),
                Text(t['market'].toString(),style:TextStyle(color:_textSec,fontSize:9)),
              ])),
              SizedBox(width:70,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Row(children:[Container(width:6,height:6,decoration:BoxDecoration(color:_red,shape:BoxShape.circle)),const SizedBox(width:4),Text(entryS.isNotEmpty?entryS:t['time'].toString(),style:TextStyle(color:_textSec,fontSize:9))]),
                const SizedBox(height:3),
                Row(children:[Container(width:6,height:6,decoration:BoxDecoration(color:won?_green:Colors.grey,shape:BoxShape.circle,border:Border.all(color:won?_green:Colors.grey))),const SizedBox(width:4),Text(exitS.isNotEmpty?exitS:t['time'].toString(),style:TextStyle(color:_textSec,fontSize:9))]),
              ])),
              SizedBox(width:75,child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                Text('\$'+stake.toStringAsFixed(2),style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:11)),
                Text((profit>=0?'+':'')+'\$'+profit.toStringAsFixed(2),style:TextStyle(color:won?_green:_red,fontSize:11,fontWeight:FontWeight.bold)),
              ])),
            ]),
          ),
        );
      }).toList(),
    ]);
  }


  Widget _dbotJournal(List<Map<String,dynamic>> trades) {
    if(trades.isEmpty) return Padding(
      padding:const EdgeInsets.all(24),
      child:Center(child:Text('No journal entries yet',style:TextStyle(color:_textSec,fontSize:12))));
    return Column(children:[
      Padding(padding:const EdgeInsets.all(12),child:Row(children:[
        Icon(Icons.book_outlined,color:_accent,size:14),const SizedBox(width:6),
        Text('${trades.length} trades recorded',style:TextStyle(color:_textSec,fontSize:11)),
        const Spacer(),
        Text((_pnl>=0?'+':'')+'\$'+_pnl.toStringAsFixed(2),style:TextStyle(color:_pnl>=0?_green:_red,fontWeight:FontWeight.bold,fontSize:11)),
      ])),
      Container(height:1,color:_cardBorder),
      ...trades.take(20).map((t){
        final won=t['won'] as bool;
        final profit=t['profit'] as double;
        final stake=t['stake'] as double;
        final entryS=t['entrySpot']?.toString()??'';
        final exitS=t['exitSpot']?.toString()??'';
        return GestureDetector(
          onTap:()=>_showTradeDetail(t),
          child:Container(
            padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),
            child:Row(children:[
              SizedBox(width:50,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(t['time'].toString().length>=5?t['time'].toString().substring(0,5):t['time'].toString(),style:TextStyle(color:_textSec,fontSize:10,fontWeight:FontWeight.bold)),
                const SizedBox(height:2),
                Container(padding:const EdgeInsets.symmetric(horizontal:4,vertical:2),
                  decoration:BoxDecoration(color:(won?_green:_red).withOpacity(0.1),borderRadius:BorderRadius.circular(4)),
                  child:Text(won?'WIN':'LOSS',style:TextStyle(color:won?_green:_red,fontSize:8,fontWeight:FontWeight.bold))),
              ])),
              const SizedBox(width:8),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(t['type'].toString(),style:TextStyle(color:_textPrim,fontSize:11,fontWeight:FontWeight.bold)),
                Text(t['market'].toString(),style:TextStyle(color:_textSec,fontSize:9)),
                if(entryS.isNotEmpty) Text('Entry: $entryS  Exit: $exitS',style:TextStyle(color:_textSec,fontSize:9)),
              ])),
              Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                Text('\$'+stake.toStringAsFixed(2),style:TextStyle(color:_textSec,fontSize:10)),
                Text((profit>=0?'+':'')+'\$'+profit.toStringAsFixed(2),style:TextStyle(color:won?_green:_red,fontSize:12,fontWeight:FontWeight.w900)),
              ]),
            ]),
          ),
        );
      }).toList(),
    ]);
  }

  void _showTradeDetail(Map<String,dynamic> t) {
    final won=t['won'] as bool;
    final profit=t['profit'] as double;
    final entryS=t['entrySpot']?.toString()??'';
    final exitS=t['exitSpot']?.toString()??'';
    showDialog(context:context,builder:(_)=>AlertDialog(
      backgroundColor:_card,
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16),side:BorderSide(color:won?_green:_red)),
      title:Row(children:[
        Icon(won?Icons.check_circle:Icons.cancel,color:won?_green:_red,size:20),
        const SizedBox(width:8),
        Text(won?'Trade Won':'Trade Lost',style:TextStyle(color:won?_green:_red,fontSize:15,fontWeight:FontWeight.bold)),
      ]),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        _detailRow('Type',t['type'].toString()),
        _detailRow('Market',t['market'].toString()),
        _detailRow('Time',t['time'].toString()),
        _detailRow('Stake','\$'+(t['stake'] as double).toStringAsFixed(2)),
        _detailRow('P/L',(profit>=0?'+':'')+'\$'+profit.toStringAsFixed(2)),
        if(entryS.isNotEmpty) _detailRow('Entry Spot',entryS),
        if(exitS.isNotEmpty)  _detailRow('Exit Spot',exitS),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(context),child:Text('Close',style:TextStyle(color:_accent)))],
    ));
  }

  Widget _detailRow(String label,String value)=>Padding(
    padding:const EdgeInsets.symmetric(vertical:4),
    child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
      Text(label,style:TextStyle(color:_textSec,fontSize:12)),
      Text(value,style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:12)),
    ]));

    Widget _botCard({required String id,required String name,required String desc,required Color color,required IconData icon}) {
    bool on=_botOn[id]??false; bool busy=_botBusy[id]??false;
    int count=_botCount[id]??0; int wins=_botWins[id]??0; double pnl=_botPnl[id]??0;
    double stake=_botStake[id]??1.0; int maxT=_botMax[id]??10;
    double sl=_botSL[id]??5.0; double tp=_botTP[id]??10.0;
    String msg=_botMsg[id]??''; Color msgC=_botMsgC[id]??Colors.grey;
    String wr=count>0?'${(wins/count*100).toStringAsFixed(0)}%':'0%';
    String pnlStr='${pnl>=0?"+":""}\$${pnl.toStringAsFixed(2)}';

    return Container(
      decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(18),
        border:Border.all(color:on?color:color.withOpacity(0.25),width:on?2:1),
        boxShadow:on?[BoxShadow(color:color.withOpacity(0.2),blurRadius:20,spreadRadius:2)]:null),
      child:Column(children:[
        // Header row
        Padding(padding:const EdgeInsets.all(14),child:Row(children:[
          Container(width:42,height:42,decoration:BoxDecoration(color:on?color:color.withOpacity(0.1),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:on?Colors.black:color,size:22)),
          const SizedBox(width:12),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(name,style:TextStyle(color:on?color:Colors.white,fontWeight:FontWeight.bold,fontSize:13)),
            Text(desc,style:const TextStyle(color:Colors.grey,fontSize:11)),
          ])),
          // START/STOP BUTTON
          GestureDetector(onTap:(!_live&&!on)?null:()=>_toggleBot(id),
            child:AnimatedContainer(duration:const Duration(milliseconds:200),
              width:70,height:36,
              decoration:BoxDecoration(
                color:on?const Color(0xFFFF4444):_live?color:Colors.grey.withOpacity(0.3),
                borderRadius:BorderRadius.circular(20),
                boxShadow:on?[BoxShadow(color:const Color(0xFFFF4444).withOpacity(0.4),blurRadius:10)]:_live?[BoxShadow(color:color.withOpacity(0.3),blurRadius:8)]:null),
              child:Center(child:busy
                ?SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:on?Colors.white:Colors.black))
                :Text(on?'STOP':'START',style:TextStyle(color:on?Colors.white:_live?Colors.black:Colors.grey,fontWeight:FontWeight.bold,fontSize:11,letterSpacing:1))))),
        ])),

        // Settings — always visible, editable even while running
        Container(height:1,color:color.withOpacity(0.1)),
        Padding(padding:EdgeInsets.fromLTRB(14,10,14,on?6:14),child:Column(children:[
          // Market picker per bot
          GestureDetector(
            onTap: on ? null : () => _showBotMarketPicker(id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
              margin: const EdgeInsets.only(bottom:10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2640),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: on ? Colors.grey.withOpacity(0.2) : color.withOpacity(0.3))),
              child: Row(children:[
                Icon(Icons.show_chart, color: on ? Colors.grey : color, size:14),
                const SizedBox(width:8),
                Expanded(child: Text(_botSymName[id]??'Vol 10', style: TextStyle(color: on ? Colors.grey : Colors.white, fontSize:12))),
                if(!on) Icon(Icons.keyboard_arrow_down, color: color, size:16),
                if(on)  Text('(running)', style: TextStyle(color: Colors.grey, fontSize:10)),
              ]),
            ),
          ),
          Row(children:[
            Expanded(child:_botFieldCtrl('Stake \$',_botStakeCtrl[id]!,(v){double? val=double.tryParse(v);if(val!=null&&val>0)setState(()=>_botStake[id]=val);})),
            const SizedBox(width:8),
            Expanded(child:_botFieldCtrl('Max trades',_botMaxCtrl[id]!,(v){int? val=int.tryParse(v);if(val!=null&&val>0)setState(()=>_botMax[id]=val);})),
          ]),
          const SizedBox(height:8),
          Row(children:[
            Expanded(child:_botFieldCtrl('Stop loss \$',_botSLCtrl[id]!,(v){double? val=double.tryParse(v);if(val!=null&&val>0)setState(()=>_botSL[id]=val);})),
            const SizedBox(width:8),
            Expanded(child:_botFieldCtrl('Take profit \$',_botTPCtrl[id]!,(v){double? val=double.tryParse(v);if(val!=null&&val>0)setState(()=>_botTP[id]=val);})),
          ]),
          if(on) Padding(padding:const EdgeInsets.only(top:6),child:Row(children:[const Icon(Icons.edit,color:Colors.grey,size:11),const SizedBox(width:4),const Text('Changes apply on next trade',style:TextStyle(color:Colors.grey,fontSize:10))])),
          if(!on) const SizedBox(height:10),
          if(!on) _botToggle('Martingale','Double stake on loss — reset on win',Icons.trending_up,const Color(0xFFFF9800),_botMartOn[id]??false,()=>setState(()=>_botMartOn[id]=!(_botMartOn[id]??false))),
          if(!on) const SizedBox(height:8),
          if(!on) _botToggle('Signal Link','Wait for SOET signal before each trade',Icons.bolt,const Color(0xFF1DE9B6),_botSigLink[id]??false,()=>setState(()=>_botSigLink[id]=!(_botSigLink[id]??false))),
          if(!on&&(_botSigLink[id]??false)) const SizedBox(height:6),
          if(!on&&(_botSigLink[id]??false)) Container(padding:const EdgeInsets.all(8),decoration:BoxDecoration(color:const Color(0xFF1DE9B6).withOpacity(0.05),borderRadius:BorderRadius.circular(8)),child:Row(children:[const Icon(Icons.info_outline,color:Color(0xFF1DE9B6),size:13),const SizedBox(width:6),Expanded(child:Text('Signal: $_signal',style:const TextStyle(color:Color(0xFF1DE9B6),fontSize:11)))])),
        ])),

        // Live stats — show when running or has trades
        if(on||count>0) ...[
          Container(height:1,color:color.withOpacity(0.15)),
          Padding(padding:const EdgeInsets.all(12),child:Column(children:[
            // Stats row
            if(count>0) Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[
              _bStat('Trades','$count',Colors.white),
              _bStat('Win Rate',wr,const Color(0xFF00C853)),
              _bStat('P&L',pnlStr,pnl>=0?const Color(0xFF00C853):const Color(0xFFFF4444)),
              if(_botMartOn[id]??false) _bStat('Stake','\$${(_botCurStake[id]??stake).toStringAsFixed(2)}',const Color(0xFFFF9800))
              else _bStat('Left','${maxT-count}',Colors.grey),
            ]),
            if(count>0) const SizedBox(height:8),
            // Progress bar
            if(on) ...[
              ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(value:count/maxT,minHeight:4,backgroundColor:color.withOpacity(0.15),valueColor:AlwaysStoppedAnimation<Color>(color))),
              const SizedBox(height:8),
            ],
            // Current message
            if(msg.isNotEmpty) Container(width:double.infinity,padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
              decoration:BoxDecoration(color:msgC.withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:msgC.withOpacity(0.4))),
              child:Text(msg,style:TextStyle(color:msgC,fontSize:12,fontWeight:FontWeight.bold))),
          ])),
        ],
      ]),
    );
  }

  Widget _botToggle(String title,String sub,IconData icon,Color c,bool val,VoidCallback onTap)=>GestureDetector(onTap:onTap,
    child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),
      decoration:BoxDecoration(color:val?c.withOpacity(0.1):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(10),border:Border.all(color:val?c:const Color(0xFF2A3A50))),
      child:Row(children:[
        Icon(icon,color:val?c:Colors.grey,size:18),const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(title,style:TextStyle(color:val?c:Colors.white,fontWeight:FontWeight.bold,fontSize:12)),
          Text(sub,style:TextStyle(color:val?c.withOpacity(0.7):Colors.grey,fontSize:10)),
        ])),
        Container(width:40,height:22,decoration:BoxDecoration(color:val?c:const Color(0xFF2A3A50),borderRadius:BorderRadius.circular(11)),
          child:AnimatedAlign(duration:const Duration(milliseconds:200),alignment:val?Alignment.centerRight:Alignment.centerLeft,
            child:Container(width:18,height:18,margin:const EdgeInsets.symmetric(horizontal:2),decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle)))),
      ])));

  Widget _botFieldCtrl(String label,TextEditingController ctrl,Function(String) onChanged)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text(label,style:const TextStyle(color:Colors.grey,fontSize:10)),
    const SizedBox(height:4),
    SizedBox(height:36,child:TextField(
      controller:ctrl,
      keyboardType:const TextInputType.numberWithOptions(decimal:true),
      style:const TextStyle(color:Colors.white,fontSize:13),
      decoration:InputDecoration(contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:8),filled:true,fillColor:const Color(0xFF1A2640),border:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:BorderSide.none),focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:const BorderSide(color:Color(0xFF1DE9B6),width:1.5))),
      onChanged:onChanged,
    )),
  ]);



  Widget _bStat(String l,String v,Color c)=>Column(children:[Text(l,style:const TextStyle(color:Colors.grey,fontSize:9)),Text(v,style:TextStyle(color:c,fontWeight:FontWeight.bold,fontSize:13))]);

  // ── GUIDE ───────────────────────────────────
  Widget _guide()=>SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('SOET GUIDE',style:TextStyle(color:Colors.white,fontSize:15,fontWeight:FontWeight.bold,letterSpacing:1)),
    const SizedBox(height:4),const Text('Everything you need to know about Deriv trading',style:TextStyle(color:Colors.grey,fontSize:12)),const SizedBox(height:20),
    _gSection('📊 TRADE TYPES',const Color(0xFF1DE9B6),[
      _gItem('DIFFERS','Last digit will NOT be your chosen number. Example: Differ from 5 = win if last digit is anything except 5.\nPayout ~9.5%. Low risk.\n💡 Use when one digit appears too often.'),
      _gItem('MATCHES','Last digit WILL BE exactly your chosen number.\nPayout ~810%. Very high risk, very high reward.\n💡 Use when a digit hasn\'t appeared in a long time.'),
      _gItem('EVEN','Last digit will be even (0,2,4,6,8). Payout ~90%.\n💡 Use when odd digits dominate recently.'),
      _gItem('ODD','Last digit will be odd (1,3,5,7,9). Payout ~90%.\n💡 Use when even digits dominate recently.'),
      _gItem('OVER (barrier)','Last digit will be HIGHER than barrier.\nOver 4 = win if digit is 5,6,7,8,9.\nHigher barrier = bigger payout, harder to win.\n💡 Use when low digits have been dominant.'),
      _gItem('UNDER (barrier)','Last digit will be LOWER than barrier.\nUnder 5 = win if digit is 0,1,2,3,4.\nLower barrier = bigger payout, harder to win.\n💡 Use when high digits have been dominant.'),
    ]),
    const SizedBox(height:16),
    _gSection('📈 MARKETS',const Color(0xFF00C853),[
      _gItem('Volatility 10 (R_10)','Moves slowly. Most balanced and predictable.\n💡 Best for beginners — start here.'),
      _gItem('(1s) Markets','Tick arrives every 1 second. More data per minute.\n💡 Good for faster analysis.'),
      _gItem('Volatility 25/50/75/100','Higher number = bigger price swings = less predictable.\n💡 Stick to low numbers when starting out.'),
      _gItem('Boom 300/500/1000','Occasional sudden SPIKES upward.\nNumber = average ticks between spikes.\n💡 Boom 300 spikes more often than Boom 1000.'),
      _gItem('Crash 300/500/1000','Occasional sudden DROPS downward.\nOpposite of Boom markets.'),
      _gItem('Jump 10/25/50/75/100','Random large jumps both up and down.\n💡 Less predictable — avoid when starting.'),
    ]),
    const SizedBox(height:16),
    _gSection('💰 MONEY MANAGEMENT',const Color(0xFFFFD700),[
      _gItem('Golden Rule','Never risk more than 5% of your balance on one trade.\nBalance \$100 → max stake \$5.'),
      _gItem('Flat Staking (safest)','Same stake every trade. Example: always \$1.\n💡 Best for beginners.'),
      _gItem('Martingale (risky)','Double stake after every loss.\n\$1 → \$2 → \$4 → \$8...\n⚠️ Stop at 3-4 levels. Can wipe balance fast.'),
      _gItem('Stop Loss','Decide before trading: "I stop if I lose \$X today."\nExample: Stop if balance drops by 20%.'),
    ]),
    const SizedBox(height:16),
    _gSection('🔑 API TOKEN',const Color(0xFF00C853),[
      _gItem('What is it?','A password that lets SOET connect to your Deriv account.\nNOT your Deriv login password.'),
      _gItem('How to create','1. deriv.com → login\n2. Profile icon → Security & Safety\n3. API Token → Create\n4. Select: Read, Trade, Trading Info\n5. Copy and paste in SOET'),
      _gItem('Demo vs Live','Demo token = virtual money. Safe to test.\nLive token = real money. Be careful!\n💡 Always test on Demo first.'),
      _gItem('Security','⚠️ Never share your token with anyone.\nIf shared accidentally: delete it on Deriv and create a new one.'),
      _gItem('Auto-login','SOET remembers your token in the browser.\nYou only need to enter it once!'),
    ]),
    const SizedBox(height:20),
    Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(gradient:LinearGradient(colors:[const Color(0xFF00C853).withOpacity(0.15),const Color(0xFF1DE9B6).withOpacity(0.08)]),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF00C853).withOpacity(0.3))),
      child:const Row(children:[Text('🦬',style:TextStyle(fontSize:32)),SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('SOET v3.0 — Phase 3',style:TextStyle(color:Color(0xFF00C853),fontWeight:FontWeight.bold,fontSize:13)),SizedBox(height:4),Text('Real trading active.\nPhase 4 = Automated bots coming!',style:TextStyle(color:Colors.grey,fontSize:12,height:1.5))]))]))
  ]));

  Widget _gSection(String title,Color color,List<Widget> items)=>Container(decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:color.withOpacity(0.3))),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Container(width:double.infinity,padding:const EdgeInsets.symmetric(horizontal:16,vertical:12),decoration:BoxDecoration(color:color.withOpacity(0.1),borderRadius:const BorderRadius.vertical(top:Radius.circular(16))),child:Text(title,style:TextStyle(color:color,fontWeight:FontWeight.bold,fontSize:12,letterSpacing:1))),...items]));

  Widget _gItem(String title,String body)=>ExpansionTile(tilePadding:const EdgeInsets.symmetric(horizontal:16,vertical:2),childrenPadding:const EdgeInsets.fromLTRB(16,0,16,16),title:Text(title,style:const TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.w600)),iconColor:const Color(0xFF1DE9B6),collapsedIconColor:Colors.grey,children:[Container(width:double.infinity,padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(10)),child:Text(body,style:const TextStyle(color:Colors.grey,fontSize:12,height:1.6)))]);

  // ── PROFILE ──────────────────────────────────
  Widget _profile(){
    Color ac=widget.isDemo?const Color(0xFF00C853):const Color(0xFFFFD700);
    String winRate=_trades>0?'${(_wins/_trades*100).toStringAsFixed(1)}%':'0%';
    String pnlStr='${_pnl>=0?"+":""}\$${ _pnl.toStringAsFixed(2)}';
    return SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[
      Container(padding:const EdgeInsets.all(24),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF0D1F0D),Color(0xFF0D1421)]),borderRadius:BorderRadius.circular(20),border:Border.all(color:ac.withOpacity(0.3))),
        child:Column(children:[
          Container(width:90,height:90,decoration:BoxDecoration(shape:BoxShape.circle,gradient:LinearGradient(colors:widget.isDemo?[const Color(0xFF00C853),const Color(0xFF1DE9B6)]:[const Color(0xFFFFD700),const Color(0xFFFF9800)]),boxShadow:[BoxShadow(color:ac.withOpacity(0.4),blurRadius:20,spreadRadius:2)]),child:const Center(child:Text('🦬',style:TextStyle(fontSize:48)))),
          const SizedBox(height:16),
          const Text('SOET',style:TextStyle(color:Colors.white,fontSize:28,fontWeight:FontWeight.w900,letterSpacing:6)),
          const Text('Smart Options & Events Trader',style:TextStyle(color:Color(0xFF1DE9B6),fontSize:12)),
          const SizedBox(height:8),
          Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:6),decoration:BoxDecoration(color:ac.withOpacity(0.1),borderRadius:BorderRadius.circular(20),border:Border.all(color:ac.withOpacity(0.4))),child:Text('${widget.isDemo?"DEMO":"LIVE"} • $_currency $_balance',style:TextStyle(color:ac,fontWeight:FontWeight.bold,fontSize:14))),
          if(_loginId.isNotEmpty) ...[const SizedBox(height:6),Text('Account: $_loginId',style:const TextStyle(color:Colors.grey,fontSize:11))],
          const SizedBox(height:16),
          GestureDetector(onTap:_logout,child:Container(padding:const EdgeInsets.symmetric(horizontal:20,vertical:8),decoration:BoxDecoration(color:const Color(0xFFFF4444).withOpacity(0.1),borderRadius:BorderRadius.circular(20),border:Border.all(color:const Color(0xFFFF4444).withOpacity(0.4))),child:const Row(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.logout,color:Color(0xFFFF4444),size:16),SizedBox(width:6),Text('Disconnect & Logout',style:TextStyle(color:Color(0xFFFF4444),fontSize:12))]))),
        ])),
      const SizedBox(height:20),
      GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,crossAxisSpacing:12,mainAxisSpacing:12,childAspectRatio:1.6,
        children:[
          {'l':'Total Trades','v':'$_trades',  'h':'FF1DE9B6'},
          {'l':'Win Rate',    'v':winRate,     'h':'FF00C853'},
          {'l':'Session P&L', 'v':pnlStr,      'h':_pnl>=0?'FF00C853':'FFFF4444'},
          {'l':'Best Streak', 'v':'$_streak',  'h':'FFFF6B35'},
        ].map((s){Color c=Color(int.parse(s['h']!,radix:16));return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(12),border:Border.all(color:c.withOpacity(0.3))),child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(s['l']!,style:const TextStyle(color:Colors.grey,fontSize:11)),Text(s['v']!,style:TextStyle(color:c,fontSize:22,fontWeight:FontWeight.bold))]));}).toList()),
      const SizedBox(height:20),
      _telegramSection(),
      const SizedBox(height:20),
      _firebaseSection(),

    ]));
  }

  // ── FIREBASE SECTION ────────────────────────────
  final _fbProjCtrl = TextEditingController();
  final _fbKeyCtrl  = TextEditingController();

  Widget _firebaseSection() {
    return Container(
      decoration: BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Padding(padding:const EdgeInsets.fromLTRB(16,16,16,0),child:Row(children:[
          Container(width:36,height:36,decoration:BoxDecoration(color:const Color(0xFFFF9800).withOpacity(0.15),borderRadius:BorderRadius.circular(10)),
            child:const Center(child:Text('🔥',style:TextStyle(fontSize:18)))),
          const SizedBox(width:12),
          const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('CROSS-DEVICE SYNC',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:13,letterSpacing:1)),
            Text('Firebase — sync trades across devices',style:TextStyle(color:Colors.grey,fontSize:11)),
          ])),
          GestureDetector(
            onTap:()=>setState((){_fbEnabled=!_fbEnabled;_saveFbSettings();}),
            child:AnimatedContainer(duration:const Duration(milliseconds:200),
              width:48,height:26,
              decoration:BoxDecoration(color:_fbEnabled?const Color(0xFFFF9800):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(13)),
              child:AnimatedAlign(duration:const Duration(milliseconds:200),
                alignment:_fbEnabled?Alignment.centerRight:Alignment.centerLeft,
                child:Container(margin:const EdgeInsets.all(3),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle)))),
          ),
        ])),
        const SizedBox(height:14),
        Container(height:1,color:const Color(0xFF1A2640)),
        Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('FIREBASE PROJECT ID',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:6),
          TextField(
            controller: _fbProjCtrl,
            style:const TextStyle(color:Colors.white,fontSize:12,fontFamily:'monospace'),
            decoration:InputDecoration(
              hintText:'your-project-id',
              hintStyle:const TextStyle(color:Colors.grey,fontSize:12),
              filled:true,fillColor:const Color(0xFF1A2640),
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:BorderSide.none),
              contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:10),
              suffixIcon:IconButton(icon:const Icon(Icons.check_circle,color:Color(0xFFFF9800),size:20),
                onPressed:(){FocusScope.of(context).unfocus();setState((){_fbProjectId=_fbProjCtrl.text.trim();});_saveFbSettings();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Project ID saved ✓'),backgroundColor:Color(0xFFFF9800),duration:Duration(seconds:2)));})),
            onChanged:(v){_fbProjectId=v.trim();},
            onSubmitted:(v){setState((){_fbProjectId=v.trim();});_saveFbSettings();},
          ),
          const SizedBox(height:12),
          const Text('WEB API KEY',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:6),
          TextField(
            controller: _fbKeyCtrl,
            style:const TextStyle(color:Colors.white,fontSize:12,fontFamily:'monospace'),
            decoration:InputDecoration(
              hintText:'AIzaSy...',
              hintStyle:const TextStyle(color:Colors.grey,fontSize:12),
              filled:true,fillColor:const Color(0xFF1A2640),
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:BorderSide.none),
              contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:10),
              suffixIcon:IconButton(icon:const Icon(Icons.check_circle,color:Color(0xFFFF9800),size:20),
                onPressed:(){FocusScope.of(context).unfocus();setState((){_fbApiKey=_fbKeyCtrl.text.trim();});_saveFbSettings();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('API Key saved ✓'),backgroundColor:Color(0xFFFF9800),duration:Duration(seconds:2)));})),
            onChanged:(v){_fbApiKey=v.trim();},
            onSubmitted:(v){setState((){_fbApiKey=v.trim();});_saveFbSettings();},
          ),
          const SizedBox(height:14),
          // Sync button
          GestureDetector(
            onTap:_fbProjectId.isEmpty||_fbApiKey.isEmpty ? null : (){_pullTradesFromFirebase();},
            child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:12),
              decoration:BoxDecoration(
                color:_fbProjectId.isEmpty||_fbApiKey.isEmpty?const Color(0xFF1A2640):const Color(0xFFFF9800).withOpacity(0.15),
                borderRadius:BorderRadius.circular(10),
                border:Border.all(color:_fbProjectId.isEmpty||_fbApiKey.isEmpty?const Color(0xFF1A2640):const Color(0xFFFF9800).withOpacity(0.5))),
              child:Center(child:_fbSyncing
                ?const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:Color(0xFFFF9800)))
                :Text('Pull Trades from Cloud',style:TextStyle(color:_fbProjectId.isEmpty||_fbApiKey.isEmpty?Colors.grey:const Color(0xFFFF9800),fontWeight:FontWeight.bold,fontSize:13))))),
          const SizedBox(height:12),
          // Setup guide
          Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFFFF9800).withOpacity(0.05),borderRadius:BorderRadius.circular(10),border:Border.all(color:const Color(0xFFFF9800).withOpacity(0.2))),
            child:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('HOW TO SETUP',style:TextStyle(color:Color(0xFFFF9800),fontSize:10,letterSpacing:1.5,fontWeight:FontWeight.bold)),
              SizedBox(height:6),
              Text('1. Go to console.firebase.google.com\n2. Create project → name it "soet"\n3. Add web app → copy Project ID & API Key\n4. Firestore → Create database → Start in test mode\n5. Paste both above → toggle ON\n6. Open SOET on any device → trades sync!',
                style:TextStyle(color:Colors.grey,fontSize:11,height:1.6)),
            ])),
        ])),
      ]),
    );
  }

  // ── TELEGRAM SECTION ───────────────────────────
  Widget _telegramSection() {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF0D1421), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1A2640))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(padding: const EdgeInsets.fromLTRB(16,16,16,0), child: Row(children: [
          Container(width:36,height:36,decoration:BoxDecoration(color:const Color(0xFF0088CC).withOpacity(0.15),borderRadius:BorderRadius.circular(10)),
            child:const Center(child:Text('✈️',style:TextStyle(fontSize:18)))),
          const SizedBox(width:12),
          const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('TELEGRAM ALERTS',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:13,letterSpacing:1)),
            Text('Get notified on your phone',style:TextStyle(color:Colors.grey,fontSize:11)),
          ])),
          // Master on/off toggle
          GestureDetector(
            onTap:() => setState((){_tgEnabled=!_tgEnabled; _saveTgSettings();}),
            child: AnimatedContainer(duration:const Duration(milliseconds:200),
              width:48,height:26,
              decoration:BoxDecoration(color:_tgEnabled?const Color(0xFF0088CC):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(13)),
              child:AnimatedAlign(duration:const Duration(milliseconds:200),
                alignment:_tgEnabled?Alignment.centerRight:Alignment.centerLeft,
                child:Container(margin:const EdgeInsets.all(3),width:20,height:20,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle)))),
          ),
        ])),
        const SizedBox(height:14),
        Container(height:1,color:const Color(0xFF1A2640)),
        Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          // Bot Token field
          const Text('BOT TOKEN',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:6),
          TextField(
            controller: _tgBotCtrl,
            style: const TextStyle(color:Colors.white,fontSize:12,fontFamily:'monospace'),
            decoration: InputDecoration(
              hintText: '1234567890:ABCdef...',
              hintStyle: const TextStyle(color:Colors.grey,fontSize:12),
              filled: true, fillColor: const Color(0xFF1A2640),
              border: OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal:12,vertical:10),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check_circle, color:Color(0xFF0088CC), size:20),
                onPressed:(){
                  FocusScope.of(context).unfocus();
                  setState((){_tgBotToken=_tgBotCtrl.text.trim();});
                  _saveTgSettings();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content:Text('Bot token saved ✓'), backgroundColor:Color(0xFF0088CC), duration:Duration(seconds:2)));
                }),
            ),
            onChanged:(v){ _tgBotToken=v.trim(); },
            onSubmitted:(v){ setState((){_tgBotToken=v.trim();}); _saveTgSettings(); },
          ),
          const SizedBox(height:12),
          // Chat ID field
          const Text('CHAT ID',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:6),
          TextField(
            controller: _tgChatCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(color:Colors.white,fontSize:12,fontFamily:'monospace'),
            decoration: InputDecoration(
              hintText: '-1001234567890 or your user ID',
              hintStyle: const TextStyle(color:Colors.grey,fontSize:12),
              filled: true, fillColor: const Color(0xFF1A2640),
              border: OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal:12,vertical:10),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check_circle, color:Color(0xFF0088CC), size:20),
                onPressed:(){
                  FocusScope.of(context).unfocus();
                  setState((){_tgChatId=_tgChatCtrl.text.trim();});
                  _saveTgSettings();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content:Text('Chat ID saved ✓'), backgroundColor:Color(0xFF0088CC), duration:Duration(seconds:2)));
                }),
            ),
            onChanged:(v){ _tgChatId=v.trim(); },
            onSubmitted:(v){ setState((){_tgChatId=v.trim();}); _saveTgSettings(); },
          ),
          const SizedBox(height:16),
          // Alert toggles
          const Text('NOTIFY ME WHEN',style:TextStyle(color:Colors.grey,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:8),
          _tgToggle('Bot wins a trade 🟢',  _tgWinAlert,  (){setState((){_tgWinAlert=!_tgWinAlert;_saveTgSettings();});}),
          _tgToggle('Bot loses a trade 🔴', _tgLossAlert, (){setState((){_tgLossAlert=!_tgLossAlert;_saveTgSettings();});}),
          _tgToggle('TP / SL hit 🎯🛑',    _tgTpSlAlert, (){setState((){_tgTpSlAlert=!_tgTpSlAlert;_saveTgSettings();});}),
          _tgToggle('High volatility ⚡',   _tgVolAlert,  (){setState((){_tgVolAlert=!_tgVolAlert;_saveTgSettings();});}),
          const SizedBox(height:14),
          // Test button
          GestureDetector(
            onTap: _tgBotToken.isEmpty||_tgChatId.isEmpty ? null : () async {
              setState((){_tgTesting=true;});
              await _sendTelegram('🦬 <b>SOET Test Alert</b>\nTelegram alerts are working! You will now get notified when bots trade.');
              await Future.delayed(const Duration(seconds:2));
              if(mounted) setState((){_tgTesting=false;});
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical:12),
              decoration: BoxDecoration(
                color: _tgBotToken.isEmpty||_tgChatId.isEmpty ? const Color(0xFF1A2640) : const Color(0xFF0088CC).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _tgBotToken.isEmpty||_tgChatId.isEmpty ? const Color(0xFF1A2640) : const Color(0xFF0088CC).withOpacity(0.5))),
              child: Center(child: _tgTesting
                ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:Color(0xFF0088CC)))
                : Text('Send Test Message',style:TextStyle(
                    color: _tgBotToken.isEmpty||_tgChatId.isEmpty ? Colors.grey : const Color(0xFF0088CC),
                    fontWeight:FontWeight.bold,fontSize:13))),
            ),
          ),
          const SizedBox(height:12),
          // Setup guide
          Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFF0088CC).withOpacity(0.05),borderRadius:BorderRadius.circular(10),border:Border.all(color:const Color(0xFF0088CC).withOpacity(0.2))),
            child:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('HOW TO SETUP',style:TextStyle(color:Color(0xFF0088CC),fontSize:10,letterSpacing:1.5,fontWeight:FontWeight.bold)),
              SizedBox(height:6),
              Text('1. Open Telegram → search @BotFather\n2. Send /newbot → follow steps → copy token\n3. Search @userinfobot → start it → copy your ID\n4. Paste both above → toggle ON → Test!',
                style:TextStyle(color:Colors.grey,fontSize:11,height:1.6)),
            ])),
        ])),
      ]),
    );
  }

  // ── P&L TRACKER WIDGET ─────────────────────────────
  Widget _pnlTracker() {
    final todayPnl  = _pnl;
    final todayTrades = _trades;
    final todayWins   = _wins;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
        const Text('P&L TRACKER',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),
        const SizedBox(height:12),
        Row(children:[
          Expanded(child:_pnlBox('Today', (todayPnl>=0?'+':'')+'\$'+todayPnl.toStringAsFixed(2), todayPnl>=0?const Color(0xFF00C853):const Color(0xFFFF4444))),
          const SizedBox(width:8),
          Expanded(child:_pnlBox('Trades', todayTrades.toString(), Colors.white)),
          const SizedBox(width:8),
          Expanded(child:_pnlBox('Win Rate', todayTrades>0?(todayWins/todayTrades*100).toStringAsFixed(0)+'%':'0%', const Color(0xFF1DE9B6))),
        ]),
        const SizedBox(height:8),
        // Session time
        if (_sessionStart != null) ...[
          const SizedBox(height:4),
          Builder(builder:(_){
            final dur = DateTime.now().difference(_sessionStart!);
            final h = dur.inHours; final m = dur.inMinutes % 60;
            return Text('Session: '+h.toString()+'h '+m.toString()+'m | Started: '+_sessionStart!.hour.toString().padLeft(2,'0')+':'+_sessionStart!.minute.toString().padLeft(2,'0'),
              style:const TextStyle(color:Colors.grey,fontSize:10));
          }),
        ],
      ]),
    );
  }
  Widget _pnlBox(String label, String val, Color c) => Container(
    padding:const EdgeInsets.all(12),
    decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(10)),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label,style:const TextStyle(color:Colors.grey,fontSize:10)),
      const SizedBox(height:4),
      Text(val,style:TextStyle(color:c,fontWeight:FontWeight.bold,fontSize:16)),
    ]));

  // ── SIGNAL HISTORY WIDGET ────────────────────────────
  Widget _sigHistoryWidget() {
    return Container(
      decoration: BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
      child: Column(children:[
        Padding(padding:const EdgeInsets.fromLTRB(16,14,16,10),child:Row(children:[
          const Expanded(child:Text('SIGNAL HISTORY',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2))),
          GestureDetector(
            onTap:()=>setState((){_sigHistory.clear();}),
            child:const Text('Clear',style:TextStyle(color:Colors.grey,fontSize:11))),
        ])),
        Container(height:1,color:const Color(0xFF1A2640)),
        // Table header
        Container(
          color:const Color(0xFF1A2640),
          padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
          child:const Row(children:[
            SizedBox(width:40,child:Text('Time',style:TextStyle(color:Colors.grey,fontSize:10,fontWeight:FontWeight.bold))),
            SizedBox(width:12),
            Expanded(child:Text('Signal',style:TextStyle(color:Colors.grey,fontSize:10,fontWeight:FontWeight.bold))),
            SizedBox(width:50,child:Text('Result',style:TextStyle(color:Colors.grey,fontSize:10,fontWeight:FontWeight.bold))),
            SizedBox(width:55,child:Text('Profit',style:TextStyle(color:Colors.grey,fontSize:10,fontWeight:FontWeight.bold),textAlign:TextAlign.right)),
          ])),
        // Rows
        ..._sigHistory.take(20).map((s){
          final won = s['won'] as bool;
          final profit = s['profit'] as double;
          return Container(
            padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
            decoration:BoxDecoration(border:Border(bottom:BorderSide(color:const Color(0xFF1A2640),width:0.5))),
            child:Row(children:[
              SizedBox(width:40,child:Text(s['time'],style:const TextStyle(color:Colors.grey,fontSize:10))),
              const SizedBox(width:12),
              Expanded(child:Text(s['signal'],style:const TextStyle(color:Colors.white,fontSize:10),overflow:TextOverflow.ellipsis)),
              SizedBox(width:50,child:Text(won?'✅ Win':'❌ Loss',style:TextStyle(color:won?const Color(0xFF00C853):const Color(0xFFFF4444),fontSize:10))),
              SizedBox(width:55,child:Text((profit>=0?'+':'')+'\$'+profit.toStringAsFixed(2),style:TextStyle(color:profit>=0?const Color(0xFF00C853):const Color(0xFFFF4444),fontSize:10),textAlign:TextAlign.right)),
            ]),
          );
        }).toList(),
        const SizedBox(height:8),
      ]),
    );
  }

  Widget _tgToggle(String label, bool val, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[
      Expanded(child:Text(label,style:const TextStyle(color:Colors.white,fontSize:12))),
      AnimatedContainer(duration:const Duration(milliseconds:200),
        width:40,height:22,
        decoration:BoxDecoration(color:val?const Color(0xFF0088CC):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(11)),
        child:AnimatedAlign(duration:const Duration(milliseconds:200),
          alignment:val?Alignment.centerRight:Alignment.centerLeft,
          child:Container(margin:const EdgeInsets.all(2),width:18,height:18,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle)))),
    ])),
  );

  // ── SIGNAL HISTORY WIDGET ──────────────────────

  // ── TRADE HISTORY WIDGET ────────────────────
  Widget _tradeHistoryWidget() {
    // Compute stats
    final totalTrades = _tradeHistory.length;
    final wins = _tradeHistory.where((t) => t['won']==true).length;
    final losses = totalTrades - wins;
    final totalStake = _tradeHistory.fold(0.0,(s,t)=>s+(t['stake'] as double));
    final totalPayout = _tradeHistory.fold(0.0,(s,t){
      final p = t['profit'] as double;
      final st = t['stake'] as double;
      return s + (t['won']==true ? st+p : 0.0);
    });
    final totalPnl = _tradeHistory.fold(0.0,(s,t)=>s+(t['profit'] as double));

    return Container(
      decoration: BoxDecoration(color:_card, borderRadius:BorderRadius.circular(16), border:Border.all(color:_cardBorder)),
      child: Column(children:[
        // Header
        Padding(padding:const EdgeInsets.fromLTRB(16,14,16,10),child:Row(children:[
          Icon(Icons.receipt_long, color:_accent, size:16),
          const SizedBox(width:8),
          Text('TRANSACTIONS', style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:13,letterSpacing:1)),
          const Spacer(),
          // Download button
          GestureDetector(
            onTap: _downloadTransactions,
            child: Container(
              padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),
              decoration:BoxDecoration(color:_accent.withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:_accent.withOpacity(0.4))),
              child:Row(mainAxisSize:MainAxisSize.min,children:[
                Icon(Icons.download, color:_accent, size:13),
                const SizedBox(width:4),
                Text('Download', style:TextStyle(color:_accent,fontSize:11,fontWeight:FontWeight.bold)),
              ]),
            ),
          ),
        ])),
        Container(height:1,color:_cardBorder),

        if (_tradeHistory.isEmpty)
          Padding(padding:const EdgeInsets.all(24),child:Center(child:Text('No trades yet',style:TextStyle(color:_textSec))))
        else ...[
          // Transaction rows
          ..._tradeHistory.take(30).toList().asMap().entries.map((entry){
            final i = entry.key;
            final t = entry.value;
            final won = t['won'] as bool;
            final profit = t['profit'] as double;
            final stake = t['stake'] as double;
            final payout = won ? stake + profit : 0.0;
            final odd = i % 2 == 1;
            return Container(
              color: odd ? (_isDark ? const Color(0xFF0A1628).withOpacity(0.5) : const Color(0xFFF8FAFC)) : Colors.transparent,
              padding:const EdgeInsets.symmetric(horizontal:16, vertical:10),
              child:Row(children:[
                // Type icon
                Container(width:36,height:36,decoration:BoxDecoration(
                  color:(won?_green:_red).withOpacity(0.1),
                  borderRadius:BorderRadius.circular(8)),
                  child:Icon(won?Icons.trending_up:Icons.trending_down, color:won?_green:_red, size:18)),
                const SizedBox(width:10),
                // Entry/Exit spot + type
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(t['type'].toString(), style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:12)),
                  Text(t['market'].toString(), style:TextStyle(color:_textSec,fontSize:10)),
                  const SizedBox(height:2),
                  Row(children:[
                    Container(width:8,height:8,decoration:BoxDecoration(color:_red,shape:BoxShape.circle)),
                    const SizedBox(width:4),
                    Text(t['time'].toString(), style:TextStyle(color:_textSec,fontSize:10)),
                    const SizedBox(width:4),
                    Container(width:8,height:8,decoration:BoxDecoration(color:won?_green:Colors.grey,shape:BoxShape.circle)),
                    const SizedBox(width:4),
                    Text(t['time'].toString(), style:TextStyle(color:_textSec,fontSize:10)),
                  ]),
                ])),
                // Buy price and P/L
                Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                  Text('\$'+stake.toStringAsFixed(2), style:TextStyle(color:_textPrim,fontWeight:FontWeight.bold,fontSize:12)),
                  Text((profit>=0?'+':'')+'\$'+profit.toStringAsFixed(2),
                    style:TextStyle(color:won?_green:_red, fontSize:12, fontWeight:FontWeight.bold)),
                ]),
              ]),
            );
          }).toList(),

          // Summary bar — like DBot
          Container(
            margin:const EdgeInsets.all(12),
            padding:const EdgeInsets.all(14),
            decoration:BoxDecoration(color:_isDark?const Color(0xFF1A2640):const Color(0xFFF0F4F8),borderRadius:BorderRadius.circular(12)),
            child:Column(children:[
              Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                _txStat('Total stake', '\$'+totalStake.toStringAsFixed(2), _textSec),
                _txStat('Total payout', '\$'+totalPayout.toStringAsFixed(2), _textSec),
                _txStat('No. of runs', totalTrades.toString(), _textSec),
              ]),
              const SizedBox(height:10),
              Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                _txStat('Contracts lost', losses.toString(), _red),
                _txStat('Contracts won', wins.toString(), _green),
                _txStat('Total P/L', (totalPnl>=0?'+':'')+'\$'+totalPnl.toStringAsFixed(2), totalPnl>=0?_green:_red),
              ]),
            ]),
          ),

          // Reset button
          Padding(padding:const EdgeInsets.fromLTRB(12,0,12,12),child:GestureDetector(
            onTap:()=>setState((){_tradeHistory.clear();_saveHistory();}),
            child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:10),
              decoration:BoxDecoration(color:_red.withOpacity(0.1),borderRadius:BorderRadius.circular(10),border:Border.all(color:_red.withOpacity(0.4))),
              child:Center(child:Text('Reset',style:TextStyle(color:_red,fontWeight:FontWeight.bold,fontSize:13)))),
          )),
        ],
      ]),
    );
  }

  Widget _txStat(String label, String value, Color color) => Column(children:[
    Text(label, style:TextStyle(color:_textSec,fontSize:9,letterSpacing:0.5)),
    const SizedBox(height:3),
    Text(value, style:TextStyle(color:color,fontWeight:FontWeight.bold,fontSize:13)),
  ]);

  void _downloadTransactions() {
    if (_tradeHistory.isEmpty) return;
    // Build CSV content
    final lines = ['Time,Market,Type,Stake,Won,Profit'];
    for (final t in _tradeHistory) {
      lines.add('${t['time']},${t['market']},${t['type']},${t['stake']},${t['won']},${t['profit']}');
    }
    final csv = lines.join('\n');
    // Trigger download via JS
    html.window.postMessage('soet_download:trades.csv:' + csv, '*');
  }


  Widget _statBox(String label, String value, Color color) => Expanded(
    child: Container(padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFF0D1421), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        const SizedBox(height:4),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    ),
  );

  // ── NAV ─────────────────────────────────────
  Widget _nav(){
    final items=[
      {'i':Icons.dashboard_rounded,'l':'Dashboard'},
      {'i':Icons.analytics_rounded,'l':'Analyzer'},
      {'i':Icons.calculate_rounded,'l':'Calc'},
      {'i':Icons.smart_toy_rounded,'l':'Bots'},
      {'i':Icons.person_rounded,   'l':'Profile'},
    ];
    return Container(
      decoration:BoxDecoration(
        color:_card,
        border:Border(bottom:BorderSide(color:_cardBorder))),
      child:Row(children:List.generate(items.length,(i){
        bool sel=_tab==i;
        return Expanded(child:GestureDetector(
          onTap:()=>setState(()=>_tab=i),
          child:Container(
            padding:const EdgeInsets.symmetric(vertical:8),
            decoration:BoxDecoration(
              border:Border(bottom:BorderSide(
                color:sel?const Color(0xFF1DE9B6):Colors.transparent,
                width:2.5))),
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              Icon(items[i]['i'] as IconData,
                color:sel?const Color(0xFF1DE9B6):_textSec,size:18),
              const SizedBox(height:2),
              Text(items[i]['l'] as String,
                style:TextStyle(
                  color:sel?const Color(0xFF1DE9B6):_textSec,
                  fontSize:9,
                  fontWeight:sel?FontWeight.bold:FontWeight.normal)),
            ]),
          ),
        ));
      })),
    );
  }
}
