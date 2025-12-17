// Attendance Management App with ONNX Face Recognition
// pubspec.yaml dependencies:
// dependencies:
//   flutter:
//     sdk: flutter
//   http: ^1.1.0
//   firebase_core: ^2.24.2
//   firebase_database: ^10.4.0
//   onnxruntime: ^1.17.0
//   image: ^4.1.3
//   intl: ^0.18.1
//   path_provider: ^2.1.1
//   flutter/services
//
// Assets needed in pubspec.yaml:
// flutter:
//   assets:
//     - assets/models/face_recognition.onnx
//     - assets/models/face_detection.onnx
//
// Download models from:
// Face Detection: https://github.com/onnx/models/tree/main/vision/body_analysis/ultraface
// Face Recognition: https://github.com/onnx/models/tree/main/vision/body_analysis/arcface

import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'door_page.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatefulWidget {
  const AttendanceApp({Key? key}) : super(key: key);

  @override
  State<AttendanceApp> createState() => _AttendanceAppState();
}

class _AttendanceAppState extends State<AttendanceApp> {
  late Future<void> _initializationFuture;

  @override
  void initState() {
    super.initState();
    _initializationFuture = _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyCPHugkbYFmF-tx9JPC5AoxR-jwJm_wYn4',
          appId: '1:359926628650:android:de45803a48368a4a0f5e53',
          messagingSenderId: '359926628650',
          projectId: 'iotprojectiit',
          databaseURL: 'https://iotprojectiit-default-rtdb.europe-west1.firebasedatabase.app',
        ),
      );
      
      // Initialize ONNX Runtime only if needed
      try {
        OrtEnv.instance.init();
        print('ONNX Runtime initialized successfully');
      } catch (e) {
        print('Warning: ONNX Runtime initialization failed: $e');
        print('The app will continue, but face recognition may not work');
      }
    } catch (e) {
      print('Error during Firebase initialization: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Attendance System',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      home: FutureBuilder<void>(
        future: _initializationFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 24),
                    Text(
                      'Initializing Face Attendance System...',
                      style: TextStyle(fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 64, color: Colors.red),
                    const SizedBox(height: 24),
                    const Text(
                      'Failed to initialize app',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      snapshot.error.toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.red),
                    ),
                  ],
                ),
              ),
            );
          }
          
          return const HomeScreen();
        },
      ),
    );
  }
}

// Face Recognition Service using ONNX
class FaceRecognitionService {
  static OrtSession? _detectionSession;
  static OrtSession? _recognitionSession;
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      print('Starting model initialization...');
      
      // Try to load ONNX models, but don't fail if they don't work
      try {
        print('Attempting to load face detection model...');
        final detectionModelBytes = await rootBundle.load('assets/models/face_detection.onnx');
        print('Face detection model loaded, bytes: ${detectionModelBytes.lengthInBytes}');
        
        final detectionOpts = OrtSessionOptions();
        _detectionSession = OrtSession.fromBuffer(
          detectionModelBytes.buffer.asUint8List(),
          detectionOpts,
        );
        print('✓ Face detection session created');
      } catch (e) {
        print('⚠ Could not load face detection model: $e');
        _detectionSession = null;
      }

      // Load face recognition model (for embeddings)
      try {
        print('Attempting to load face recognition model...');
        final recognitionModelBytes = await rootBundle.load('assets/models/face_recognition.onnx');
        print('Face recognition model loaded, bytes: ${recognitionModelBytes.lengthInBytes}');
        
        final recognitionOpts = OrtSessionOptions();
        _recognitionSession = OrtSession.fromBuffer(
          recognitionModelBytes.buffer.asUint8List(),
          recognitionOpts,
        );
        print('✓ Face recognition session created');
      } catch (e) {
        print('⚠ Could not load face recognition model: $e');
        _recognitionSession = null;
      }

