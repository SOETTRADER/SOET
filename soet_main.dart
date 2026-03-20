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
      onContract?.call(Map.from(d['proposal_open_contract'] as Map));
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

  Future<Map?> getProposal({required String symbol, required String contractType, required double amount, int? barrier}) async {
    if (!_connected) return null;
    final id = _nextId;
    final req = <String,dynamic>{'proposal':1,'amount':amount,'basis':'stake','contract_type':contractType,'currency':'USD','duration':1,'duration_unit':'t','symbol':symbol,'req_id':id}; // duration kept at 1t — digit contracts always 1 tick
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
    symbol.startsWith('1HZ') || symbol.startsWith('JD') ||
    symbol.startsWith('BOOM_') || symbol.startsWith('CRASH_');

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

class SOETApp extends StatelessWidget {
  const SOETApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SOET', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF060B18)),
    home: const SplashScreen(),
  );
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

  // Account
  String _balance = '...', _currency = 'USD', _loginId = '';

  // Market
  String _sym = 'R_10', _symName = 'Volatility 10 Index';
  double _price = 0;
  int    _lastDigit = 0;
  List<int>    _hist       = [];

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

  void _logTrade({required String market, required String type, required double stake, required bool won, required double profit}) {
    // Track signal accuracy + log signal history
    _sessionStart ??= DateTime.now();
    if (won) _sigWins++; else _sigLosses++;
    if (_signal.isNotEmpty && _signal != 'Collecting data...') {
      _logSignalResult(_signal, type, won, profit);
    }
    final now = DateTime.now();
    _tradeHistory.insert(0, {
      'time':   '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}',
      'market': market,
      'type':   type,
      'stake':  stake,
      'won':    won,
      'profit': profit,
    });
    if (_tradeHistory.length > 200) _tradeHistory.removeLast();
    _saveHistory(); // persist immediately
    _syncTradeToFirebase(_tradeHistory.first); // sync to Firebase
  }

  // ── BOT STATE ──────────────────────────────
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
    {'g':'BOOM & CRASH','id':'','n':''},
    {'g':'','id':'BOOM_300',  'n':'Boom 300 Index'},
    {'g':'','id':'BOOM_500',  'n':'Boom 500 Index'},
    {'g':'','id':'BOOM_1000', 'n':'Boom 1000 Index'},
    {'g':'','id':'CRASH_300', 'n':'Crash 300 Index'},
    {'g':'','id':'CRASH_500', 'n':'Crash 500 Index'},
    {'g':'','id':'CRASH_1000','n':'Crash 1000 Index'},
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
        _logTrade(market:_symName, type:_tType, stake:_tStake, won:won, profit:profit);
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
      symbol:_sym, contractType:_ctype(_tType), amount:_tStake, barrier:_barrier(),
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
          // Find hottest digit in recent 20 ticks — avoid it
          final rf = <int,int>{for(int i=0;i<=9;i++) i:0};
          for(final d in recent20) rf[d]=(rf[d]??0)+1;
          final rmx = rf.values.reduce(max);
          final hotD = rf.entries.firstWhere((e)=>e.value==rmx).key;
          return {'type':'DIGITDIFF','barrier':hotD,'label':'Differ $hotD'};

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
          if(recent.isEmpty) return {'type':'DIGITOVER','barrier':4,'label':'Over 4'};
          // Use recent 10 ticks — trade against momentum
          final recentOver = recent.where((d)=>d>4).length;
          final overPct = recentOver/recent.length;
          // Only trade if bias is >60%
          if(overPct >= 0.60) return {'type':'DIGITUNDER','barrier':5,'label':'Under 5 (high streak)'};
          if(overPct <= 0.40) return {'type':'DIGITOVER','barrier':4,'label':'Over 4 (low streak)'};
          // No clear bias — use full history
          final fullOver = _hist.where((d)=>d>4).length;
          return fullOver/_hist.length>0.5
            ?{'type':'DIGITUNDER','barrier':5,'label':'Under 5'}
            :{'type':'DIGITOVER','barrier':4,'label':'Over 4'};

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

      // ── SCHEDULE CHECK ──
      if (!_botScheduleAllowed(bot)) {
        final start = _botStartHour[bot]??8;
        setState((){_botMsg[bot]='⏰ Outside schedule — waiting for ${start.toString().padLeft(2,'0')}:00';_botMsgC[bot]=Colors.grey;});
        // Sleep until schedule window opens
        while(!_botScheduleAllowed(bot) && (_botOn[bot]??false)) {
          await Future.delayed(const Duration(minutes:1));
        }
        if(!(_botOn[bot]??false)) return;
        setState((){_botMsg[bot]='✅ Schedule active — starting...';_botMsgC[bot]=const Color(0xFF1DE9B6);});
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
          final prev=deriv.onContract;
          // Filter by contract ID so multiple bots don't cross-fire
          deriv.onContract=(data){
            prev?.call(data);
            final dataCid = data['contract_id']?.toString() ?? '';
            if (dataCid.isNotEmpty && dataCid != cid) return; // not our contract
            final status=data['status']?.toString()??'';
            final isSold=data['is_sold'];
            final settled=isSold==1||isSold==true||status=='won'||status=='lost';
            if(settled&&!comp.isCompleted) comp.complete(Map.from(data));
          };
          deriv.subscribeContract(cid);
          final result=await comp.future.timeout(const Duration(seconds:20),onTimeout:()=>{});
          if(!mounted||!(_botOn[bot]??false)) return;
          deriv.onContract=prev;
          final profit=(result['profit'] as num?)?.toDouble()??0;
          final status2=result['status']?.toString()??'';
          final won=status2=='won'||profit>0;
          setState((){
            _botBusy[bot]=false;
            _botCount[bot]=(_botCount[bot]??0)+1;
            if(won) _botWins[bot]=(_botWins[bot]??0)+1;
            _botPnl[bot]=(_botPnl[bot]??0)+profit;

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
            _logTrade(market:_botSymName[bot]??_symName, type:decision['label']?.toString()??'', stake:curStake, won:won, profit:profit);
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
      Expanded(child: IndexedStack(index:_tab, children:[
        _dashboard(), _analyzer(), _calculator(), _bots(), _guide(), _profile(),
      ])),
      _nav(),
    ])),
  );

  // ── HEADER ──────────────────────────────────
  Widget _header() {
    Color ac = widget.isDemo ? const Color(0xFF00C853) : const Color(0xFFFFD700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:16,vertical:12),
      decoration: const BoxDecoration(color:Color(0xFF0D1421),border:Border(bottom:BorderSide(color:Color(0xFF1A2640)))),
      child: Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        Row(children:[
          Container(width:32,height:32,decoration:const BoxDecoration(shape:BoxShape.circle,gradient:LinearGradient(colors:[Color(0xFF00C853),Color(0xFF1DE9B6)])),child:const Center(child:Text('🦬',style:TextStyle(fontSize:18)))),
          const SizedBox(width:8),
          const Text('SOET',style:TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.w900,letterSpacing:4)),
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
    if(_streak>0)...[_streakCard(),const SizedBox(height:16)],
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
        const Text('Digit Distribution',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold)),
        const SizedBox(height:16),
        total==0
          ? const Padding(padding:EdgeInsets.all(20),child:Text('Waiting for live ticks...',style:TextStyle(color:Colors.grey)))
          : LayoutBuilder(builder:(ctx,constraints){
              // Fit all 10 digits perfectly regardless of screen width
              final ringSize = ((constraints.maxWidth - 20) / 10).clamp(28.0, 48.0);
              final fontSize = (ringSize * 0.33).clamp(9.0, 15.0);
              final pctSize  = (ringSize * 0.22).clamp(7.0, 10.0);
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
                    CircularProgressIndicator(value:pct/100,strokeWidth:2.5,backgroundColor:const Color(0xFF1A2640),valueColor:AlwaysStoppedAnimation<Color>(ring)),
                    Text('$digit',style:TextStyle(color:isLast?const Color(0xFF1DE9B6):Colors.white70,fontWeight:isLast?FontWeight.bold:FontWeight.normal,fontSize:fontSize)),
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
            Text(_signal,style:TextStyle(color:_sigColor,fontSize:14,fontWeight:FontWeight.bold)),
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
      {'l':'DIFFERS','i':Icons.remove_circle_outline,'c':const Color(0xFF1DE9B6)},
      {'l':'EVEN',   'i':Icons.looks_two_outlined,   'c':const Color(0xFF00C853)},
      {'l':'ODD',    'i':Icons.looks_3_outlined,     'c':const Color(0xFF00C853)},
      {'l':'OVER',   'i':Icons.trending_up,          'c':const Color(0xFFFFD700)},
      {'l':'UNDER',  'i':Icons.trending_down,        'c':const Color(0xFFFF9800)},
      {'l':'MATCHES','i':Icons.center_focus_strong,  'c':const Color(0xFFFF4444)},
    ];
    Color pc = const Color(0xFF1DE9B6);
    for(final t in types){ if(t['l']==_tType){ pc=t['c'] as Color; break; }}
    String sugg = _sigType=='Over/Under'?(_signal.contains('OVER')?'OVER':'UNDER'):_sigType=='Even/Odd'?(_signal.contains('EVEN')?'EVEN':'ODD'):_sigType=='Differs'?'DIFFERS':'';

    return Container(
      decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(20),border:Border.all(color:pc.withOpacity(0.4),width:1.5),boxShadow:[BoxShadow(color:pc.withOpacity(0.08),blurRadius:20,spreadRadius:2)]),
      child:Column(children:[
          // Signal accuracy tracker
          if (_sigWins + _sigLosses > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
              margin: const EdgeInsets.only(bottom:10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2640),
                borderRadius: BorderRadius.circular(10)),
              child: Row(children:[
                const Icon(Icons.track_changes, color:Color(0xFF1DE9B6), size:14),
                const SizedBox(width:8),
                Expanded(child: Text(_sigAccuracy, style: const TextStyle(color:Color(0xFF1DE9B6), fontSize:11, fontWeight:FontWeight.bold))),
                GestureDetector(
                  onTap: ()=>setState((){_sigWins=0;_sigLosses=0;}),
                  child: const Icon(Icons.refresh, color:Colors.grey, size:14)),
              ]),
            ),
          ],
        // Header
        Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:12),
          decoration:BoxDecoration(gradient:LinearGradient(colors:[pc.withOpacity(0.15),pc.withOpacity(0.05)]),borderRadius:const BorderRadius.vertical(top:Radius.circular(20))),
          child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            Row(children:[Icon(Icons.flash_on,color:pc,size:18),const SizedBox(width:8),const Text('QUICK TRADE',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:14,letterSpacing:2))]),
            if(sugg.isNotEmpty) Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),decoration:BoxDecoration(color:pc.withOpacity(0.15),borderRadius:BorderRadius.circular(10),border:Border.all(color:pc.withOpacity(0.4))),
              child:Row(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.auto_awesome,color:pc,size:10),const SizedBox(width:4),Text('AI: $sugg',style:TextStyle(color:pc,fontSize:10,fontWeight:FontWeight.bold))])),
          ])),
        Padding(padding:const EdgeInsets.all(16),child:Column(children:[
          // Trade type grid
          GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:3,crossAxisSpacing:8,mainAxisSpacing:8,childAspectRatio:2.2,
            children:types.map((t){
              bool sel=_tType==t['l']; Color c=t['c'] as Color; bool sug=t['l']==sugg;
              return GestureDetector(onTap:()=>setState(()=>_tType=t['l'] as String),
                child:AnimatedContainer(duration:const Duration(milliseconds:200),
                  decoration:BoxDecoration(color:sel?c:c.withOpacity(0.07),borderRadius:BorderRadius.circular(12),border:Border.all(color:sel?c:sug?c.withOpacity(0.6):c.withOpacity(0.2),width:sel?2:sug?1.5:1),boxShadow:sel?[BoxShadow(color:c.withOpacity(0.3),blurRadius:10,spreadRadius:1)]:null),
                  child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                    Icon(t['i'] as IconData,color:sel?Colors.black:c,size:16),
                    const SizedBox(height:2),
                    Text(t['l'] as String,style:TextStyle(color:sel?Colors.black:c,fontSize:10,fontWeight:FontWeight.bold)),
                    if(sug&&!sel) Text('✦ AI',style:TextStyle(color:c.withOpacity(0.8),fontSize:8)),
                  ])));
            }).toList()),
          const SizedBox(height:12),
          // Barrier selector for OVER/UNDER
          if(_tType=='OVER'||_tType=='UNDER') ...[
            Row(children:[Text('Barrier:',style:TextStyle(color:pc,fontSize:12,fontWeight:FontWeight.bold)),const SizedBox(width:8),
              ...['1','2','3','4','5','6','7','8'].map((b){bool sel=_tBarrier==b;return GestureDetector(onTap:()=>setState(()=>_tBarrier=b),child:Container(width:32,height:32,margin:const EdgeInsets.only(right:6),decoration:BoxDecoration(color:sel?pc:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(8)),child:Center(child:Text(b,style:TextStyle(color:sel?Colors.black:Colors.grey,fontWeight:FontWeight.bold,fontSize:12)))));}  ).toList(),
            ]),const SizedBox(height:12),
          ],
          // Digit selector for MATCHES/DIFFERS
          if(_tType=='MATCHES'||_tType=='DIFFERS') ...[
            Row(children:[Text(_tType=='MATCHES'?'Digit:':'Avoid:',style:TextStyle(color:pc,fontSize:12,fontWeight:FontWeight.bold)),const SizedBox(width:8),
              ...List.generate(10,(i){
                bool sel=_tDigit==i; bool hot=_hist.length>20&&_freq.values.isNotEmpty&&(_freq[i]??0)==_freq.values.reduce(max);
                return GestureDetector(onTap:()=>setState(()=>_tDigit=i),child:Stack(children:[
                  Container(width:28,height:28,margin:const EdgeInsets.only(right:4),decoration:BoxDecoration(color:sel?pc:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(7),border:Border.all(color:hot&&!sel?const Color(0xFFFF4444):Colors.transparent)),child:Center(child:Text('$i',style:TextStyle(color:sel?Colors.black:hot?const Color(0xFFFF4444):Colors.grey,fontWeight:FontWeight.bold,fontSize:11)))),
                  if(hot) Positioned(top:0,right:3,child:Container(width:5,height:5,decoration:const BoxDecoration(color:Color(0xFFFF4444),shape:BoxShape.circle))),
                ]));
              }),
            ]),const SizedBox(height:12),
          ],
          // Stake
          Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Stake:',style:TextStyle(color:Colors.grey,fontSize:12)),
            const SizedBox(height:6),
            Row(children:[
              ...[0.35,0.5,1.0,2.0,5.0].map((amt){bool sel=_tStake==amt;return GestureDetector(onTap:()=>setState(()=>_tStake=amt),child:Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),margin:const EdgeInsets.only(right:6),decoration:BoxDecoration(color:sel?const Color(0xFF00C853):const Color(0xFF1A2640),borderRadius:BorderRadius.circular(8)),child:Text('\$$amt',style:TextStyle(color:sel?Colors.black:Colors.grey,fontWeight:sel?FontWeight.bold:FontWeight.normal,fontSize:11))));}).toList(),
            ]),
            const SizedBox(height:8),
            SizedBox(height:38,child:TextField(
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              style:const TextStyle(color:Colors.white,fontSize:13),
              decoration:InputDecoration(
                hintText:'Custom amount...',hintStyle:const TextStyle(color:Colors.grey,fontSize:12),
                prefixText:'\$ ',prefixStyle:const TextStyle(color:Color(0xFF00C853),fontSize:13),
                contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:8),
                filled:true,fillColor:const Color(0xFF1A2640),
                border:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:BorderSide.none),
                focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(8),borderSide:const BorderSide(color:Color(0xFF00C853),width:1.5)),
              ),
              onChanged:(v){double? val=double.tryParse(v);if(val!=null&&val>0) setState(()=>_tStake=val);},
            )),
          // Stake risk warning
          if (_stakeRiskLabel.isNotEmpty) ...[
            const SizedBox(height:6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal:10, vertical:7),
              decoration: BoxDecoration(
                color: _stakeRiskColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _stakeRiskColor.withOpacity(0.4))),
              child: Row(children:[
                Icon(Icons.warning_amber_rounded, color: _stakeRiskColor, size:13),
                const SizedBox(width:6),
                Expanded(child: Text(_stakeRiskLabel, style: TextStyle(color: _stakeRiskColor, fontSize:11, fontWeight:FontWeight.bold))),
              ]),
            ),
          ],
          ]),
          const SizedBox(height:12),
          // Payout bar
          Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(12)),
            child:Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[
              Column(children:[const Text('Stake',style:TextStyle(color:Colors.grey,fontSize:10)),Text('$_currency ${_tStake.toStringAsFixed(2)}',style:const TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:14))]),
              Container(width:1,height:30,color:const Color(0xFF2A3A50)),
              Column(children:[const Text('Profit',style:TextStyle(color:Colors.grey,fontSize:10)),Text('+$_currency ${_estPayout.toStringAsFixed(2)}',style:const TextStyle(color:Color(0xFF00C853),fontWeight:FontWeight.bold,fontSize:14))]),
              Container(width:1,height:30,color:const Color(0xFF2A3A50)),
              Column(children:[const Text('Return',style:TextStyle(color:Colors.grey,fontSize:10)),Text('$_currency ${(_tStake+_estPayout).toStringAsFixed(2)}',style:TextStyle(color:pc,fontWeight:FontWeight.bold,fontSize:14))]),
            ])),
          const SizedBox(height:12),
          // TRADE BUTTON
          GestureDetector(onTap:(_tBusy||!_live)?null:_placeTrade,
            child:AnimatedContainer(duration:const Duration(milliseconds:200),width:double.infinity,padding:const EdgeInsets.symmetric(vertical:16),
              decoration:BoxDecoration(
                gradient:!_live?const LinearGradient(colors:[Color(0xFF2A3A50),Color(0xFF1A2640)]):_tBusy?LinearGradient(colors:[pc.withOpacity(0.4),pc.withOpacity(0.2)]):LinearGradient(colors:[pc,pc.withOpacity(0.75)]),
                borderRadius:BorderRadius.circular(14),
                boxShadow:(_live&&!_tBusy)?[BoxShadow(color:pc.withOpacity(0.35),blurRadius:16,spreadRadius:1)]:null),
              child:Center(child:Row(mainAxisSize:MainAxisSize.min,children:_tBusy
                ?[SizedBox(width:14,height:14,child:CircularProgressIndicator(strokeWidth:2,color:pc)),const SizedBox(width:10),Text(_tType,style:TextStyle(color:pc,fontWeight:FontWeight.bold,fontSize:15))]
                :[Icon(_live?Icons.play_arrow_rounded:Icons.hourglass_empty,color:_live?Colors.black:Colors.grey,size:22),const SizedBox(width:8),Text(!_live?'Waiting for market...':'$_tType  •  $_currency ${_tStake.toStringAsFixed(2)}',style:TextStyle(color:_live?Colors.black:Colors.grey,fontWeight:FontWeight.bold,fontSize:15,letterSpacing:1))])))),
          // Result — only win or loss shown
          if(_tMsg.isNotEmpty)...[const SizedBox(height:10),AnimatedContainer(duration:const Duration(milliseconds:250),width:double.infinity,padding:const EdgeInsets.symmetric(vertical:14,horizontal:16),
            decoration:BoxDecoration(color:_tColor.withOpacity(0.12),borderRadius:BorderRadius.circular(12),border:Border.all(color:_tColor.withOpacity(0.6),width:1.5)),
            child:Text(_tMsg,textAlign:TextAlign.center,style:TextStyle(color:_tColor,fontSize:16,fontWeight:FontWeight.bold)))],
        ])),
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
    int total=_hist.length, even=_hist.where((d)=>d%2==0).length, over=_hist.where((d)=>d>4).length;
    double ep=total>0?even/total*100:50, op=total>0?over/total*100:50;
    int mx=0, mn=0, hot=0, cold=0;
    try {
      if (total>0 && _freq.values.isNotEmpty) {
        mx=_freq.values.reduce(max); mn=_freq.values.reduce(min);
        hot=_freq.entries.firstWhere((e)=>e.value==mx).key;
        cold=_freq.entries.firstWhere((e)=>e.value==mn).key;
      }
    } catch(_) {}
    return SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[
      // Bar guide
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1DE9B6).withOpacity(0.3))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Row(children:[Icon(Icons.info_outline,color:Color(0xFF1DE9B6),size:16),SizedBox(width:8),Text('WHAT DO THE BARS MEAN?',style:TextStyle(color:Color(0xFF1DE9B6),fontSize:12,fontWeight:FontWeight.bold,letterSpacing:1))]),
          const SizedBox(height:12),
          _barHint('🟢 GREEN (Over side)','How many ticks ended with digit 5-9. Big green = trade OVER 4',const Color(0xFF00C853)),const SizedBox(height:8),
          _barHint('🟡 YELLOW (Under side)','How many ticks ended with digit 0-4. Big yellow = trade UNDER 5',const Color(0xFFFFD700)),const SizedBox(height:8),
          _barHint('🔵 CYAN (Even side)','How many even digits (0,2,4,6,8). Over 55% = trade ODD',const Color(0xFF1DE9B6)),const SizedBox(height:10),
          Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:const Color(0xFF1A2640),borderRadius:BorderRadius.circular(8)),child:const Text('💡 When one side goes above 55% — market usually corrects back to 50/50. That correction is your trade!',style:TextStyle(color:Colors.white70,fontSize:12))),
        ])),
      const SizedBox(height:16),
      if(total>=10)...[_recsCard(),const SizedBox(height:16)],
      if(total<10) Container(margin:const EdgeInsets.only(bottom:16),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:Colors.orange.withOpacity(0.4))),
        child:Row(children:[const Icon(Icons.hourglass_empty,color:Colors.orange,size:20),const SizedBox(width:12),Expanded(child:Text('Collecting ticks... ($total/10 minimum)',style:const TextStyle(color:Colors.orange,fontSize:12)))])),
      _block(title:'EVEN / ODD',ll:'Even',lv:ep,lc:even,rl:'Odd',rv:100-ep,rc:total-even,lCol:const Color(0xFF1DE9B6),rCol:const Color(0xFF00C853),advice:ep>55?'🔵 Even dominant — consider ODD':(100-ep)>55?'🟢 Odd dominant — consider EVEN':'⚖️ Balanced'),
      const SizedBox(height:16),
      _block(title:'OVER / UNDER',ll:'Over 4',lv:op,lc:over,rl:'Under 5',rv:100-op,rc:total-over,lCol:const Color(0xFFFFD700),rCol:const Color(0xFFFF6B35),advice:op>55?'📈 High digits — OVER 4':(100-op)>55?'📉 Low digits — UNDER 5':'⚖️ Balanced'),
      const SizedBox(height:16),
      if(total>0) Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF1A2640))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('DIFFERS GUIDE',style:TextStyle(color:Colors.grey,fontSize:11,letterSpacing:2)),const SizedBox(height:16),
          Row(children:[Expanded(child:_digitBadge(hot,'HOT\nDIFFER FROM',const Color(0xFFFF4444))),const SizedBox(width:12),Expanded(child:_digitBadge(cold,'COLD\nSAFE TO USE',const Color(0xFF00C853)))]),
        ])),
      const SizedBox(height:16),
      if(_hist.length>=10) _last10(),
      const SizedBox(height:16),
      // P&L Tracker
      _pnlTracker(),
      const SizedBox(height:16),
      // Signal History
      if(_sigHistory.isNotEmpty) _sigHistoryWidget(),
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
      const Text('STAKE CALCULATOR',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,letterSpacing:2)),
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
  Widget _bots() => SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('TRADING BOTS',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,letterSpacing:2)),
    const SizedBox(height:4),
    Text(_live?'Connected — bots ready':'⚠️ Connect to market first',style:TextStyle(color:_live?const Color(0xFF00C853):Colors.orange,fontSize:12)),
    const SizedBox(height:16),
    _botCard(id:'differs',  name:'DIFFERS BOT',   desc:'Avoids hottest digit automatically', color:const Color(0xFF1DE9B6), icon:Icons.remove_circle_outline),
    const SizedBox(height:12),
    _botCard(id:'evenodd',  name:'EVEN / ODD BOT', desc:'Trades opposite of dominant side',   color:const Color(0xFF00C853), icon:Icons.swap_horiz),
    const SizedBox(height:12),
    _botCard(id:'overunder',name:'OVER/UNDER BOT', desc:'Trades against the dominant digit side', color:const Color(0xFFFFD700), icon:Icons.trending_up),
    const SizedBox(height:12),
    // MATCHES warning banner
    Container(
      padding: const EdgeInsets.symmetric(horizontal:14, vertical:10),
      decoration: BoxDecoration(color:const Color(0xFFFF4444).withOpacity(0.08),borderRadius:BorderRadius.circular(12),border:Border.all(color:const Color(0xFFFF4444).withOpacity(0.5))),
      child: Row(children:[
        const Icon(Icons.dangerous_outlined, color:Color(0xFFFF4444), size:18),
        const SizedBox(width:10),
        const Expanded(child:Text('MATCHES has ~10% win rate. Only 1 in 10 trades wins. Use only when a digit has not appeared in 20+ ticks.',style:TextStyle(color:Color(0xFFFF4444),fontSize:11))),
      ])),
    const SizedBox(height:8),
    _botCard(id:'matches',  name:'MATCHES BOT',    desc:'⚠️ High risk — 10% win rate', color:const Color(0xFFFF4444), icon:Icons.center_focus_strong),
    const SizedBox(height:20),
    Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:const Color(0xFF0D1421),borderRadius:BorderRadius.circular(12),border:Border.all(color:Colors.orange.withOpacity(0.4))),
      child:const Row(children:[Icon(Icons.warning_amber_rounded,color:Colors.orange,size:18),SizedBox(width:10),Expanded(child:Text('Only 1 bot at a time recommended. Bots use real funds — test on Demo first!',style:TextStyle(color:Colors.orange,fontSize:11)))])),
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
          if(!on) const SizedBox(height:8),
          // ── SCHEDULER ──
          if(!on) _botToggle('Scheduler','Trade only at certain hours',Icons.schedule,const Color(0xFFFFD700),_botScheduleOn[id]??false,()=>setState(()=>_botScheduleOn[id]=!(_botScheduleOn[id]??false))),
          if(!on&&(_botScheduleOn[id]??false))...[
            const SizedBox(height:8),
            Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFFFFD700).withOpacity(0.05),borderRadius:BorderRadius.circular(10),border:Border.all(color:const Color(0xFFFFD700).withOpacity(0.2))),
              child:Column(children:[
                Row(children:[
                  const Icon(Icons.play_circle_outline,color:Color(0xFF00C853),size:14),
                  const SizedBox(width:6),
                  const Text('Start hour',style:TextStyle(color:Colors.grey,fontSize:11)),
                  const Spacer(),
                  GestureDetector(onTap:()=>setState((){if((_botStartHour[id]??8)>0)_botStartHour[id]=(_botStartHour[id]??8)-1;}),child:const Icon(Icons.remove_circle_outline,color:Colors.grey,size:18)),
                  const SizedBox(width:8),
                  Text('${(_botStartHour[id]??8).toString().padLeft(2,'0')}:00',style:const TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:13)),
                  const SizedBox(width:8),
                  GestureDetector(onTap:()=>setState((){if((_botStartHour[id]??8)<23)_botStartHour[id]=(_botStartHour[id]??8)+1;}),child:const Icon(Icons.add_circle_outline,color:Color(0xFF00C853),size:18)),
                ]),
                const SizedBox(height:8),
                Row(children:[
                  const Icon(Icons.stop_circle_outlined,color:Color(0xFFFF4444),size:14),
                  const SizedBox(width:6),
                  const Text('Stop hour',style:TextStyle(color:Colors.grey,fontSize:11)),
                  const Spacer(),
                  GestureDetector(onTap:()=>setState((){if((_botStopHour[id]??17)>0)_botStopHour[id]=(_botStopHour[id]??17)-1;}),child:const Icon(Icons.remove_circle_outline,color:Colors.grey,size:18)),
                  const SizedBox(width:8),
                  Text('${(_botStopHour[id]??17).toString().padLeft(2,'0')}:00',style:const TextStyle(color:Colors.white,fontWeight:FontWeight.bold,fontSize:13)),
                  const SizedBox(width:8),
                  GestureDetector(onTap:()=>setState((){if((_botStopHour[id]??17)<23)_botStopHour[id]=(_botStopHour[id]??17)+1;}),child:const Icon(Icons.add_circle_outline,color:Color(0xFF00C853),size:18)),
                ]),
                const SizedBox(height:8),
                Text('Bot trades only between ${(_botStartHour[id]??8).toString().padLeft(2,'0')}:00 – ${(_botStopHour[id]??17).toString().padLeft(2,'0')}:00',
                  style:const TextStyle(color:Color(0xFFFFD700),fontSize:10),textAlign:TextAlign.center),
              ])),
          ],
        ])),

        // Live stats — show when running or has trades
        if(on||count>0)...[
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
            if(on)...[
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
    const Text('SOET GUIDE',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,letterSpacing:2)),
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
          if(_loginId.isNotEmpty)...[const SizedBox(height:6),Text('Account: $_loginId',style:const TextStyle(color:Colors.grey,fontSize:11))],
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
      _sigHistoryWidget(),
      const SizedBox(height:20),
      _telegramSection(),
      const SizedBox(height:20),
      _firebaseSection(),
      const SizedBox(height:20),
      _tradeHistoryWidget(),
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
    if (_tradeHistory.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: const Color(0xFF0D1421), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1A2640))),
        child: const Center(child: Column(children: [
          Icon(Icons.history, color: Colors.grey, size:40),
          SizedBox(height:8),
          Text('No trades yet this session', style: TextStyle(color: Colors.grey)),
          Text('Place a trade to see history here', style: TextStyle(color: Colors.grey, fontSize:12)),
        ])),
      );
    }

    // Stats summary
    final totalTrades = _tradeHistory.length;
    final wins = _tradeHistory.where((t) => t['won'] == true).length;
    final winRate = totalTrades > 0 ? wins / totalTrades * 100 : 0.0;
    final totalPnl = _tradeHistory.fold(0.0, (s, t) => s + (t['profit'] as double));
    final bestTrade = _tradeHistory.reduce((a,b) => (a['profit'] as double) > (b['profit'] as double) ? a : b);
    final worstTrade = _tradeHistory.reduce((a,b) => (a['profit'] as double) < (b['profit'] as double) ? a : b);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Stats summary row
      const Text('SESSION STATS', style: TextStyle(color: Colors.grey, fontSize: 11, letterSpacing:2)),
      const SizedBox(height: 10),
      Row(children: [
        _statBox('Trades', '$totalTrades', const Color(0xFF1DE9B6)),
        const SizedBox(width: 8),
        _statBox('Win Rate', '${winRate.toStringAsFixed(1)}%', winRate >= 50 ? const Color(0xFF00C853) : const Color(0xFFFF4444)),
        const SizedBox(width: 8),
        _statBox('P&L', '${totalPnl >= 0 ? "+" : ""}\$${totalPnl.toStringAsFixed(2)}', totalPnl >= 0 ? const Color(0xFF00C853) : const Color(0xFFFF4444)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        _statBox('Best', '+\$${(bestTrade['profit'] as double).abs().toStringAsFixed(2)}', const Color(0xFF00C853)),
        const SizedBox(width: 8),
        _statBox('Worst', '-\$${(worstTrade['profit'] as double).abs().toStringAsFixed(2)}', const Color(0xFFFF4444)),
        const SizedBox(width: 8),
        _statBox('Wins', '$wins / $totalTrades', const Color(0xFFFFD700)),
      ]),
      const SizedBox(height: 16),

      // History header
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('TRADE HISTORY', style: TextStyle(color: Colors.grey, fontSize: 11, letterSpacing:2)),
        GestureDetector(
          onTap: () => setState(() => _tradeHistory.clear()),
          child: Container(padding: const EdgeInsets.symmetric(horizontal:10, vertical:4),
            decoration: BoxDecoration(color: const Color(0xFFFF4444).withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFFF4444).withOpacity(0.3))),
            child: const Text('Clear', style: TextStyle(color: Color(0xFFFF4444), fontSize: 11))),
        ),
      ]),
      const SizedBox(height: 8),

      // Trade list
      Container(decoration: BoxDecoration(color: const Color(0xFF0D1421), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1A2640))),
        child: Column(children: [
          // Header row
          Container(padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
            decoration: const BoxDecoration(color: Color(0xFF1A2640), borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16))),
            child: Row(children: const [
              SizedBox(width:50, child: Text('Time', style: TextStyle(color: Colors.grey, fontSize:10, fontWeight: FontWeight.bold))),
              SizedBox(width:8),
              Expanded(child: Text('Market', style: TextStyle(color: Colors.grey, fontSize:10, fontWeight: FontWeight.bold))),
              SizedBox(width:8),
              SizedBox(width:55, child: Text('Type', style: TextStyle(color: Colors.grey, fontSize:10, fontWeight: FontWeight.bold))),
              SizedBox(width:8),
              SizedBox(width:45, child: Text('Stake', style: TextStyle(color: Colors.grey, fontSize:10, fontWeight: FontWeight.bold))),
              SizedBox(width:8),
              SizedBox(width:55, child: Text('Result', style: TextStyle(color: Colors.grey, fontSize:10, fontWeight: FontWeight.bold, overflow: TextOverflow.clip))),
            ])),
          // Trade rows
          ...(_tradeHistory.take(50).toList().asMap().entries.map((entry) {
            final i = entry.key;
            final t = entry.value;
            final won = t['won'] as bool;
            final profit = t['profit'] as double;
            final c = won ? const Color(0xFF00C853) : const Color(0xFFFF4444);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
              decoration: BoxDecoration(
                color: i % 2 == 0 ? Colors.transparent : const Color(0xFF0A0F1E),
                border: const Border(bottom: BorderSide(color: Color(0xFF1A2640), width: 0.5)),
              ),
              child: Row(children: [
                SizedBox(width:50, child: Text(t['time'], style: const TextStyle(color: Colors.grey, fontSize:10))),
                const SizedBox(width:8),
                Expanded(child: Text(t['market'], style: const TextStyle(color: Colors.white70, fontSize:10), overflow: TextOverflow.ellipsis)),
                const SizedBox(width:8),
                SizedBox(width:55, child: Text(t['type'], style: TextStyle(color: const Color(0xFF1DE9B6), fontSize:10), overflow: TextOverflow.ellipsis)),
                const SizedBox(width:8),
                SizedBox(width:45, child: Text('\$${(t['stake'] as double).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70, fontSize:10))),
                const SizedBox(width:8),
                SizedBox(width:55, child: Text('${won ? "✅ +" : "❌ -"}\$${profit.abs().toStringAsFixed(2)}', style: TextStyle(color: c, fontSize:10, fontWeight: FontWeight.bold))),
              ]),
            );
          })).toList(),
        ]),
      ),
    ]);
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
      {'i':Icons.calculate_rounded,'l':'Calculator'},
      {'i':Icons.smart_toy_rounded,'l':'Bots'},
      {'i':Icons.menu_book_rounded,'l':'Guide'},
      {'i':Icons.person_rounded,   'l':'Profile'},
    ];
    return Container(padding:const EdgeInsets.symmetric(vertical:8),decoration:const BoxDecoration(color:Color(0xFF0D1421),border:Border(top:BorderSide(color:Color(0xFF1A2640)))),
      child:Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:List.generate(items.length,(i){
        bool sel=_tab==i;
        return GestureDetector(onTap:()=>setState(()=>_tab=i),child:Column(mainAxisSize:MainAxisSize.min,children:[
          Icon(items[i]['i'] as IconData,color:sel?const Color(0xFF1DE9B6):Colors.grey,size:22),
          const SizedBox(height:3),
          Text(items[i]['l'] as String,style:TextStyle(color:sel?const Color(0xFF1DE9B6):Colors.grey,fontSize:9)),
          if(sel) Container(margin:const EdgeInsets.only(top:2),width:4,height:4,decoration:const BoxDecoration(color:Color(0xFF1DE9B6),shape:BoxShape.circle)),
        ]));
      })));
  }
}
