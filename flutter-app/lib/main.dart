import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const SynapsifyApp());

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
        id:         (json['id']     as String?) ?? '',
        name:       (json['name']   as String?) ?? 'Desconocido',
        artist:     (json['artist'] as String?) ?? 'Artista desconocido',
        previewUrl:  json['preview_url'] as String?,
        valence:    (json['valence'] as num?)?.toDouble() ?? 0.5,
        energy:     (json['energy']  as num?)?.toDouble() ?? 0.5,
      );
}

class PlaylistResult {
  final String interpretation;
  final List<Track> tracks;
  final String? playlistId;
  final String? playlistUrl;

  PlaylistResult({required this.interpretation,
      required this.tracks, this.playlistId, this.playlistUrl});

  factory PlaylistResult.fromJson(Map<String, dynamic> json) => PlaylistResult(
        interpretation: (json['interpretation'] as String?) ?? '',
        tracks: (json['tracks'] as List).map((t) => Track.fromJson(t as Map<String, dynamic>)).toList(),
        playlistId:  json['playlistId']  as String?,
        playlistUrl: json['playlistUrl'] as String?,
      );
}

class UserSession {
  final String accessToken;
  final String userId;
  UserSession({required this.accessToken, required this.userId});
}

// [NEW] Modelo para items de playlist del usuario
class SpotifyPlaylist {
  final String id;
  final String name;
  final int total;
  SpotifyPlaylist({required this.id, required this.name, required this.total});
  factory SpotifyPlaylist.fromJson(Map<String, dynamic> json) => SpotifyPlaylist(
        id:    json['id']    as String,
        name:  json['name']  as String,
        total: json['total'] as int,
      );
}

// ── API ───────────────────────────────────────────────────────────────────────

Future<PlaylistResult> fetchPlaylist(String prompt) async {
  final response = await http.post(
    Uri.parse('$_gatewayUrl/mood'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'mood': prompt, 'limit': 50}),  // [CHANGE] 10 → 50
  );
  if (response.statusCode != 200) {
    final body = jsonDecode(response.body);
    throw Exception(body['error'] ?? 'Error desconocido');
  }
  return PlaylistResult.fromJson(jsonDecode(response.body));
}

Future<String> getLoginUrl() async {
  final response = await http.get(Uri.parse('$_gatewayUrl/auth/login'));
  return jsonDecode(response.body)['loginUrl'];
}

// [NEW] Obtener playlists del usuario
Future<List<SpotifyPlaylist>> fetchUserPlaylists() async {
  final response = await http.get(Uri.parse('$_gatewayUrl/playlists'));
  if (response.statusCode != 200) {
    final body = jsonDecode(response.body);
    throw Exception(body['error'] ?? 'Error al obtener playlists');
  }
  final data = jsonDecode(response.body);
  return (data['playlists'] as List)
      .map((p) => SpotifyPlaylist.fromJson(p as Map<String, dynamic>))
      .toList();
}

// [NEW] Exportar tracks a Spotify
Future<Map<String, dynamic>> exportToSpotify({
  required List<String> trackIds,
  required String mode,
  String? playlistName,
  String? targetPlaylistId,
  String? moodText,
}) async {
  final response = await http.post(
    Uri.parse('$_gatewayUrl/export'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'trackIds': trackIds,
      'mode': mode,
      if (playlistName != null) 'playlistName': playlistName,
      if (targetPlaylistId != null) 'targetPlaylistId': targetPlaylistId,
      if (moodText != null) 'moodText': moodText,
    }),
  );
  if (response.statusCode != 200) {
    final body = jsonDecode(response.body);
    throw Exception(body['error'] ?? 'Error al exportar');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

const _examples = [
  'Progressive para un atardecer',
  'Jazz para estudiar de noche',
  'Rock argentino de los 90',
];

// ── App ───────────────────────────────────────────────────────────────────────

class SynapsifyApp extends StatelessWidget {
  const SynapsifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Synapsify',
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
      home: const SynapsifyScreen(),
      onGenerateRoute: (settings) {
        if (settings.name != null && settings.name!.startsWith('/callback')) {
          final uri = Uri.parse(settings.name!);
          final token  = uri.queryParameters['token'];
          final userId = uri.queryParameters['userId'];
          return MaterialPageRoute(
            builder: (_) => SynapsifyScreen(
              initialToken:  token,
              initialUserId: userId,
            ),
          );
        }
        return null;
      },
    );
  }
}

