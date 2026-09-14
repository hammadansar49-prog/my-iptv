import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../xtream_client.dart';
import 'main_shell.dart';

class LoginScreen extends StatefulWidget {
  final AppState state;
  const LoginScreen({super.key, required this.state});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late TabController tabController;
  final urlCtrl = TextEditingController();
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final m3uNameCtrl = TextEditingController();
  final m3uUrlCtrl = TextEditingController();

  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 2, vsync: this);
  }

  Future<void> _doLogin(Account acc) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.state.login(acc);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MainShell(state: widget.state)),
      );
    } on XtreamException catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _submit() {
    if (tabController.index == 0) {
      var url = urlCtrl.text.trim();
      final user = userCtrl.text.trim();
      final pass = passCtrl.text.trim();
      if (url.isEmpty || user.isEmpty || pass.isEmpty) {
        setState(() => error = 'Please fill in server URL, username and password.');
        return;
      }
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) url = 'http://$url';
      final acc = Account(
        id: 'x_${DateTime.now().millisecondsSinceEpoch}',
        type: 'xtream',
        name: '$user @ ${Uri.tryParse(url)?.host ?? url}',
        url: url,
        username: user,
        password: pass,
      );
      _doLogin(acc);
    } else {
      final url = m3uUrlCtrl.text.trim();
      if (url.isEmpty) {
        setState(() => error = 'Please provide an M3U URL.');
        return;
      }
      setState(() => error = 'M3U playlists are coming soon on Android — please use Xtream Codes for now.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.state.savedAccounts;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [AppColors.accent, AppColors.accent2]),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Text('Z', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      ),
                      const SizedBox(width: 12),
                      const Text('IPTV Player', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.all(4),
                    child: TabBar(
                      controller: tabController,
                      indicator: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(7)),
                      labelColor: Colors.white,
                      unselectedLabelColor: AppColors.textDim,
                      dividerColor: Colors.transparent,
                      tabs: const [Tab(text: 'Xtream Codes'), Tab(text: 'M3U URL')],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 210,
                    child: TabBarView(
                      controller: tabController,
                      children: [
                        Column(
                          children: [
                            _field(urlCtrl, 'Server URL', 'http://server.example.com:8080'),
                            const SizedBox(height: 10),
                            _field(userCtrl, 'Username', 'Username'),
                            const SizedBox(height: 10),
                            _field(passCtrl, 'Password', 'Password', obscure: true),
                          ],
                        ),
                        Column(
                          children: [
                            _field(m3uNameCtrl, 'Playlist Name', 'My Playlist'),
                            const SizedBox(height: 10),
                            _field(m3uUrlCtrl, 'M3U URL', 'http://server.example.com/playlist.m3u'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 6),
                    Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                  ],
                  const SizedBox(height: 14),
                  ElevatedButton(
                    onPressed: loading ? null : _submit,
                    child: loading
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Login'),
                  ),
                  if (saved.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Align(alignment: Alignment.centerLeft, child: Text('Saved accounts', style: TextStyle(color: AppColors.textDim, fontSize: 12))),
                    const SizedBox(height: 8),
                    ...saved.map((acc) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(8)),
                          child: Row(
                            children: [
                              Expanded(child: Text(acc.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                              IconButton(
                                icon: const Icon(Icons.play_arrow, size: 20),
                                onPressed: loading ? null : () => _doLogin(acc),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18, color: AppColors.textDim),
                                onPressed: () async {
                                  await widget.state.removeAccount(acc.id);
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        )),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
    );
  }
}
