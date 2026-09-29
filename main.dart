// ============================================================================
// Klebsiella AMR Predictor - Flutter Mobile App
// Single-file implementation (main.dart)
//
// Connects to a FastAPI backend for:
//   - GET  /gene-list
//   - POST /predict-gene-impact
//   - POST /trigger-live-bvbrc-sync
//
// Dependencies (add to pubspec.yaml):
//   dependencies:
//     flutter:
//       sdk: flutter
//     http: ^1.2.1
//
// Run:
//   flutter pub get
//   flutter run
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ----------------------------------------------------------------------------
// CONFIG
// ----------------------------------------------------------------------------
const String kBaseUrl = 'http://127.0.0.1:8000';

// NOTE: If testing on:
//  - Android Emulator -> use http://10.0.2.2:8000
//  - iOS Simulator    -> http://127.0.0.1:8000 works fine
//  - Physical device  -> use your machine's LAN IP, e.g. http://192.168.1.5:8000

const List<String> kAntibiotics = [
  'Meropenem',
  'Ceftazidime',
  'Colistin',
  'Imipenem',
  'Amikacin',
  'Ciprofloxacin',
];

// Clinical color palette
const Color kMedicalBlue = Color(0xFF0D6EFD);
const Color kMedicalBlueDark = Color(0xFF0A58CA);
const Color kBackground = Color(0xFFF5F8FC);
const Color kCardShadow = Color(0x1A0D6EFD);
const Color kResistantRed = Color(0xFFD32F2F);
const Color kSusceptibleGreen = Color(0xFF2E7D32);
const Color kNeutralGrey = Color(0xFF6B7280);

void main() {
  runApp(const KlebsiellaAMRApp());
}

class KlebsiellaAMRApp extends StatelessWidget {
  const KlebsiellaAMRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Klebsiella AMR Predictor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBackground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kMedicalBlue,
          primary: kMedicalBlue,
          background: kBackground,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kMedicalBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        fontFamily: 'Roboto',
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const AMRHomePage(),
    );
  }
}

// ----------------------------------------------------------------------------
// DATA MODEL
// ----------------------------------------------------------------------------
class PredictionResult {
  final double probability;
  final String status;

  PredictionResult({required this.probability, required this.status});

  factory PredictionResult.fromJson(Map<String, dynamic> json) {
    final rawProb = json['resistance_probability_%'];
    double prob;
    if (rawProb is int) {
      prob = rawProb.toDouble();
    } else if (rawProb is double) {
      prob = rawProb;
    } else {
      prob = double.tryParse(rawProb.toString()) ?? 0.0;
    }
    return PredictionResult(
      probability: prob,
      status: json['status']?.toString() ?? 'Unknown',
    );
  }

  bool get isResistant => status.toLowerCase().contains('resistant') &&
      !status.toLowerCase().contains('susceptible');
}

// ----------------------------------------------------------------------------
// API SERVICE
// ----------------------------------------------------------------------------
class AMRApiService {
  static const Duration _timeout = Duration(seconds: 15);