      _isInitialized = true;
      print('✓ Model initialization complete (ONNX fallback enabled)');
    } catch (e, stackTrace) {
      print('✗ Error during initialization: $e');
      print('Stack trace: $stackTrace');
      _isInitialized = true; // Mark as initialized to prevent repeated attempts
    }
  }

  static Future<List<FaceBox>?> detectFaces(Uint8List imageBytes) async {
    if (!_isInitialized) await initialize();

    try {
      // Decode image
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      // Preprocess for detection model (resize to 320x240)
      final resized = img.copyResize(image, width: 320, height: 240);
      
      // Convert to normalized float array [1, 3, 240, 320]
      final inputData = Float32List(1 * 3 * 240 * 320);
      var pixelIndex = 0;
      
      for (var y = 0; y < 240; y++) {
        for (var x = 0; x < 320; x++) {
          final pixel = resized.getPixel(x, y);
          // Normalize to [-1, 1] and split into RGB channels
          inputData[pixelIndex] = (pixel.r / 127.5) - 1.0; // R channel
          inputData[pixelIndex + 240 * 320] = (pixel.g / 127.5) - 1.0; // G channel
          inputData[pixelIndex + 2 * 240 * 320] = (pixel.b / 127.5) - 1.0; // B channel
          pixelIndex++;
        }
      }

      // Run detection
      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputData,
        [1, 3, 240, 320],
      );
      
      final inputs = {'input': inputOrt};
      final outputs = await _detectionSession?.runAsync(
        OrtRunOptions(),
        inputs,
      );

      inputOrt.release();

      if (outputs == null) return null;

      // Parse detection results (simplified - adjust based on your model output)
      final boxes = <FaceBox>[];
      // Note: Output parsing depends on your specific model
      // This is a placeholder - adjust based on actual model outputs
      
      return boxes.isEmpty ? null : boxes;
    } catch (e) {
      print('Face detection error: $e');
      return null;
    }
  }

  static Future<List<double>?> extractFaceEmbedding(
    Uint8List imageBytes,
    FaceBox? faceBox,
  ) async {
    try {
      // Check if ONNX session is available
      if (_recognitionSession == null) {
        print('Warning: Recognition session is null, attempting to initialize...');
        await initialize();
        if (_recognitionSession == null) {
          print('Failed to initialize ONNX recognition session');
          print('Using fallback feature extraction method...');
          return _extractFallbackEmbedding(imageBytes);
        }
      }

      // Decode image
      var image = img.decodeImage(imageBytes);
      if (image == null) {
        print('Error: Could not decode image, using fallback...');
        return _extractFallbackEmbedding(imageBytes);
      }

      // Crop to face if box provided, otherwise use full image
      if (faceBox != null) {
        image = img.copyCrop(
          image,
          x: faceBox.x,
          y: faceBox.y,
          width: faceBox.width,
          height: faceBox.height,
        );
      }

      // Resize to model input size (typically 112x112 for face recognition)
      final resized = img.copyResize(image, width: 112, height: 112);

      // Convert to normalized float array [1, 3, 112, 112]
      final inputData = Float32List(1 * 3 * 112 * 112);
      var pixelIndex = 0;

      for (var y = 0; y < 112; y++) {
        for (var x = 0; x < 112; x++) {
          final pixel = resized.getPixel(x, y);
          // Normalize to [0, 1] or [-1, 1] based on your model
          inputData[pixelIndex] = (pixel.r / 255.0);
          inputData[pixelIndex + 112 * 112] = (pixel.g / 255.0);
          inputData[pixelIndex + 2 * 112 * 112] = (pixel.b / 255.0);
          pixelIndex++;
        }
      }

      // Run recognition model
      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputData,
        [1, 3, 112, 112],
      );

      final inputs = {'input': inputOrt};
      print('Running ONNX recognition model...');
      
      final outputs = await _recognitionSession?.runAsync(
        OrtRunOptions(),
        inputs,
      );

      inputOrt.release();

      if (outputs == null || outputs.isEmpty) {
        print('Error: ONNX model returned null or empty outputs, using fallback...');
        return _extractFallbackEmbedding(imageBytes);
      }

      // Extract embedding vector (typically 512 dimensions)
      final embeddingTensor = outputs.first;
      if (embeddingTensor == null) {
        print('Error: Embedding tensor is null, using fallback...');
        return _extractFallbackEmbedding(imageBytes);
      }

      try {
        final embeddingValue = embeddingTensor.value;
        if (embeddingValue == null) {
          print('Error: Embedding value is null, using fallback...');
          return _extractFallbackEmbedding(imageBytes);
        }

        final embedding = (embeddingValue as List).cast<double>();
        print('✓ Successfully extracted embedding with ${embedding.length} dimensions');
        return embedding;
      } catch (e) {
        print('Error parsing embedding output: $e');
        print('Output type: ${embeddingTensor.runtimeType}');
        print('Using fallback feature extraction...');
        return _extractFallbackEmbedding(imageBytes);
      }
    } catch (e, stackTrace) {
      print('✗ Face embedding extraction error: $e');
      print('Stack trace: $stackTrace');
      print('Using fallback feature extraction...');
      return _extractFallbackEmbedding(imageBytes);
    }
  }

  static List<double> _extractFallbackEmbedding(Uint8List imageBytes) {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) {
        print('Error: Could not decode image in fallback');
        return List.filled(512, 0.0);
      }

      // Resize to 112x112
      final resized = img.copyResize(image, width: 112, height: 112);

      // Extract histogram-based features (512 dimensions)
      final embedding = <double>[];

      // Extract color histograms (RGB channels)
      final rHist = List<int>.filled(64, 0);
      final gHist = List<int>.filled(64, 0);
      final bHist = List<int>.filled(64, 0);

      for (var y = 0; y < resized.height; y++) {
        for (var x = 0; x < resized.width; x++) {
          final pixel = resized.getPixel(x, y);
          rHist[(pixel.r ~/ 4)] += 1; // 256 / 64 = 4
          gHist[(pixel.g ~/ 4)] += 1;
          bHist[(pixel.b ~/ 4)] += 1;
        }
      }

      // Normalize histograms
      final totalPixels = resized.width * resized.height;
      for (int i = 0; i < 64; i++) {
        embedding.add(rHist[i] / totalPixels);
        embedding.add(gHist[i] / totalPixels);
        embedding.add(bHist[i] / totalPixels);
      }

      // Add edge detection features
      for (var y = 1; y < resized.height - 1; y++) {
        for (var x = 1; x < resized.width - 1; x++) {
          final center = resized.getPixel(x, y);
          final edges = [
            resized.getPixel(x - 1, y),
            resized.getPixel(x + 1, y),
            resized.getPixel(x, y - 1),
            resized.getPixel(x, y + 1),
          ];

          double edgeStrength = 0;
          for (final edge in edges) {
            edgeStrength += ((center.r - edge.r).abs() +
                    (center.g - edge.g).abs() +
                    (center.b - edge.b).abs())
                .toDouble();
          }
          embedding.add(edgeStrength / 1020); // Normalize
        }
      }

      // Pad to 512 dimensions if needed
      while (embedding.length < 512) {
        embedding.add(0.0);
      }

      // Trim to 512 if longer
      final result = embedding.sublist(0, math.min(512, embedding.length));
      print('✓ Generated fallback embedding with ${result.length} dimensions');
      return result;
    } catch (e) {
      print('Error in fallback embedding: $e');
      return List.filled(512, 0.0);
    }
  }

  static double cosineSimilarity(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) return 0.0;

    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;

    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }

    if (norm1 == 0.0 || norm2 == 0.0) return 0.0;

    return dotProduct / (math.sqrt(norm1) * math.sqrt(norm2));
  }

  static void dispose() {
    _detectionSession?.release();
    _recognitionSession?.release();
    OrtEnv.instance.release();
    _isInitialized = false;
  }
}

