import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceAgentScreen extends StatefulWidget {
  const VoiceAgentScreen({Key? key}) : super(key: key);

  @override
  State<VoiceAgentScreen> createState() => _VoiceAgentScreenState();
}

class _VoiceAgentScreenState extends State<VoiceAgentScreen> {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  
  bool _isListening = false;
  bool _isProcessing = false;
  String _transcribedText = '';
  String _aiResponse = '';
  List<ChatMessage> _chatHistory = [];
  
  // Replace with your Gemini API key
  final String _geminiApiKey = 'AIzaSyAAg-S8OofY0qvoS6TudUPN3u_m-VoK4fw';
  
  @override
  void initState() {
    super.initState();
    _initializeSpeech();
    _initializeTts();
    _addSystemMessage('Hello! I\'m your AI assistant. You can ask me about attendance, who\'s present or absent, or control the door.');
  }

  Future<void> _initializeSpeech() async {
    bool available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        print('Speech recognition error: $error');
        setState(() => _isListening = false);
        _showMessage('Speech recognition error: ${error.errorMsg}');
      },
    );
    
    if (!available) {
      _showMessage('Speech recognition not available on this device');
    }
  }

  Future<void> _initializeTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  void _addSystemMessage(String message) {
    setState(() {
      _chatHistory.add(ChatMessage(
        text: message,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
  }

  Future<void> _startListening() async {
    if (!_isListening) {
      bool available = await _speech.initialize();
      if (available) {
        setState(() {
          _isListening = true;
          _transcribedText = '';
        });
        
        _speech.listen(
          onResult: (result) {
            setState(() {
              _transcribedText = result.recognizedWords;
            });
            
            if (result.finalResult) {
              _stopListening();
              _processVoiceCommand(_transcribedText);
            }
          },
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
          cancelOnError: true,
          partialResults: true,
        );
      } else {
        _showMessage('Speech recognition not available');
      }
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  Future<void> _processVoiceCommand(String text) async {
    if (text.isEmpty) return;
    
    setState(() {
      _isProcessing = true;
      _chatHistory.add(ChatMessage(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
    });

    try {
      // Get attendance and employee data
      final attendanceData = await _getAttendanceData();
      final employeeData = await _getEmployeeData();
      
      // Build context for Gemini
      final context = _buildContext(attendanceData, employeeData);
      
      // Call Gemini API
      final response = await _callGeminiApi(text, context);
      
      setState(() {
        _aiResponse = response;
        _chatHistory.add(ChatMessage(
          text: response,
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      
      // Speak the response
      await _tts.speak(response);
      
      // Check if door command was given
      await _handleDoorCommand(text, response);
      
    } catch (e) {
      print('Error processing command: $e');
      final errorMsg = 'Sorry, I encountered an error: ${e.toString()}';
      setState(() {
        _chatHistory.add(ChatMessage(
          text: errorMsg,
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      await _tts.speak(errorMsg);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<Map<String, dynamic>> _getAttendanceData() async {
    try {
      final snapshot = await _database.child('attendance').get();
      
      if (!snapshot.exists) {
        return {'records': [], 'todayCount': 0};
      }
      
      final data = snapshot.value as Map<dynamic, dynamic>;
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      
      List<Map<String, dynamic>> allRecords = [];
      Set<String> todayEmployees = {};
      
      data.forEach((key, value) {
        if (value is Map) {
          final record = Map<String, dynamic>.from(value);
          allRecords.add(record);
          
          if (record['date'] == today) {
            todayEmployees.add(record['employeeId'].toString());
          }
        }
      });
      
      // Sort by timestamp
      allRecords.sort((a, b) {
        final aTime = a['timestamp']?.toString() ?? '';
        final bTime = b['timestamp']?.toString() ?? '';
        return bTime.compareTo(aTime);
      });
      
      return {
        'records': allRecords,
        'todayCount': todayEmployees.length,
        'todayEmployees': todayEmployees.toList(),
      };
    } catch (e) {
      print('Error getting attendance data: $e');
      return {'records': [], 'todayCount': 0};
    }
  }

  Future<Map<String, dynamic>> _getEmployeeData() async {
    try {
      final snapshot = await _database.child('employees').get();
      
      if (!snapshot.exists) {
        return {'employees': [], 'totalCount': 0};
      }
      
      final data = snapshot.value as Map<dynamic, dynamic>;
      List<Map<String, dynamic>> employees = [];
      
      data.forEach((key, value) {
        if (value is Map) {
          employees.add(Map<String, dynamic>.from(value));
        }
      });
      
      return {
        'employees': employees,
        'totalCount': employees.length,
      };
    } catch (e) {
      print('Error getting employee data: $e');
      return {'employees': [], 'totalCount': 0};
    }
  }

  String _buildContext(Map<String, dynamic> attendanceData, Map<String, dynamic> employeeData) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final todayEmployees = attendanceData['todayEmployees'] as List? ?? [];
    final allEmployees = employeeData['employees'] as List<Map<String, dynamic>>? ?? [];
    
    // Find who's present and absent today
    List<String> presentToday = [];
    List<String> absentToday = [];
    
    for (var employee in allEmployees) {
      final id = employee['id'].toString();
      final name = employee['name'].toString();
      
      if (todayEmployees.contains(id)) {
        presentToday.add(name);
      } else {
        absentToday.add(name);
      }
    }
    
    // Recent attendance records
    final recentRecords = (attendanceData['records'] as List<Map<String, dynamic>>? ?? [])
        .take(10)
        .map((r) => '${r['employeeName']} at ${r['time']} on ${r['date']}')
        .join(', ');
    
    return '''
Current Date: $today
Total Registered Employees: ${employeeData['totalCount']}
Total Present Today: ${todayEmployees.length}
Total Absent Today: ${absentToday.length}

Present Today: ${presentToday.isEmpty ? 'None' : presentToday.join(', ')}
Absent Today: ${absentToday.isEmpty ? 'None' : absentToday.join(', ')}

Recent Attendance Records: ${recentRecords.isEmpty ? 'None' : recentRecords}

You are an AI assistant for an attendance management system. You can:
1. Answer questions about who is present or absent
2. Provide attendance statistics
3. Control the door (open/close)

When the user asks to open or close the door, confirm the action in your response by saying "Opening the door" or "Closing the door".
Be concise and friendly in your responses.
''';
  }

  Future<String> _callGeminiApi(String userQuery, String context) async {
    if (_geminiApiKey.isEmpty || _geminiApiKey == 'YOUR_GEMINI_API_KEY_HERE') {
      return 'Please add your Gemini API key in the code to use the AI assistant.';
    }
    
    print('Using Gemini API key: ${_geminiApiKey.substring(0, 10)}...');
    
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey'
    );
    
    final requestBody = {
      'contents': [
        {
          'parts': [
            {'text': 'Context:\n$context\n\nUser Question: $userQuery'}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.7,
        'topK': 40,
        'topP': 0.95,
        'maxOutputTokens': 1024,
      }
    };
    
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final text = data['candidates'][0]['content']['parts'][0]['text'];
      return text.toString().trim();
    } else {
      throw Exception('Gemini API error: ${response.statusCode} - ${response.body}');
    }
  }

  Future<void> _handleDoorCommand(String userQuery, String aiResponse) async {
    final lowerQuery = userQuery.toLowerCase();
    final lowerResponse = aiResponse.toLowerCase();
    
    // Check if user wants to open/close door
    if (lowerQuery.contains('open') && lowerQuery.contains('door') ||
        lowerResponse.contains('opening the door')) {
      await _database.child('door/command').set('open');
      print('Door opened via voice command');
    } else if (lowerQuery.contains('close') && lowerQuery.contains('door') ||
               lowerResponse.contains('closing the door')) {
      await _database.child('door/command').set('close');
      print('Door closed via voice command');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice AI Assistant'),
        backgroundColor: Colors.deepPurple,
      ),
      body: Column(
        children: [
          // Chat History
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              reverse: true,
              itemCount: _chatHistory.reversed.length,
              itemBuilder: (context, index) {
                final message = _chatHistory.reversed.toList()[index];
                return ChatBubble(message: message);
              },
            ),
          ),
          
          // Transcription Display
          if (_isListening || _transcribedText.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.blue[50],
              child: Row(
                children: [
                  if (_isListening)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _isListening 
                          ? (_transcribedText.isEmpty ? 'Listening...' : _transcribedText)
                          : _transcribedText,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          
          // Control Panel
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 2,
                  blurRadius: 5,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: Column(
              children: [
                // Status
                if (_isProcessing)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Processing...', style: TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                
                // Voice Button
                GestureDetector(
                  onTap: _isProcessing ? null : (_isListening ? _stopListening : _startListening),
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isListening ? Colors.red : Colors.deepPurple,
                      boxShadow: [
                        BoxShadow(
                          color: (_isListening ? Colors.red : Colors.deepPurple).withOpacity(0.3),
                          spreadRadius: _isListening ? 10 : 5,
                          blurRadius: _isListening ? 15 : 10,
                        ),
                      ],
                    ),
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _isListening ? 'Tap to stop' : 'Tap to speak',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Ask me about attendance or to control the door',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _speech.cancel();
    _tts.stop();
    super.dispose();
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser)
            Container(
              margin: const EdgeInsets.only(right: 8),
              child: const CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: Icon(Icons.smart_toy, color: Colors.white, size: 20),
              ),
            ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: message.isUser ? Colors.deepPurple : Colors.grey[200],
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 16,
                      color: message.isUser ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('HH:mm').format(message.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: message.isUser ? Colors.white70 : Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (message.isUser)
            Container(
              margin: const EdgeInsets.only(left: 8),
              child: const CircleAvatar(
                backgroundColor: Colors.blue,
                child: Icon(Icons.person, color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}