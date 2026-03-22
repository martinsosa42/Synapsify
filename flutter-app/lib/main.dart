import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MoodifyApp());

const _gatewayUrl = 'http://localhost:8080';
const _green = Color(0xFF1DB954);
const _greenGlow = Color(0xFF1ED760);
const _bg = Color(0xFF040A06);
const _surface = Color(0xFF0D1A10);
const _surfaceHigh = Color(0xFF142119);

// ── Modelos ───────────────────────────────────────────────────────────────────

class Track {
  final String id;
  final String name;
  final String artist;
  final String? previewUrl;
  final double valence;
  final double energy;

  Track({required this.id, required this.name, required this.artist,
      this.previewUrl, required this.valence, required this.energy});

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'], name: json['name'], artist: json['artist'],
        previewUrl: json['preview_url'],
        valence: (json['valence'] as num).toDouble(),
        energy: (json['energy'] as num).toDouble(),
      );
}

class PlaylistResult {
  final String sentiment;
  final double compound;
  final List<Track> tracks;
  final String? playlistUrl;

  PlaylistResult({required this.sentiment, required this.compound,
      required this.tracks, this.playlistUrl});

  factory PlaylistResult.fromJson(Map<String, dynamic> json) => PlaylistResult(
        sentiment: json['sentiment'],
        compound: (json['compound'] as num).toDouble(),
        tracks: (json['tracks'] as List).map((t) => Track.fromJson(t)).toList(),
        playlistUrl: json['playlistUrl'],
      );
}

class UserSession {
  final String accessToken;
  final String userId;
  UserSession({required this.accessToken, required this.userId});
}

// ── API ───────────────────────────────────────────────────────────────────────

Future<PlaylistResult> fetchPlaylist(String prompt) async {
  final response = await http.post(
    Uri.parse('$_gatewayUrl/mood'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'mood': prompt, 'limit': 10}),
  );
  if (response.statusCode != 200) {
    final body = jsonDecode(response.body);
    throw Exception(body['error'] ?? 'Error desconocido');
  }
  return PlaylistResult.fromJson(jsonDecode(response.body));
}

Future<void> sendFeedback(String trackId, bool liked, String prompt) async {
  await http.post(Uri.parse(
      '$_gatewayUrl/feedback?track_id=$trackId&liked=$liked&mood=${Uri.encodeComponent(prompt)}'));
}

Future<String> getLoginUrl() async {
  final response = await http.get(Uri.parse('$_gatewayUrl/auth/login'));
  return jsonDecode(response.body)['loginUrl'];
}

const _examples = [
  'Progressive para un atardecer',
  'Jazz para estudiar de noche',
  'Rock argentino de los 90',
];

// ── App ───────────────────────────────────────────────────────────────────────

class MoodifyApp extends StatelessWidget {
  const MoodifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moodify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _green,
          secondary: _greenGlow,
          surface: _surface,
        ),
        useMaterial3: true,
      ),
      home: const MoodifyScreen(),
    );
  }
}

class MoodifyScreen extends StatefulWidget {
  const MoodifyScreen({super.key});
  @override
  State<MoodifyScreen> createState() => _MoodifyScreenState();
}