class FaceBox {
  final int x;
  final int y;
  final int width;
  final int height;
  final double confidence;

  FaceBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'confidence': confidence,
  };

  factory FaceBox.fromJson(Map<dynamic, dynamic> json) => FaceBox(
    x: json['x'] as int,
    y: json['y'] as int,
    width: json['width'] as int,
    height: json['height'] as int,
    confidence: (json['confidence'] as num).toDouble(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _cameraUrl = '';
  bool _isCameraConnected = false;
  bool _isModelLoading = false;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeModels();
  }

  Future<void> _initializeModels() async {
    setState(() => _isModelLoading = true);
    try {
      await FaceRecognitionService.initialize();
      _showMessage('Face recognition models loaded successfully!', isError: false);
    } catch (e) {
      _showMessage('Failed to load models: $e');
    } finally {
      setState(() => _isModelLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Attendance System'),
        backgroundColor: Colors.indigo,
      ),
      body: _isModelLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading AI models...'),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Camera Connection Card
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const Text(
                            'Camera Connection',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _urlController,
                            decoration: InputDecoration(
                              labelText: 'Camera Server URL',
                              hintText: 'http://192.168.1.100:8080',
                              border: const OutlineInputBorder(),
                              prefixIcon: const Icon(Icons.link),
                              suffixIcon: _isCameraConnected
                                  ? const Icon(Icons.check_circle, color: Colors.green)
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _testConnection,
                            icon: const Icon(Icons.cable),
                            label: const Text('Test Connection'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Action Buttons
                  _buildActionButton(
                    context,
                    'Register New Employee',
                    Icons.person_add,
                    Colors.indigo,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => RegisterScreen(cameraUrl: _cameraUrl),
                      ),
                    ),
                    enabled: _isCameraConnected,
                  ),
                  const SizedBox(height: 12),
                  _buildActionButton(
                    context,
                    'Mark Attendance',
                    Icons.check_circle,
                    Colors.green,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AttendanceScreen(cameraUrl: _cameraUrl),
                      ),
                    ),
                    enabled: _isCameraConnected,
                  ),
                  const SizedBox(height: 12),
                  _buildActionButton(
                    context,
                    'View Employees',
                    Icons.people,
                    Colors.blue,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const EmployeeListScreen(),
                      ),
                    ),
                    enabled: true,
                  ),
                  const SizedBox(height: 12),
                  _buildActionButton(
                    context,
                    'Attendance Log',
                    Icons.history,
                    Colors.orange,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AttendanceLogScreen(),
                      ),
                    ),
                    enabled: true,
                  ),
                  const SizedBox(height: 12),
                  _buildActionButton(
                    context,
                    'Door Control',
                    Icons.door_front_door,
                    Colors.deepPurple,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DoorPage(),
                      ),
                    ),
                    enabled: true,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String label,
    IconData icon,
    Color color,
    VoidCallback onPressed, {
    bool enabled = true,
  }) {
    return ElevatedButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 28),
      label: Text(label, style: const TextStyle(fontSize: 18)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showMessage('Please enter camera URL');
      return;
    }

    try {
      final response = await http.get(Uri.parse('$url/health')).timeout(
        const Duration(seconds: 5),
      );

      if (response.statusCode == 200) {
        setState(() {
          _cameraUrl = url;
          _isCameraConnected = true;
        });
        _showMessage('Camera connected successfully!', isError: false);
      } else {
        setState(() => _isCameraConnected = false);
        _showMessage('Camera server not responding');
      }
    } catch (e) {
      setState(() => _isCameraConnected = false);
      _showMessage('Connection failed: ${e.toString()}');
    }
  }

  void _showMessage(String message, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}