class SynapsifyScreen extends StatefulWidget {
  final String? initialToken;
  final String? initialUserId;
  const SynapsifyScreen({super.key, this.initialToken, this.initialUserId});
  @override
  State<SynapsifyScreen> createState() => _SynapsifyScreenState();
}

class _SynapsifyScreenState extends State<SynapsifyScreen>
    with TickerProviderStateMixin {
  final _controller = TextEditingController();
  PlaylistResult? _result;
  bool _loading = false;
  String? _error;
  UserSession? _session;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkCallbackFromUrl();
    });
  }

  void _checkCallbackFromUrl() {
    final href = html.window.location.href;
    final uri = Uri.parse(href);
    final token  = widget.initialToken  ?? uri.queryParameters['token'];
    final userId = widget.initialUserId ?? uri.queryParameters['userId'];
    if (token != null && userId != null && _session == null) {
      setState(() {
        _session = UserSession(accessToken: token, userId: userId);
      });
      html.window.history.replaceState(null, '', '/');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() { _loading = true; _error = null; _result = null; });
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

  // [NEW] Abre el bottom sheet de exportación
  void _showExportSheet() {
    if (_result == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExportSheet(
        tracks: _result!.tracks,
        moodText: _controller.text.trim(),
      ),
    );
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

                        // Chips de ejemplos
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

                        // Botón generar
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
                                  '${_result!.tracks.length} canciones · ${_result!.interpretation}',
                                  style: const TextStyle(fontSize: 12, color: _green),
                                ),
                              ),
                              const Spacer(),

                              // [NEW] Botón exportar (solo si hay sesión activa)
                              if (_session != null)
                                GestureDetector(
                                  onTap: _showExportSheet,
                                  child: Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.transparent,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: _green.withOpacity(0.5)),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.ios_share, size: 14, color: _green),
                                        SizedBox(width: 4),
                                        Text('Exportar',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: _green,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),

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

// ── [NEW] Export Bottom Sheet ─────────────────────────────────────────────────

class _ExportSheet extends StatefulWidget {
  final List<Track> tracks;
  final String moodText;
  const _ExportSheet({required this.tracks, required this.moodText});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Pestaña "Crear nueva"
  final _nameController = TextEditingController();
  bool _creatingPlaylist = false;
  String? _createError;

