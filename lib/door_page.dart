import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class DoorPage extends StatefulWidget {
  const DoorPage({Key? key}) : super(key: key);

  @override
  State<DoorPage> createState() => _DoorPageState();
}

class _DoorPageState extends State<DoorPage> {
  final DatabaseReference _doorRef =
      FirebaseDatabase.instance.ref('door');

  String _doorStatus = 'unknown';

  @override
  void initState() {
    super.initState();
    _listenToDoorStatus();
  }

  void _listenToDoorStatus() {
    _doorRef.child('status').onValue.listen((event) {
      if (event.snapshot.value != null) {
        setState(() {
          _doorStatus = event.snapshot.value.toString();
        });
      }
    });
  }

  void _openDoor() {
    _doorRef.child('command').set('open');
  }

  void _closeDoor() {
    _doorRef.child('command').set('close');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Door Control'),
        backgroundColor: Colors.indigo,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _doorStatus == 'opened'
                  ? Icons.lock_open
                  : Icons.lock,
              size: 120,
              color: _doorStatus == 'opened'
                  ? Colors.green
                  : Colors.red,
            ),
            const SizedBox(height: 20),
            Text(
              'Door Status: $_doorStatus',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _openDoor,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 55),
              ),
              child: const Text(
                'OPEN DOOR',
                style: TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 15),
            ElevatedButton(
              onPressed: _closeDoor,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size(double.infinity, 55),
              ),
              child: const Text(
                'CLOSE DOOR',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