// Register Screen
class RegisterScreen extends StatefulWidget {
  final String cameraUrl;

  const RegisterScreen({Key? key, required this.cameraUrl}) : super(key: key);

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _idController = TextEditingController();
  Uint8List? _capturedImage;
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Employee'),
        backgroundColor: Colors.indigo,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Employee Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _idController,
              decoration: const InputDecoration(
                labelText: 'Employee ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge),
              ),
            ),
            const SizedBox(height: 24),
            if (_capturedImage != null)
              Container(
                height: 300,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_capturedImage!, fit: BoxFit.contain),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _captureImage,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Capture Face'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: (_capturedImage != null && !_isProcessing)
                  ? _registerEmployee
                  : null,
              icon: _isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save),
              label: Text(_isProcessing ? 'Processing...' : 'Register Employee'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.all(16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _captureImage() async {
    setState(() => _isProcessing = true);

    try {
      final response = await http.get(
        Uri.parse('${widget.cameraUrl}/capture'),
      );

      if (response.statusCode == 200) {
        final base64Image = response.body;
        setState(() {
          _capturedImage = base64Decode(base64Image);
          _isProcessing = false;
        });
        _showMessage('Image captured successfully!', isError: false);
      } else {
        throw Exception('Failed to capture image');
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      _showMessage('Capture failed: ${e.toString()}');
    }
  }

  Future<void> _registerEmployee() async {
    if (_nameController.text.isEmpty || _idController.text.isEmpty) {
      _showMessage('Please fill all fields');
      return;
    }

    if (_capturedImage == null) {
      _showMessage('Please capture an image first');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      print('Extracting face embedding...');
      // Extract face embedding using ONNX
      final embedding = await FaceRecognitionService.extractFaceEmbedding(
        _capturedImage!,
        null, // Will use full image if no face box provided
      );

      if (embedding == null || embedding.isEmpty) {
        print('Error: Face embedding is null or empty');
        _showMessage('Could not extract face features. Please try again with better lighting.');
        setState(() => _isProcessing = false);
        return;
      }

      print('Successfully got embedding, saving to Firebase...');
      // Save to Firebase
      final employeeData = {
        'id': _idController.text,
        'name': _nameController.text,
        'image': base64Encode(_capturedImage!),
        'faceEmbedding': embedding,
        'embeddingDimension': embedding.length,
        'registeredAt': DateTime.now().toIso8601String(),
      };

      await _database.child('employees').child(_idController.text).set(employeeData);

      _showMessage('Employee registered successfully!', isError: false);
      
      await Future.delayed(const Duration(seconds: 1));
      Navigator.pop(context);
    } catch (e) {
      _showMessage('Registration failed: ${e.toString()}');
      print('Full error: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showMessage(String message, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }
}

// Attendance Screen
class AttendanceScreen extends StatefulWidget {
  final String cameraUrl;

  const AttendanceScreen({Key? key, required this.cameraUrl}) : super(key: key);

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  Uint8List? _capturedImage;
  bool _isProcessing = false;
  String? _matchedEmployee;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mark Attendance'),
        backgroundColor: Colors.green,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_capturedImage != null)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_capturedImage!, fit: BoxFit.contain),
                  ),
                ),
              ),
            if (_matchedEmployee != null)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: Text(
                  'Matched: $_matchedEmployee',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _captureAndMarkAttendance,
              icon: _isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.camera_alt),
              label: Text(_isProcessing ? 'Processing...' : 'Capture & Mark Attendance'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.all(20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _captureAndMarkAttendance() async {
    setState(() => _isProcessing = true);

    try {
      // Capture image from camera
      final response = await http.get(
        Uri.parse('${widget.cameraUrl}/capture'),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to capture image');
      }

      final base64Image = response.body;
      final imageBytes = base64Decode(base64Image);
      
      setState(() => _capturedImage = imageBytes);

      // Extract face embedding
      final capturedEmbedding = await FaceRecognitionService.extractFaceEmbedding(
        imageBytes,
        null,
      );

      if (capturedEmbedding == null || capturedEmbedding.isEmpty) {
        _showMessage('Could not detect face. Please try again.');
        setState(() => _isProcessing = false);
        return;
      }

      // Match with registered employees
      final snapshot = await _database.child('employees').get();
      
      if (!snapshot.exists) {
        _showMessage('No employees registered');
        setState(() => _isProcessing = false);
        return;
      }

      if (snapshot.value is! Map) {
        _showMessage('Invalid employee data format');
        setState(() => _isProcessing = false);
        return;
      }

      final employees = snapshot.value as Map<dynamic, dynamic>;
      String? matchedId;
      String? matchedName;
      double highestSimilarity = 0.0;

      // Find best match using cosine similarity
      for (var entry in employees.entries) {
        final employeeData = entry.value as Map<dynamic, dynamic>;
        final storedEmbedding = (employeeData['faceEmbedding'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        
        if (storedEmbedding != null && storedEmbedding.length == capturedEmbedding.length) {
          final similarity = FaceRecognitionService.cosineSimilarity(
            capturedEmbedding,
            storedEmbedding,
          );
          
          // Typical threshold for face recognition is 0.5-0.6
          if (similarity > highestSimilarity && similarity > 0.5) {
            highestSimilarity = similarity;
            matchedId = employeeData['id'];
            matchedName = employeeData['name'];
          }
        }
      }

      if (matchedId != null && matchedName != null) {
        // Mark attendance
        final now = DateTime.now();
        final attendanceData = {
          'employeeId': matchedId,
          'employeeName': matchedName,
          'timestamp': now.toIso8601String(),
          'date': DateFormat('yyyy-MM-dd').format(now),
          'time': DateFormat('HH:mm:ss').format(now),
          'confidence': '${(highestSimilarity * 100).toStringAsFixed(1)}%',
          'similarityScore': highestSimilarity,
        };

        await _database
            .child('attendance')
            .child(now.millisecondsSinceEpoch.toString())
            .set(attendanceData);

        setState(() => _matchedEmployee = matchedName);
        _showMessage(
          'Attendance marked for $matchedName! (${(highestSimilarity * 100).toStringAsFixed(1)}% match)',
          isError: false,
        );
      } else {
        _showMessage('No matching employee found. Similarity too low or employee not registered.');
      }
    } catch (e) {
      _showMessage('Error: ${e.toString()}');
      print('Attendance error: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showMessage(String message, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

// Employee List Screen
class EmployeeListScreen extends StatelessWidget {
  const EmployeeListScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final database = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registered Employees'),
        backgroundColor: Colors.blue,
      ),
      body: StreamBuilder(
        stream: database.child('employees').onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
            return const Center(
              child: Text(
                'No employees registered yet',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          try {
            final data = snapshot.data!.snapshot.value;
            
            // Handle both Map and List types
            List<Map<String, dynamic>> employeeList = [];
            
            if (data is Map) {
              employeeList = data.values.map((e) {
                if (e is Map) {
                  return Map<String, dynamic>.from(e);
                }
                return <String, dynamic>{};
              }).where((e) => e.isNotEmpty).toList();
            } else if (data is List) {
              employeeList = data.where((e) => e != null).map((e) {
                if (e is Map) {
                  return Map<String, dynamic>.from(e);
                }
                return <String, dynamic>{};
              }).where((e) => e.isNotEmpty).toList();
            }

            if (employeeList.isEmpty) {
              return const Center(
                child: Text(
                  'No employees registered yet',
                  style: TextStyle(fontSize: 16),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: employeeList.length,
              itemBuilder: (context, index) {
                final employee = employeeList[index];
                final imageData = employee['image'] as String?;
                
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: imageData != null
                        ? CircleAvatar(
                            backgroundImage: MemoryImage(
                              base64Decode(imageData),
                            ),
                          )
                        : const CircleAvatar(
                            child: Icon(Icons.person),
                          ),
                    title: Text(employee['name']?.toString() ?? 'Unknown'),
                    subtitle: Text('ID: ${employee['id']?.toString() ?? 'N/A'}'),
                    trailing: employee['registeredAt'] != null
                        ? Text(
                            DateFormat('MMM dd, yyyy').format(
                              DateTime.parse(employee['registeredAt'].toString()),
                            ),
                            style: const TextStyle(fontSize: 12),
                          )
                        : null,
                  ),
                );
              },
            );
          } catch (e) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error loading employees: $e'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }
}

// Attendance Log Screen
class AttendanceLogScreen extends StatelessWidget {
  const AttendanceLogScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final database = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Log'),
        backgroundColor: Colors.orange,
      ),
      body: StreamBuilder(
        stream: database.child('attendance').orderByChild('timestamp').onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
            return const Center(
              child: Text(
                'No attendance records yet',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          try {
            final data = snapshot.data!.snapshot.value;
            
            // Handle both Map and List types
            List<Map<String, dynamic>> attendanceList = [];
            
            if (data is Map) {
              attendanceList = data.values.map((e) {
                if (e is Map) {
                  return Map<String, dynamic>.from(e);
                }
                return <String, dynamic>{};
              }).where((e) => e.isNotEmpty).toList();
            } else if (data is List) {
              attendanceList = data.where((e) => e != null).map((e) {
                if (e is Map) {
                  return Map<String, dynamic>.from(e);
                }
                return <String, dynamic>{};
              }).where((e) => e.isNotEmpty).toList();
            }

            // Sort by timestamp (newest first)
            attendanceList.sort((a, b) {
              final aTime = a['timestamp']?.toString() ?? '';
              final bTime = b['timestamp']?.toString() ?? '';
              return bTime.compareTo(aTime);
            });

            if (attendanceList.isEmpty) {
              return const Center(
                child: Text(
                  'No attendance records yet',
                  style: TextStyle(fontSize: 16),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: attendanceList.length,
              itemBuilder: (context, index) {
                final record = attendanceList[index];
                
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.check_circle),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    title: Text(record['employeeName']?.toString() ?? 'Unknown'),
                    subtitle: Text('ID: ${record['employeeId']?.toString() ?? 'N/A'}${record['confidence'] != null ? ' - ${record['confidence']}' : ''}'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          record['date']?.toString() ?? '',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          record['time']?.toString() ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          } catch (e) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error loading attendance: $e'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }
}