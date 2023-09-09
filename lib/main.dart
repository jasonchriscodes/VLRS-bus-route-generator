import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_route_service/open_route_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Future<List<Map<String, double>>> routePoints = Future.value([]);
  final startLatController = TextEditingController();
  final startLngController = TextEditingController();
  final endLatController = TextEditingController();
  final endLngController = TextEditingController();

  @override
  void initState() {
    super.initState();
    generateRoute(
      startLatitude: '51.1324',
      startLongitude: '13.4145',
      endLatitude: '51.1324',
      endLongitude: '13.4145',
    );
  }

  Future<void> generateRoute({
    required String startLatitude,
    required String startLongitude,
    required String endLatitude,
    required String endLongitude,
  }) async {
    // Initialize the openrouteservice with your API key.
    final OpenRouteService client = OpenRouteService(
        apiKey: '5b3ce3597851110001cf6248388ec6c4e06043d3b87eb77a95a06a02');
    double startLat = double.parse(startLatitude);
    double startLng = double.parse(startLongitude);
    double endLat = double.parse(endLatitude);
    double endLng = double.parse(endLongitude);

    final List<ORSCoordinate> routeCoordinates =
        await client.directionsRouteCoordsGet(
      startCoordinate: ORSCoordinate(latitude: startLat, longitude: startLng),
      endCoordinate: ORSCoordinate(latitude: endLat, longitude: endLng),
    );

    final List<LatLng> routePoints = routeCoordinates
        .map((coordinate) => LatLng(coordinate.latitude, coordinate.longitude))
        .toList();

    List<Map<String, double>> data = [];
    for (var element in routePoints) {
      data.add({'latitude': element.latitude, 'longitude': element.longitude});
    }

    print(data);
    // String jsonData = jsonEncode(data);
    // String filePath = '/path/ke/file.json';
    // File file = File(filePath);
    // file.writeAsString(jsonData);

    setState(() {
      this.routePoints = Future.value(data);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          TextFormField(
            controller: startLatController,
            decoration: const InputDecoration(
              labelText: 'Start Latitude',
            ),
          ),
          TextFormField(
            controller: startLngController,
            decoration: const InputDecoration(
              labelText: 'Start Longitude',
            ),
          ),
          TextFormField(
            controller: endLatController,
            decoration: const InputDecoration(
              labelText: 'End Latitude',
            ),
          ),
          TextFormField(
            controller: endLngController,
            decoration: const InputDecoration(
              labelText: 'End Longitude',
            ),
          ),
          FutureBuilder(
            future: routePoints,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }
              if (snapshot.hasError) {
                return const Center(
                  child: Text('Error'),
                );
              }
              if (snapshot.data!.isEmpty) {
                return const Center(
                  child: Text('No Route Points Found'),
                );
              }
              return SelectableText(snapshot.data.toString());
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          generateRoute(
            startLatitude: startLatController.text,
            startLongitude: startLngController.text,
            endLatitude: endLatController.text,
            endLongitude: endLngController.text,
          );
        },
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