  // Pestaña "Agregar a existente"
  List<SpotifyPlaylist>? _userPlaylists;
  bool _loadingPlaylists = true;
  String? _loadError;
  String? _selectedPlaylistId;
  bool _addingTracks = false;
  String? _addError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _nameController.text = widget.moodText.isNotEmpty
        ? 'Synapsify · ${widget.moodText}'.substring(
            0, 'Synapsify · ${widget.moodText}'.length.clamp(0, 60))
        : 'Synapsify Mix';
    _loadPlaylists();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await fetchUserPlaylists();
      setState(() { _userPlaylists = playlists; _loadingPlaylists = false; });
    } catch (e) {
      setState(() { _loadError = e.toString(); _loadingPlaylists = false; });
    }
  }

  Future<void> _createNew() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() { _creatingPlaylist = true; _createError = null; });
    try {
      final result = await exportToSpotify(
        trackIds: widget.tracks.map((t) => t.id).toList(),
        mode: 'create',
        playlistName: name,
        moodText: widget.moodText,
      );
      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessSnack(result['playlistUrl'] as String, result['tracksAdded'] as int);
    } catch (e) {
      setState(() { _createError = e.toString(); _creatingPlaylist = false; });
    }
  }

  Future<void> _addToExisting() async {
    if (_selectedPlaylistId == null) return;
    setState(() { _addingTracks = true; _addError = null; });
    try {
      final result = await exportToSpotify(
        trackIds: widget.tracks.map((t) => t.id).toList(),
        mode: 'add',
        targetPlaylistId: _selectedPlaylistId,
      );
      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessSnack(result['playlistUrl'] as String, result['tracksAdded'] as int);
    } catch (e) {
      setState(() { _addError = e.toString(); _addingTracks = false; });
    }
  }

  void _showSuccessSnack(String url, int count) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: _green, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$count canciones exportadas a Spotify',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            GestureDetector(
              onTap: () => launchUrl(Uri.parse(url),
                  mode: LaunchMode.externalApplication),
              child: const Text('Abrir',
                  style: TextStyle(color: _green, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ],
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0A1510),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: Color(0xFF1A3020), width: 1)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Row(
              children: [
                const Icon(Icons.ios_share, color: _green, size: 18),
                const SizedBox(width: 10),
                const Text('Exportar a Spotify',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const Spacer(),
                Text('${widget.tracks.length} canciones',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4))),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Tabs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: _green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _green.withOpacity(0.4)),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: _green,
                unselectedLabelColor: Colors.white.withOpacity(0.4),
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                tabs: const [
                  Tab(text: 'Crear nueva'),
                  Tab(text: 'Agregar a existente'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Contenido de los tabs
          SizedBox(
            height: 260,
            child: TabBarView(
              controller: _tabController,
              children: [
                // ── Tab 1: Crear nueva ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Nombre de la playlist',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.45))),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: _surfaceHigh,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1A3020)),
                        ),
                        child: TextField(
                          controller: _nameController,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          maxLength: 100,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            counterText: '',
                          ),
                        ),
                      ),
                      if (_createError != null) ...[
                        const SizedBox(height: 8),
                        Text(_createError!,
                            style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12)),
                      ],
                      const Spacer(),
                      _ExportButton(
                        label: 'Crear en Spotify',
                        loading: _creatingPlaylist,
                        onPressed: _createNew,
                      ),
                    ],
                  ),
                ),

                // ── Tab 2: Agregar a existente ───────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loadingPlaylists)
                        const Expanded(
                          child: Center(
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(_green)),
                          ),
                        )
                      else if (_loadError != null)
                        Expanded(
                          child: Center(
                            child: Text(_loadError!,
                                style: const TextStyle(
                                    color: Color(0xFFFF6B6B), fontSize: 13)),
                          ),
                        )
                      else ...[
                        Expanded(
                          child: ListView.builder(
                            itemCount: _userPlaylists!.length,
                            itemBuilder: (context, i) {
                              final pl = _userPlaylists![i];
                              final selected = _selectedPlaylistId == pl.id;
                              return GestureDetector(
                                onTap: () => setState(
                                    () => _selectedPlaylistId = pl.id),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? _green.withOpacity(0.12)
                                        : _surfaceHigh,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: selected
                                          ? _green.withOpacity(0.5)
                                          : const Color(0xFF1A3020),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        selected
                                            ? Icons.check_circle
                                            : Icons.queue_music,
                                        size: 16,
                                        color: selected
                                            ? _green
                                            : Colors.white.withOpacity(0.3),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(pl.name,
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: selected
                                                    ? Colors.white
                                                    : Colors.white
                                                        .withOpacity(0.7)),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      Text('${pl.total}',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.white
                                                  .withOpacity(0.25))),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (_addError != null) ...[
                          const SizedBox(height: 6),
                          Text(_addError!,
                              style: const TextStyle(
                                  color: Color(0xFFFF6B6B), fontSize: 12)),
                        ],
                        const SizedBox(height: 10),
                        _ExportButton(
                          label: 'Agregar a playlist',
                          loading: _addingTracks,
                          onPressed:
                              _selectedPlaylistId != null ? _addToExisting : null,
                        ),
                      ],
                    ],
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

class _ExportButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback? onPressed;
  const _ExportButton(
      {required this.label, required this.loading, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 46,
        decoration: BoxDecoration(
          color: enabled ? _green : _green.withOpacity(0.25),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(Colors.black)))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.ios_share,
                        size: 16,
                        color: enabled ? Colors.black : Colors.white38),
                    const SizedBox(width: 8),
                    Text(label,
                        style: TextStyle(
                            color: enabled ? Colors.black : Colors.white38,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                  ],
                ),
        ),
      ),
    );
  }
}

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
