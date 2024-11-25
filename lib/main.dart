import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Map Viewer',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final MapController _mapController = MapController();
  LatLng _currentLocation = LatLng(-36.8485, 174.7633); // Auckland, New Zealand

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map Viewer')),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          center: _currentLocation,
          zoom: 14,
          maxZoom: 18,
          minZoom: 5,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.app',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _resetToDefaultLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }

  void _resetToDefaultLocation() {
    setState(() {
      _currentLocation = LatLng(-36.8485, 174.7633); // Reset to Auckland
      _mapController.move(_currentLocation, 14);
    });
  }
}