class _MoodifyScreenState extends State<MoodifyScreen>
    with TickerProviderStateMixin {
  final _controller = TextEditingController();
  PlaylistResult? _result;
  bool _loading = false;
  String? _error;
  UserSession? _session;
  final Map<String, bool> _feedback = {};
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() { _loading = true; _error = null; _result = null; _feedback.clear(); });
    try {
      final result = await fetchPlaylist(text);
      setState(() => _result = result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loginWithSpotify() async {
    try {
      final url = await getLoginUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      setState(() => _error = 'No se pudo iniciar el login: $e');
    }
  }

  void _logout() {
    setState(() => _session = null);
    http.post(Uri.parse('$_gatewayUrl/auth/logout'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Fondo gradiente
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.6),
                  radius: 1.2,
                  colors: [Color(0xFF0D2015), _bg],
                ),
              ),
            ),
          ),

          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── SIDEBAR ──────────────────────────────────────────────
                Container(
                  width: 220,
                  height: double.infinity,
                  decoration: const BoxDecoration(
                    color: Color(0xFF070E08),
                    border: Border(
                      right: BorderSide(color: Color(0xFF0F1E10), width: 1),
                    ),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo
                      Image.asset('assets/logo.png', width: 160, fit: BoxFit.contain),

                      const SizedBox(height: 32),
                      Container(height: 1, color: const Color(0xFF0F1E10)),
                      const SizedBox(height: 24),

                      // Estado sesión
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, _) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: _session != null
                                ? _green.withOpacity(0.08 + _pulseController.value * 0.04)
                                : const Color(0xFF0D1A10),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _session != null
                                  ? _green.withOpacity(0.3)
                                  : const Color(0xFF1A2E1A),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8, height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _session != null ? _greenGlow : const Color(0xFF3D5A3D),
                                  boxShadow: _session != null
                                      ? [BoxShadow(color: _green.withOpacity(0.6), blurRadius: 6)]
                                      : [],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _session != null ? 'Conectado' : 'Sin sesión',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _session != null ? _green : const Color(0xFF4A6B4A),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // Botón login/logout
                      GestureDetector(
                        onTap: _session == null ? _loginWithSpotify : _logout,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D1A10),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF1A2E1A)),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _session == null ? Icons.login : Icons.logout,
                                size: 16,
                                color: _session == null ? _green : const Color(0xFF6B8F6B),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _session == null ? 'Conectar Spotify' : 'Cerrar sesión',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _session == null ? _green : const Color(0xFF6B8F6B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const Spacer(),

                      Text(
                        'by MSS for Spotify',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.15),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── CONTENIDO PRINCIPAL ───────────────────────────────────
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(36, 36, 36, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [

                        const Text(
                          'Tu lenguaje.\nTu playlist.',
                          style: TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.1,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Describí lo que querés escuchar.',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withOpacity(0.35),
                          ),
                        ),

                        const SizedBox(height: 28),

                        // Input
                        Container(
                          decoration: BoxDecoration(
                            color: _surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _loading
                                  ? _green.withOpacity(0.5)
                                  : const Color(0xFF1A2E1A),
                              width: 1.5,
                            ),
                            boxShadow: _loading
                                ? [BoxShadow(color: _green.withOpacity(0.12), blurRadius: 20)]
                                : [],
                          ),
                          child: TextField(
                            controller: _controller,
                            maxLines: 3,
                            style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.6),
                            decoration: InputDecoration(
                              hintText: 'ej: "Techno progresivo para las 3am" o "Jazz melancólico de los 60"',
                              hintStyle: TextStyle(color: Colors.white.withOpacity(0.18), fontSize: 14),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.all(20),
                            ),
                            onSubmitted: (_) => _generate(),
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Chips
                        Wrap(
                          spacing: 8,
                          children: _examples.map((e) => GestureDetector(
                            onTap: () { _controller.text = e; _generate(); },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                              decoration: BoxDecoration(
                                color: _surface,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: const Color(0xFF1A3020)),
                              ),
                              child: Text(e,
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF5A9E6A))),
                            ),
                          )).toList(),
                        ),

                        const SizedBox(height: 16),

                        // Botón
                        _GenerateButton(loading: _loading, onPressed: _generate),

                        const SizedBox(height: 20),

                        // Error
                        if (_error != null)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.red.withOpacity(0.2)),
                            ),
                            child: Text(_error!,
                                style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13)),
                          ),

                        // Resultados
                        if (_result != null) ...[
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: _green.withOpacity(0.3)),
                                ),
                                child: Text(
                                  '${_result!.tracks.length} canciones · ${_result!.sentiment}',
                                  style: const TextStyle(fontSize: 12, color: _green),
                                ),
                              ),
                              const Spacer(),
                              if (_result!.playlistUrl != null)
                                GestureDetector(
                                  onTap: () => launchUrl(
                                    Uri.parse(_result!.playlistUrl!),
                                    mode: LaunchMode.externalApplication,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _green,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.open_in_new, size: 14, color: Colors.black),
                                        SizedBox(width: 4),
                                        Text('Ver en Spotify',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.black,
                                                fontWeight: FontWeight.w700)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _result!.tracks.length,
                              itemBuilder: (context, i) {
                                final track = _result!.tracks[i];
                                final fb = _feedback[track.id];
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: i.isEven ? _surface : _surfaceHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF0F2010), width: 1),
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 28,
                                        child: Text('${i + 1}',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: Colors.white.withOpacity(0.2),
                                                fontWeight: FontWeight.w600)),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(track.name,
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.white),
                                                overflow: TextOverflow.ellipsis),
                                            const SizedBox(height: 2),
                                            Text(track.artist,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.white.withOpacity(0.45)),
                                                overflow: TextOverflow.ellipsis),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          _MiniBar(label: 'V', value: track.valence, color: _green),
                                          const SizedBox(height: 3),
                                          _MiniBar(label: 'E', value: track.energy,
                                              color: const Color(0xFFFF8C00)),
                                        ],
                                      ),
                                      const SizedBox(width: 12),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _FeedbackBtn(
                                            icon: Icons.thumb_up_outlined,
                                            active: fb == true,
                                            activeColor: _green,
                                            onTap: () async {
                                              setState(() => _feedback[track.id] = true);
                                              await sendFeedback(track.id, true, _controller.text);
                                            },
                                          ),
                                          const SizedBox(width: 4),
                                          _FeedbackBtn(
                                            icon: Icons.thumb_down_outlined,
                                            active: fb == false,
                                            activeColor: const Color(0xFFFF4444),
                                            onTap: () async {
                                              setState(() => _feedback[track.id] = false);
                                              await sendFeedback(track.id, false, _controller.text);
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ] else
                          const Spacer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Widgets auxiliares ────────────────────────────────────────────────────────

class _GenerateButton extends StatefulWidget {
  final bool loading;
  final VoidCallback onPressed;
  const _GenerateButton({required this.loading, required this.onPressed});
  @override
  State<_GenerateButton> createState() => _GenerateButtonState();
}

class _GenerateButtonState extends State<_GenerateButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.loading ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 52,
          decoration: BoxDecoration(
            color: _hovered && !widget.loading ? _greenGlow : _green,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: _green.withOpacity(_hovered ? 0.5 : 0.25),
                blurRadius: _hovered ? 24 : 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: widget.loading
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation(Colors.black)))
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.queue_music, color: Colors.black, size: 20),
                      SizedBox(width: 8),
                      Text('Generar Playlist',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              letterSpacing: 0.3)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _MiniBar extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const _MiniBar({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: color.withOpacity(0.6))),
        const SizedBox(width: 4),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(2),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      ],
    );
  }
}

class _FeedbackBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  const _FeedbackBtn({required this.icon, required this.active,
      required this.activeColor, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? activeColor.withOpacity(0.4) : Colors.transparent),
        ),
        child: Icon(icon, size: 14,
            color: active ? activeColor : Colors.white.withOpacity(0.2)),
      ),
    );
  }
}