  Future<List<String>> fetchGeneList() async {
    final uri = Uri.parse('$kBaseUrl/gene-list');
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode == 200) {
      final Map<String, dynamic> data = jsonDecode(response.body);
      final List<dynamic> genes = data['genes'] ?? [];
      return genes.map((e) => e.toString()).toList();
    } else {
      throw ApiException(
          'Failed to load gene list (status ${response.statusCode})');
    }
  }

  Future<PredictionResult> predictGeneImpact({
    required List<String> genes,
    required String antibiotic,
  }) async {
    final uri = Uri.parse('$kBaseUrl/predict-gene-impact');
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'genes': genes, 'antibiotic': antibiotic}),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final Map<String, dynamic> data = jsonDecode(response.body);
      return PredictionResult.fromJson(data);
    } else {
      throw ApiException(
          'Prediction failed (status ${response.statusCode})');
    }
  }

  Future<int> triggerLiveSync() async {
    final uri = Uri.parse('$kBaseUrl/trigger-live-bvbrc-sync');
    final response = await http.post(uri).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final Map<String, dynamic> data = jsonDecode(response.body);
      return (data['new_records_added'] ?? 0) is int
          ? data['new_records_added']
          : int.tryParse(data['new_records_added'].toString()) ?? 0;
    } else {
      throw ApiException('Sync failed (status ${response.statusCode})');
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

// ----------------------------------------------------------------------------
// HOME PAGE
// ----------------------------------------------------------------------------
class AMRHomePage extends StatefulWidget {
  const AMRHomePage({super.key});

  @override
  State<AMRHomePage> createState() => _AMRHomePageState();
}

class _AMRHomePageState extends State<AMRHomePage> {
  final AMRApiService _api = AMRApiService();

  List<String> _genes = [];
  final Set<String> _selectedGenes = {};
  String _selectedAntibiotic = kAntibiotics.first;

  bool _isLoadingGenes = true;
  bool _isSyncing = false;
  bool _isPredicting = false;

  PredictionResult? _result;
  String? _geneListError;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadGeneList();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadGeneList() async {
    setState(() {
      _isLoadingGenes = true;
      _geneListError = null;
    });
    try {
      final genes = await _api.fetchGeneList();
      setState(() {
        _genes = genes;
        _isLoadingGenes = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingGenes = false;
        _geneListError = 'Could not load gene list. Pull down to retry.';
      });
      _showErrorSnackBar('Failed to load genes: $e');
    }
  }

  void _toggleGene(String gene, bool selected) {
    setState(() {
      if (selected) {
        _selectedGenes.add(gene);
      } else {
        _selectedGenes.remove(gene);
      }
    });
    _debouncedPredict();
  }

  void _onAntibioticChanged(String? value) {
    if (value == null) return;
    setState(() => _selectedAntibiotic = value);
    _debouncedPredict();
  }

  // Debounce rapid toggle changes so we don't spam the API
  void _debouncedPredict() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _runPrediction);
  }

  Future<void> _runPrediction() async {
    if (_selectedGenes.isEmpty) {
      setState(() => _result = null);
      return;
    }

    setState(() => _isPredicting = true);

    try {
      final result = await _api.predictGeneImpact(
        genes: _selectedGenes.toList(),
        antibiotic: _selectedAntibiotic,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _isPredicting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPredicting = false);
      _showErrorSnackBar('Prediction error: $e');
    }
  }

  Future<void> _handleSync() async {
    setState(() => _isSyncing = true);
    try {
      final count = await _api.triggerLiveSync();
      if (!mounted) return;
      setState(() => _isSyncing = false);
      _showSuccessSnackBar('Sync complete: $count new records added.');
      // Refresh gene list in case new genes appeared
      _loadGeneList();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSyncing = false);
      _showErrorSnackBar('Sync failed: $e');
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: kResistantRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: kSusceptibleGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Klebsiella AMR Predictor'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: TextButton.icon(
              onPressed: _isSyncing ? null : _handleSync,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : const Icon(Icons.sync, color: Colors.white),
              label: Text(
                _isSyncing ? 'Syncing...' : 'Sync BV-BRC',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadGeneList,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildAntibioticSelector()),
              SliverToBoxAdapter(child: _buildSectionTitle('Resistance Genes')),
              _buildGeneSection(),
              SliverToBoxAdapter(
                child: SizedBox(
                    height:
                        _selectedGenes.isNotEmpty || _isPredicting ? 24 : 8),
              ),
              SliverToBoxAdapter(child: _buildResultCard()),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1F2937),
        ),
      ),
    );
  }

  Widget _buildAntibioticSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: kCardShadow, blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.medication_outlined, color: kMedicalBlue),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedAntibiotic,
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down, color: kMedicalBlue),
                  style: const TextStyle(
                    color: Color(0xFF1F2937),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  items: kAntibiotics
                      .map((ab) => DropdownMenuItem(value: ab, child: Text(ab)))
                      .toList(),
                  onChanged: _onAntibioticChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneSection() {
    if (_isLoadingGenes) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator(color: kMedicalBlue)),
        ),
      );
    }

    if (_geneListError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            children: [
              Text(_geneListError!,
                  style: const TextStyle(color: kNeutralGrey),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _loadGeneList,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(backgroundColor: kMedicalBlue),
              ),
            ],
          ),
        ),
      );
    }

    if (_genes.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          child: Text('No genes available.',
              style: TextStyle(color: kNeutralGrey)),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _genes.map((gene) {
            final selected = _selectedGenes.contains(gene);
            return FilterChip(
              label: Text(
                gene,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : const Color(0xFF374151),
                ),
              ),
              selected: selected,
              onSelected: (val) => _toggleGene(gene, val),
              selectedColor: kMedicalBlue,
              backgroundColor: Colors.white,
              checkmarkColor: Colors.white,
              elevation: 1,
              shadowColor: kCardShadow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: selected ? kMedicalBlue : const Color(0xFFE5E7EB),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final hasSelection = _selectedGenes.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: kCardShadow, blurRadius: 20, offset: Offset(0, 6)),
          ],
        ),
        child: !hasSelection
            ? _buildEmptyState()
            : _isPredicting
                ? _buildPredictingState()
                : _result == null
                    ? _buildEmptyState()
                    : _buildResultContent(_result!),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.science_outlined, size: 40, color: kNeutralGrey),
          SizedBox(height: 12),
          Text(
            'Select one or more genes to predict resistance',
            textAlign: TextAlign.center,
            style: TextStyle(color: kNeutralGrey, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildPredictingState() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          CircularProgressIndicator(color: kMedicalBlue),
          SizedBox(height: 16),
          Text('Analyzing genomic profile...',
              style: TextStyle(color: kNeutralGrey)),
        ],
      ),
    );
  }

  Widget _buildResultContent(PredictionResult result) {
    final Color statusColor =
        result.isResistant ? kResistantRed : kSusceptibleGreen;
    final IconData statusIcon =
        result.isResistant ? Icons.warning_amber_rounded : Icons.verified_outlined;

    return Column(
      children: [
        Text(
          'Predicted Resistance to $_selectedAntibiotic',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: kNeutralGrey,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 160,
                height: 160,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    begin: 0,
                    end: (result.probability / 100).clamp(0.0, 1.0),
                  ),
                  duration: const Duration(milliseconds: 600),
                  builder: (context, value, child) {
                    return CircularProgressIndicator(
                      value: value,
                      strokeWidth: 12,
                      backgroundColor: statusColor.withOpacity(0.12),
                      valueColor: AlwaysStoppedAnimation(statusColor),
                    );
                  },
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${result.probability.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Probability',
                    style: TextStyle(fontSize: 12, color: kNeutralGrey),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, color: statusColor, size: 20),
              const SizedBox(width: 8),
              Text(
                result.status,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: _selectedGenes
              .map((g) => Chip(
                    label: Text(g, style: const TextStyle(fontSize: 12)),
                    backgroundColor: const Color(0xFFF3F4F6),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ))
              .toList(),
        ),
      ],
    );
  }
}
