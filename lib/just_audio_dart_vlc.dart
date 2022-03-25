import 'dart:async';
import 'dart:io';

import 'package:dart_vlc/dart_vlc.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class DartVlcJustAudioPlatform extends JustAudioPlatform {
  final Map<String, DartVlcAudioPlayerPlatform> players = {};

  static void registerWith() {
    DartVLC.initialize();
    JustAudioPlatform.instance = DartVlcJustAudioPlatform();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (players.containsKey(request.id)) {
      throw PlatformException(
        code: 'error',
        message: 'Platform player ${request.id} already exists',
      );
    }

    final player = DartVlcAudioPlayerPlatform(request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await players[request.id]?.dispose(DisposeRequest());
    players.remove(request.id);
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    for (final player in players.values) {
      await player.dispose(DisposeRequest());
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

int _id = 0;

class DartVlcAudioPlayerPlatform extends AudioPlayerPlatform {
  final Player player;
  IcyMetadataMessage? _icyMetadataMessage;

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  final _eventController = StreamController<PlaybackEventMessage>.broadcast();

  DartVlcAudioPlayerPlatform(String id)
      : player = Player(id: _id, commandlineArguments: ['--no-video']),
        super(id) {
    _id++;

    player.bufferingProgressStream.listen((event) {
      _transitState(ProcessingStateMessage.buffering);
      if (event >= 100) {
        _transitState(ProcessingStateMessage.ready);
      }
    });
    player.positionStream.listen((event) {
      broadcastPlaybackEvent();
    });
    player.errorStream.listen((error) {
      throw PlatformException(
        code: 'Abort',
        message: error,
      );
    });
    player.currentStream.listen((event) {
      _icyMetadataMessage = _getIcyMetadata();
      broadcastPlaybackEvent();
    });
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _eventController.stream;

  void broadcastPlaybackEvent() {
    final total = player.position.duration ?? Duration.zero;
    final buffered = Duration(milliseconds: ((player.bufferingProgress / 100) * total.inMilliseconds).round());

    var updateTime = DateTime.now();
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updatePosition: player.position.position ?? Duration.zero,
      updateTime: updateTime,
      bufferedPosition: buffered,
      icyMetadata: _icyMetadataMessage,
      duration: player.position.duration,
      currentIndex: player.current.index,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) {
    _transitState(ProcessingStateMessage.loading);

    final medias = _loadAudioMessage(request.audioSourceMessage);
    MediaSource source;
    if (medias.length > 1) {
      source = medias.first;
    } else {
      source = Playlist(medias: medias);
    }

    player.open(source, autoStart: false);

    if (request.initialIndex != null) {
      player.jump(request.initialIndex!);
    }
    if (request.initialPosition != null) {
      player.seek(request.initialPosition!);
    }

    return player.positionStream
        .firstWhere((state) => state.duration != null, orElse: () => PositionState())
        .then((state) {
      _transitState(ProcessingStateMessage.ready);
      return LoadResponse(duration: state.duration);
    });
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    player.play();

    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    player.pause();

    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.position != null) {
      if (request.index != null) {
        player.jump(request.index!);
      }
      player.seek(request.position!);
    }
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    player.setVolume(request.volume);

    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    player.setRate(request.speed);

    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    switch (request.loopMode) {
      case LoopModeMessage.off:
        player.setPlaylistMode(PlaylistMode.single);
        break;
      case LoopModeMessage.one:
        player.setPlaylistMode(PlaylistMode.repeat);
        break;
      case LoopModeMessage.all:
        player.setPlaylistMode(PlaylistMode.loop);
        break;
    }

    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    // TODO: implement manual shuffle
    return SetShuffleModeResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    player.dispose();
    _eventController.close();
    _transitState(ProcessingStateMessage.idle);

    return DisposeResponse();
  }

  Media _getUriMedia(UriAudioSourceMessage message,
      {Duration? startTime = Duration.zero, Duration? stopTime = Duration.zero}) {
    final uri = Uri.parse(message.uri);
    if (uri.isScheme('http') || uri.isScheme('https')) {
      return Media.network(
        uri.toString(),
        startTime: startTime,
        stopTime: stopTime,
        parse: true,
      );
    } else {
      return Media.file(
        File(uri.toFilePath()),
        startTime: startTime,
        stopTime: stopTime,
        parse: true,
      );
    }
  }

  List<Media> _loadAudioMessage(AudioSourceMessage sourceMessage) {
    final media = <Media>[];
    switch (sourceMessage.toMap()['type']) {
      case 'progressive':
      case 'dash':
      case 'hsl':
        final message = sourceMessage as UriAudioSourceMessage;
        media.add(_getUriMedia(message));
        break;
      case 'silence':
        throw UnsupportedError('SilenceAudioSourceMessage is not a supported audio source.');
      case 'concatenating':
        final message = sourceMessage as ConcatenatingAudioSourceMessage;

        for (final source in message.children) {
          media.addAll(_loadAudioMessage(source));
        }
        break;
      case 'clipping':
        final message = sourceMessage as ClippingAudioSourceMessage;
        media.add(_getUriMedia(message.child, startTime: message.start, stopTime: message.end));
        break;
      case 'looping':
        // final message = sourceMessage as LoopingAudioSourceMessage;
        throw UnsupportedError('LoopingAudioSourceMessage is not a supported audio source.');
    }
    return media;
  }

  void _transitState(ProcessingStateMessage state) {
    _processingState = state;
    broadcastPlaybackEvent();
  }

  IcyMetadataMessage? _getIcyMetadata() {
    final mediaMeta = player.current.media?.metas;

    if (mediaMeta == null) {
      return null;
    }

    return IcyMetadataMessage(
      info: IcyInfoMessage(
        title: mediaMeta['title'],
        url: mediaMeta['url'],
      ),
      headers: IcyHeadersMessage(
        genre: mediaMeta['genre'],
        url: mediaMeta['url'],
        bitrate: null,
        isPublic: mediaMeta['copyright'] == null,
        name: mediaMeta['title'],
        metadataInterval: null,
      ),
    );
  }
}
