import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';

import 'package:just_audio/just_audio.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final player = AudioPlayer();

  void load() async {
    await player.setUrl(
        'https://media.fireside.fm/file/fireside-audio/podcasts/audio/6/6fb8e611-9a4a-40ab-84a6-a3cd847c82e5/episodes/b/bb168014-0d09-43e4-8d0a-dfaf6cbfa89b/bb168014-0d09-43e4-8d0a-dfaf6cbfa89b.mp3');
  }

  @override
  void initState() {
    super.initState();

    player.icyMetadataStream.listen((event) {
      print(event?.headers);
    });

    load();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Column(
          children: [
            StreamBuilder<PlaybackEvent>(
              stream: player.playbackEventStream,
              builder: ((context, snapshot) {
                var progress = Duration.zero;
                var buffered = Duration.zero;
                var total = Duration.zero;
                if (snapshot.hasData) {
                  var positionData = snapshot.data!;

                  total = positionData.duration ?? Duration.zero;
                  progress = positionData.updatePosition;
                  buffered = positionData.bufferedPosition;
                }

                return ProgressBar(
                  progress: progress,
                  total: total,
                  buffered: buffered,
                  onSeek: (position) {
                    player.seek(position);
                  },
                );
              }),
            ),
            Center(
              child: ElevatedButton(
                child: const Text('play'),
                onPressed: () {
                  player.play();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
